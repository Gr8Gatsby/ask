# claude-3 Redesign — Functional Spec

**Status:** Draft for review  
**Date:** 2026-04-26  
**Version target:** 1.0.0

---

## Problem

The current claude-3 script is unreliable as a remote control layer:

1. **TTY injection fails on macOS 13+** — TIOCSTI is restricted; injected text is dropped silently
2. **TTY discovery is fragile** — heuristics (ps scan, lsof, cwd matching) miss sessions and create ghost sessions
3. **Session identity is ambiguous** — Claude Code's `raw_id`, the daemon's `session_id`, and the terminal `tty` are three different things that get mismatched
4. **Messages are not durable** — if the daemon crashes while a message is queued, it is lost

---

## Goals

- **100% delivery** of iPhone messages to Claude Code
- **100% delivery** of permission requests to iPhone
- **Zero session identity confusion** — one canonical ID per session
- **No lost events** — hook events and iPhone messages survive daemon restart
- **No TTY heuristics** — the daemon owns the terminal it controls

---

## Non-goals

- Controlling sessions the daemon did not start (view-only observation is fine)
- Supporting Claude Code launched in any terminal other than tmux (for full control)
- Backward compatibility with the existing session file format

---

## Core Principle: Hooks Are Observation-Only

**Hooks must never block, never control, and never interfere with Claude Code's execution.**

- Every hook fires, writes its event, and exits immediately
- No hook waits for a response from the daemon, iPhone, or any other process
- No hook returns a decision that alters Claude Code's behavior (e.g. approving/denying a tool)
- Other users or scripts may register additional hooks; our hooks must coexist safely

**Control is exclusively via `tmux send-keys`.** The daemon injects text into the terminal it owns. Hooks have no role in the control path.

---

## Functional Requirements

### 1. Session Lifecycle

**1.1** Sessions are started via the Ask app (`start_session` tool) or by the user running `ask start` from the CLI.

**1.2** The daemon launches Claude Code inside a tmux window it owns. The tmux session is named `ask`, windows are named by project (e.g. `ask:myrepo`).

**1.3** Claude Code's `raw_id` (from the `SessionStart` hook) becomes the canonical session ID. All subsequent hook events, CloudKit records, and iPhone messages use this ID.

**1.4** If Claude Code is started outside the daemon (externally launched), the session appears as **view-only**: hook events are visible on iPhone but iPhone cannot send messages or answer permission requests.

**1.5** Session state persists to disk. If the daemon restarts, it reads existing state and reattaches to live tmux windows.

**1.6** Sessions are marked stopped when: (a) the `SessionStop` hook fires, (b) the tmux pane exits, or (c) the daemon detects the pane has been dead for > 30 seconds.

---

### 2. Observation (Claude Code → iPhone)

**2.1** All hook events (SessionStart, PreToolUse, PostToolUse, PermissionRequest, SessionStop, PreCompact, PostCompact, UserPromptSubmit) are written to CloudKit before the hook returns.

**2.2** Hooks connect to the daemon via Unix socket with a short non-blocking timeout (100ms). If the daemon is unreachable, the hook writes the event to a local spool file and exits. The daemon drains the spool on startup.

**2.3** iPhone sees: session state, current tool, last assistant message, permission requests, and task feed entries — all in real-time.

**2.4** No observation event is ever discarded. If CloudKit write fails, it is retried with exponential backoff until it succeeds.

---

### 3. Control (iPhone → Claude Code)

**3.1** Messages from iPhone are written to CloudKit by the iOS app before the send is acknowledged to the user.

**3.2** The daemon polls CloudKit for pending messages addressed to each live session.

**3.3** Before injecting any message, the daemon confirms Claude Code is at an idle interactive prompt (not mid-output, not processing a tool). If not idle, the daemon waits (up to 30 seconds) and retries.

**3.4** Messages are injected via `tmux send-keys` into the window the daemon owns for that session. No TTY device is used.

**3.5** Messages are delivered in the order they were sent. If two messages are queued, the second is not injected until Claude Code returns to idle after the first.

