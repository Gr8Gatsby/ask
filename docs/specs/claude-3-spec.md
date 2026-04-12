# claude-3: Feed-Based Claude Code Supervisor

## Overview

claude-3 is a rewrite of claudecode-controller using the feed-first architecture introduced in codex-3. It supervises Claude Code sessions on the Mac, surfaces live session state to the iPhone and Mac apps via `agent_session` blocks, and records session history to a persistent task feed visible in the iOS Feed tab.

claude-3 runs alongside claudecode-controller without conflict. The existing script is not modified.

---

## Goals

- Replace the ad-hoc block list in claudecode-controller with a proper task-backed feed that appears in the iOS Feed tab alongside other A2A tasks
- Reduce architectural complexity by adopting codex-3's proven block/socket/hook skeleton
- Keep all functionality users rely on: permission gating, session routing, interactive prompt detection, process discovery

---

## Session Discovery

- claude-3 installs hooks into Claude Code's hook system on startup
- Hooks fire for: SessionStart, PreToolUse, PostToolUse, Stop, UserPromptSubmit
- Each hook sends a JSON event to a local Unix socket that claude-3 listens on
- On startup, claude-3 also scans running processes to discover Claude Code instances that started before the daemon (process discovery)
- Sessions discovered via process scan are tracked as transient sessions and not persisted to disk

---

## Session State

Each live Claude Code session is represented as a session record with:
- Session ID and project label (last 2 path parts of CWD)
- Working directory and TTY
- Working state: starting, idle, running\_tool, awaiting\_user, waiting\_permission, stopped
- Current tool name and preview text (truncated)
- Last message extracted from Claude's output
- Pending permission request, if any

Session records are persisted to disk. Sessions older than 24 hours without activity are pruned on startup. Transient process-discovery sessions are never persisted.

---

## Block Surface

### Tile Block
- One tile block for the whole script showing session count and whether any session needs permission
- Status color: orange when permission is needed, blue when sessions are working, gray when idle, absent when no sessions

### Start Session Block
- Shows a list of local git repositories the user can launch a new Claude Code session in
- Refreshed each time the start session block is emitted

### Agent Session Block
- One `agent_session` block per live session
- Shows: project label, working state, current tool, preview text, last message, permission mode toggle
- When a permission request is pending, the block includes an embedded `pending_confirmation` with options (Allow, Always Allow, Deny) — no separate floating inbox item
- When the session stops, its block is cleared

---

## Task Feed (A2A History)

Each session is backed by an A2A task (open\_task). The task is opened when a session is first seen and updated throughout the session's lifetime.

Events written to the task history:
- Session started (with project name and CWD)
- User prompt submitted (role: user)
- Claude's last message when a tool executes or the session goes idle (role: assistant)
- Permission requested (role: assistant, includes tool name and preview)
- Permission resolved (role: assistant, includes the user's choice)
- Session stopped or interrupted

Long assistant outputs (over ~1600 characters) are also uploaded as artifacts so the feed row shows a summary rather than a wall of text.

Task status reflects session activity: `working` while a session is live, `completed` when it stops.

---

## Terminal Routing

- Outbound text (user replies, permission choices that require keystroke injection) is sent via terminal-manager
- Primary route: `inject_tty` (sends directly into the TTY input queue, no window focus required)
- Fallback: `send_text` via terminal-manager if inject\_tty is unavailable for the session
- Interrupt (Ctrl-C) is sent via terminal-manager's `send_interrupt`

---

## Permission Requests

- When a hook sends a `permission_request` event, claude-3 blocks the hook process until the user responds or a timeout elapses
- In supervised mode: the session block is updated with a `pending_confirmation` and the daemon waits up to 180 seconds for the user's response
- In full-auto mode: all requests are automatically allowed without surfacing to the user
- "Always Allow" responses are recorded in a local allowlist; matching tool previews are auto-allowed on future requests without prompting
- On timeout, the request is denied

---

## Interactive Prompt Detection

- claude-3 polls each session's TTY output via terminal-manager to detect interactive terminal prompts (numbered menus, arrow-key menus, y/n prompts) that Claude Code itself surfaces in the terminal
- When such a prompt is detected, it is embedded as a `pending_confirmation` in the session's block
- The user's response is translated into the appropriate keystroke sequence and sent to the TTY
- Polling is suppressed while Claude is actively streaming output to avoid false positives
- Claude Code's own idle UI strings (e.g. "accept edits on", "esc to interrupt") are excluded from detection

---

## User-Initiated Actions (from iPhone / Mac)

- **Reply**: Send a text message to a specific session; routed to the TTY and recorded in the task feed
- **Interrupt**: Send Ctrl-C to a specific session
- **Close session**: Send a quit sequence to stop Claude Code in that session
- **Toggle permission mode**: Switch between supervised and full-auto for all sessions
- **Start session**: Launch a new Claude Code session in a selected repository

---

## Heartbeat

- A background task runs every 15 seconds
- Checks whether each tracked session's TTY is still live
- Sessions whose TTY has gone away are marked stopped, their task closed, and their block cleared
- Tile block is re-emitted after each heartbeat cycle

---

## Module Structure

claude-3 is organized as three files mirroring codex-3:
- `main.py`: Main controller, RPC loop, socket server, hook event handlers, block/task emission
- `registry.py`: Per-session state dataclass and session registry (create, update, lookup, remove)
- `transport.py`: Terminal-manager RPC calls (inject\_tty, send\_text, send\_interrupt, wait\_for\_idle) and TTY utilities

Hooks live in a `hooks/` subdirectory, matching the claudecode-controller layout.

---

## Out of Scope

- Diagnostics block (removed — not needed in the feed-first model)
- Floating inbox items for permissions (replaced by embedded pending\_confirmation)
- tmux capture-pane response polling (replaced by terminal-manager's wait\_for\_idle)
- Multi-tier routing fallback chains (terminal-manager is the single routing layer)

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-11 | Initial spec |
| 2026-04-11 | Initial implementation: main.py, registry.py, transport.py, setup.py, 8 hooks |