**3.6** After injection, the daemon writes a delivery acknowledgment to CloudKit. If the injection fails (tmux window gone), the message is surfaced as undeliverable on iPhone.

**3.7** If the daemon crashes with messages in the delivery queue, the messages remain in CloudKit and are re-delivered when the daemon restarts and reattaches to the tmux session.

---

### 4. Permission Requests

**4.1** When Claude Code requests tool permission, the `PermissionRequest` hook fires and immediately writes the request to CloudKit, then exits. The hook does **not** block. Claude Code shows its native terminal permission prompt.

**4.2** The daemon reads the permission request from CloudKit and surfaces it on iPhone as a permission card.

**4.3** Two resolution paths exist — whichever fires first wins:
- **Terminal**: the user types a response at the tmux pane directly; Claude Code resolves natively
- **iPhone**: the user responds on iPhone; the iOS app writes the response to CloudKit; the daemon injects the response via `tmux send-keys` into the pane

**4.4** Before injecting an iPhone response, the daemon checks that the pane is still showing a permission prompt (idle, waiting for input). If the terminal has already moved on (user already responded), the injection is skipped.

**4.5** For sessions in **auto-approve** mode, the daemon injects the approval via `tmux send-keys` immediately without surfacing it to iPhone, consistent with the existing allowlist behavior.

---

### 5. Idle Detection

**5.1** The daemon reads tmux pane output to determine when Claude Code is at an interactive prompt. An interactive prompt is defined as: the pane ends with a `>` or `?` prompt pattern and no new output has appeared for 500ms.

**5.2** `wait_for_idle` is called before every injection (messages and permission responses).

**5.3** If idle is not detected within 30 seconds, the daemon logs a warning and does not inject. The message remains queued for the next idle window.

---

### 6. Session Identity

**6.1** The canonical session ID is Claude Code's `raw_id` (the UUID Claude Code generates per session, delivered via the `SessionStart` hook).

**6.2** The tmux window target (`ask:<project>`) is stored as a routing handle. Multiple fields are never used as competing identifiers.

**6.3** If two Claude Code instances share the same cwd, they are treated as distinct sessions (no merging by cwd).

---

### 7. Start Session UX

**7.1** `start_session` with a repo path opens a tmux window for that repo and launches Claude Code in it. If a live session already exists for that repo, it surfaces the existing session instead of creating a duplicate.

**7.2** `start_session` with no arguments shows a repo picker (existing behavior).

**7.3** If tmux is not installed, the tool returns an actionable error with an install command.

---

### 8. Backward Compatibility

**8.1** Existing `reply`, `stop_session` tool signatures are unchanged.

**8.2** The session state file format changes. Old state files are ignored (sessions will be rediscovered from live tmux windows on first start after upgrade).

---

## Architecture Summary

```
iPhone
  │ write message or permission response
  ▼
CloudKit  ◄──────────────────── Daemon (writes hook events + permission requests)
  │                                  ▲
  │ poll for messages/responses      │ Unix socket (hook events)
  ▼                                  │
Daemon ──── tmux send-keys ──► tmux pane (Claude Code)
             (wait_for_idle)         │
                                     │ hooks fire (non-blocking, fire-and-forget)
                                     ▼
                            Hook scripts ──► Unix socket ──► Daemon
                            (PermissionRequest hook exits immediately;
                             terminal prompt shown natively while
                             iPhone card shown in parallel)
```

---

## Change Log

| Date | Change |
|------|--------|
| 2026-04-26 | Initial draft |
| 2026-04-26 | Implemented: tmux launch path, fire-and-forget permissions, migrate_to_tmux, is_tmux session flag, tmux liveness check in heartbeat (claude-3 v0.3.0) |
| 2026-04-26 | Fixed stdin deadlock: _read_stdin now fires _handle_rpc_line as background task; extracted _dispatch_tool_call and _dispatch_notification. Fixed wait_for_pattern pattern to include ❯ (U+276F). (claude-3 v0.3.1) |
