# Ask — Agent Integration Readiness Review

**Version:** 1.0  
**Date:** April 9, 2026  
**Author:** Kevin Hill  

---

## Executive Summary (1-Pager)

### Who, What, Why

**Ask** is a personal iOS + macOS application that lets you supervise AI coding agents running on your Mac — from your iPhone, from anywhere.

**Who it's for:** Developers who use AI coding agents (Claude Code, OpenAI Codex) for long-running tasks and want to stay in the loop without sitting at their desk. Whether you're approving a risky file deletion, answering a prompt, or just checking what your agent is up to — Ask surfaces the right moment to you on your phone.

**What it does:** Ask installs a lightweight daemon on your Mac that watches your AI agent sessions. When something needs your attention — a permission request, an interactive prompt, a question from the agent — it appears on your iPhone as a card. You respond with a tap. Your answer flows back to the terminal and the agent continues.

**Why it matters:** AI agents are increasingly doing real work autonomously. The missing piece is a remote control and supervision layer that feels native, fast, and reliable. Ask fills that gap with a tight CloudKit-backed pipeline between your Mac and iPhone, with no server infrastructure required.

---

### Feature Comparison: Codex vs Claude Code

| Feature | Codex (codex-2) | Claude Code (claudecode-controller) |
|---|---|---|
| **Version** | 1.5.21 | 2.23.25 |
| **Session Discovery** | Hook-driven (Codex fires on start) | Auto-discovers running `claude` processes via `ps` |
| **Session Identity** | Stable `tmux-{target}` ID survives restarts | TTY-based; stable across same terminal pane |
| **Permission Requests** | ✅ Blocks until iPhone responds | ✅ Blocks until iPhone responds (5-min timeout) |
| **Always Allow** | ✅ Allowlist in settings | ✅ Allowlist in settings |
| **Tool Activity Feed** | Partial (last message only) | ✅ Full 20-entry tool history timeline |
| **TUI / Interactive Prompts** | ✅ Via terminal-manager | Partial (regex-based numbered menus only) |
| **Session Chat (message reply)** | ❌ Not implemented | ✅ Can send messages to active sessions |
| **Start Session from iPhone** | ✅ Repo picker → tmux launch | ✅ Repo picker → tmux launch |
| **Stop Session from iPhone** | ❌ Not implemented | ✅ Interrupt signal supported |
| **Diagnostics Block** | ❌ No | ✅ Setup validation card |
| **Compact Summarization Hooks** | ✅ Hooks exist | ✅ Hooks exist |
| **Quick Reply** | ❌ Not implemented | ✅ Inline compact responses |
| **Notifications (transient)** | ✅ Push alert on session end | ✅ `notification.py` hook |
| **Session Persistence** | ❌ Lost on daemon restart | Partial (file-persisted but history not recovered) |
| **Multiple Concurrent Sessions** | ✅ (one block per session) | ✅ (one block per TTY) |
| **Test Coverage** | ✅ Integration + unit test suite | ❌ Limited test coverage |

---

### Gaps Summary (Ship-Blocking vs Nice-to-Have)

#### Ship-Blocking

| Gap | Affects |
|---|---|
| Codex sessions lost on daemon restart | Codex |
| No timeout/fallback if iPhone is unreachable (Codex) | Codex |
| Claude permission hook has 5-min timeout but no user-visible countdown | Claude |
| TUI prompt detection (Claude) is regex-only — fragile, misses complex UIs | Claude |
| No session chat for Codex (can't reply to agent from iPhone) | Codex |
| Claude activity feed capped at 20 entries with no scrollback | Claude |

#### Nice-to-Have (Post-Ship)

| Gap | Affects |
|---|---|
| Permission allowlist uses exact-match strings only (no glob/regex) | Both |
| Shared allowlist/settings across agents | Both |
| Session stop from iPhone for Codex | Codex |
| Clipboard routing (iPhone text → terminal) | Both |
| Cross-agent session visibility (see both Codex + Claude on one screen) | Both |
| Repo picker search/filter on large directory trees | Both |
| Block expiry cleanup in SwiftData when app is backgrounded | iOS |

---

## Technical Deep-Dive

---

### Architecture Overview

```
iPhone (Ask iOS App)
  │  CloudKit (iCloud private DB)
  ▼
AskMac Daemon
  ├─ codex-2 script  ←────────────  Codex CLI (OpenAI)
  │    hooks: session_start, pre_tool_use, post_tool_use,
  │           user_prompt_submit, session_stop
  │
  └─ claudecode-controller script  ←──  Claude Code (Anthropic)
       hooks: session_start, pre_tool_use, post_tool_use,
              permission_request, notification,
              pre_compact, post_compact, session_stop
```

**CloudKit schema (key records):**
- `RKBlock` — one record per active card emitted by any script. Contains blockType, payloadJSON, scriptID, icon.
- `RKResponse` — one record per user tap on iPhone. Drain-semantics: read once, deleted.
- `Machine` / `AskDevice` — heartbeat records for presence tracking.

**iOS sync strategy (triple-redundancy):**
1. `CKQuerySubscription` silent push when blocks change
2. Foreground refresh on every app launch/resume
3. 5-second poll while `HomeView` is visible

---

### Codex-2 — Technical Detail

**Version:** 1.5.21  
**Entry:** `ask/scripts/codex-2/main.py` (~1,700 lines)

#### How It Works

Codex-2 is a Python daemon that sits between Codex CLI and the iPhone. Codex fires shell hooks at lifecycle events (session start, before/after each tool use). The hooks connect to the daemon via a Unix socket and pass event payloads as JSON-RPC.

The daemon maintains an in-memory session registry, debounces CloudKit writes (0.5s), and delegates terminal I/O to the `terminal-manager` script via MCP tool calls.

#### Session Identity

Sessions are keyed to `tmux-{window_index}` (e.g., `tmux-project:0`), not to Codex's own ephemeral session UUIDs. This was a deliberate fix (v1.5.x) to give stable CloudKit block identities across Codex restarts within the same tmux pane. The `session_start.py` hook discovers the tmux target from the calling process's TTY and sends it to the daemon.

#### Permission Flow

```
Codex wants to run tool
  → pre_tool_use.py fires (hook script)
  → sends JSON-RPC to codex-2 daemon via socket
  → daemon emits confirmation block to CloudKit
  → user taps Allow/Deny on iPhone
  → daemon receives RKResponse (polled every 2s by AskMac)
  → delivers response to waiting hook via socket reply
  → pre_tool_use exits 0 (allow) or non-zero (deny)
  → Codex continues or skips tool
```

**Always Allow:** stored in `~/.ask/codex2-settings.json` as a list of exact command/tool strings. Checked before the block is emitted so there is zero latency for trusted commands.

#### TUI / Interactive Prompt Detection

All terminal-screen scraping is delegated to `terminal-manager`. Codex-2 registers each session via a `register_session` MCP call and receives TUI event callbacks when terminal-manager detects interactive content (numbered menus, slash-command pickers, checkbox lists).

When a TUI event arrives, the daemon emits a `confirmation` block with the menu options so the user can respond from iPhone. The selected option is sent back to the terminal as keystrokes via tmux `send-keys`.

#### Known Issues & Gaps

1. **Session loss on daemon restart.** Active session state is in-memory only. A daemon crash clears all sessions. The next heartbeat (60s) will re-create blocks for any sessions that fire another hook, but between crash and next hook call, iOS shows nothing.
   - *Fix path:* Persist session registry to `~/.ask/codex2-sessions.json` on every write (same pattern as claudecode uses).

2. **No message reply.** Users cannot send text to the Codex CLI from iPhone. The `reply` tool exists in claudecode-controller but was never implemented for codex-2.
   - *Fix path:* Add a `reply` tool that routes text to the tmux session via `send-keys`.

3. **No session stop.** There is no way to interrupt a running Codex session from iPhone.
   - *Fix path:* Add a `stop_session` tool that sends `C-c` to the tmux pane.

4. **Payload hash deduplication.** The daemon skips a CloudKit write if the new payload JSON hash matches the last emitted hash. This is a good optimization but could mask a legitimate re-emit of identical-content blocks (e.g., a permission request for the same tool twice in a row).

5. **Allowlist is exact-match strings.** No glob or regex support. `npm run build` and `npm run test` are treated as distinct entries.

6. **No permission timeout on Codex side.** The socket read in `pre_tool_use.py` blocks indefinitely. If AskMac is down or iPhone is unreachable, Codex freezes waiting for a response that will never come.
   - *Fix path:* Add a 10-minute read timeout with a fallback to "deny" (safer default).

7. **No diagnostics block.** Codex-2 has no equivalent to claudecode-controller's setup validation card. First-run failures surface only as missing blocks.

---

### Claudecode-Controller — Technical Detail

**Version:** 2.23.25  
**Entry:** `ask/scripts/claudecode-controller/main.py` (~2,200 lines)

#### How It Works

Claudecode-controller is a Python async daemon. Unlike codex-2 which relies entirely on Codex's own hook system, this controller also runs background process-discovery tasks that scan `ps` output for `claude` processes, resolving their TTY to identify active sessions. This dual approach (hooks + discovery) makes it more resilient to daemon restarts — a Claude process already running when the daemon starts will be rediscovered automatically.

#### Session Identity

Sessions are keyed to TTY (e.g., `s003`), discovered from the hook script's process parent chain. TTY-based identity means the same terminal pane always maps to the same CloudKit block, surviving both Claude restarts and daemon restarts. Sessions are persisted to `~/.ask/claudecode_sessions.json`.

#### Permission Flow

Identical structure to codex-2 but uses the dedicated `PermissionRequest` hook (a Claude Code-specific hook type) rather than `pre_tool_use`. This hook has first-class access to Claude's `permission_suggestions` — the set of rules Claude would auto-apply — which could be surfaced in the iOS UI but currently falls back to a simple Allow/Deny display.

**Timeout:** The `permission_request.py` hook has a 5-minute read timeout. On timeout, it falls through (allows the action) rather than denying. This is a deliberate UX choice to avoid blocking agents indefinitely, but it means a missed iPhone notification results in an implicit approval.

#### Session Chat (Reply)

Claudecode-controller implements `reply` — the only agent integration that allows sending text back to the agent from iPhone. The text is routed via terminal-manager, which writes it to the correct tmux pane's TTY. This makes the iOS conversation view genuinely interactive: you can steer Claude, answer its questions, or give it new instructions.

#### TUI / Interactive Prompts

Two layers:
1. **terminal-manager integration** — Sessions are registered with terminal-manager on startup. TM handles detection and routing for known TUI formats.
2. **tmux pane polling** — A per-session background task polls `tmux capture-pane` every 1–5 seconds and applies regex patterns to detect numbered menus. When a menu is detected, a confirmation block is emitted. When the menu disappears, the block is cleared.

The regex approach is fragile. It matches patterns like `  1. Option name` with a footer line containing `[enter]` or `[↵]`. This works for Claude Code's built-in permission dialogs but will miss any prompt format that differs from this exact layout.

#### Activity Feed

Every `pre_tool_use` and `post_tool_use` hook updates a per-session tool history list (capped at 20 entries). The last 20 tool invocations — name, input preview (truncated to 120 chars), timestamp, and status — are embedded in the `agent_session` block payload. iOS renders this as an inline timeline in `SessionChatView`.

The 120-char preview truncation is aggressive. Long shell commands, file paths, or multi-line search patterns are cut off in ways that make it hard to understand what Claude actually did.

#### Known Issues & Gaps

1. **TUI detection is regex-only.** The `tmux capture-pane` polling only catches simple numbered menus. The trust prompt (first-run directory approval), multi-select checkboxes, and any custom TUI that Claude Code might add are not guaranteed to be detected.
   - *Current state:* Trust prompt was recently fixed (commit `04a1efc`) and works. Other formats remain fragile.

2. **Activity feed capped at 20 / no scrollback.** Once a session exceeds 20 tool calls, older entries are dropped. There is no way to review a completed task's full tool history from iOS.
   - *Fix path:* Store full history in a local SQLite file; emit summary + recent N in the block payload; add a detail view in iOS.

3. **Permission suggestions not displayed.** Claude Code provides structured `permission_suggestions` (e.g., "allow Read in /Users/kevin/projects") but the iOS confirmation UI shows only Allow/Deny buttons with a raw tool name. The richer context is captured but not shown.

4. **5-minute timeout is silent.** When the permission timeout fires, the action proceeds. There is no iOS notification ("Permission auto-approved after timeout") and no indication in the session block that an implicit approval occurred.

5. **Process discovery race on startup.** When the daemon starts, it scans `ps` for `claude` processes. If a process started very recently, it may not yet have a registered TTY in terminal-manager. The session will appear but may have incorrect or missing TTY routing until the next discovery cycle.

6. **Session history not recovered after daemon restart.** Tool history (the activity feed) lives only in memory. A daemon restart clears it. Sessions are re-discovered but appear with an empty history.

7. **Clipboard routing removed.** An earlier version routed clipboard content from iPhone to terminal. This code path was removed. Copy-paste into a Claude session requires physical keyboard access.

8. **Limited test coverage.** codex-2 has a full integration + unit test suite (added in v1.5.x). claudecode-controller has no equivalent test coverage. Changes to the daemon risk regressions with no automated safety net.

---

### Shared Infrastructure

#### terminal-manager Script

Both controllers delegate terminal I/O to `terminal-manager`, a shared MCP script that:
- Discovers tmux sessions and panes
- Routes keystrokes to the correct pane via TTY or `send-keys`
- Detects TUI content (numbered menus, prompts)
- Fires callbacks to registered controllers

This is the single most critical shared dependency. A bug or restart of terminal-manager silently breaks TUI interaction for both agents simultaneously.

**Gap:** There is no health check or watchdog for terminal-manager. If it crashes, codex-2 and claudecode-controller continue running but TUI-related blocks stop appearing. Neither controller emits a diagnostic when terminal-manager is unreachable.

#### Ask SDK (`ask_sdk.py`)

Both scripts use a shared `ask_sdk.py` to emit blocks and read responses. This is the only abstraction layer between script logic and the AskMac MCP protocol. It is stable and well-tested in production.

#### Block Expiry & Cleanup

Blocks have a server-side TTL (set when emitted). Expired blocks are deleted from CloudKit automatically. However, SwiftData on iOS caches block records locally. If a block expires while the app is backgrounded, the stale record persists in the local store until the next foreground query refresh. This creates a brief window where the iOS UI shows blocks that no longer exist on the Mac.

---

### Pre-Ship Testing Checklist

The following scenarios are high-priority for manual QA before release:

#### Codex Scenarios
- [ ] Start Codex in a tmux session → verify session block appears on iOS
- [ ] Run a tool (e.g., file write) → verify permission block appears, Allow works, Deny works
- [ ] Always Allow a command → verify no block on subsequent calls
- [ ] Kill and restart the codex-2 daemon mid-session → verify session re-appears
- [ ] Start multiple Codex sessions in different tmux panes → verify each gets its own block
- [ ] TUI menu appears (slash commands, model picker) → verify it surfaces on iOS and selection works
- [ ] Codex session ends → verify block updates to idle state with last message
- [ ] Start new session from iPhone repo picker → verify tmux session launches

#### Claude Code Scenarios
- [ ] Start `claude` in a tmux pane → verify session block appears on iOS within 30s
- [ ] Run a tool → verify permission block appears, respond Allow/Deny, verify correct behavior
- [ ] Send a message from iPhone via SessionChatView → verify text appears in terminal
- [ ] Stop session from iPhone → verify `C-c` is delivered and Claude stops
- [ ] Trust prompt on first run in a new directory → verify it surfaces on iOS
- [ ] Kill and restart the claudecode-controller daemon mid-session → verify sessions re-discovered
- [ ] Run 25+ tools in a session → verify activity feed shows last 20 correctly
- [ ] Compact context summarization fires → verify pre/post blocks appear appropriately
- [ ] Diagnostics block shows correct setup state on first install

#### Cross-Cutting Scenarios
- [ ] Mac goes to sleep and wakes → verify blocks refresh correctly on iOS
- [ ] iPhone backgrounded during an active permission request → verify block still present on return
- [ ] Two blocks arrive simultaneously → verify both render, neither is lost
- [ ] AskMac daemon restart → verify both controllers reconnect and resume
- [ ] Block expires while app is backgrounded → verify stale block is gone after foreground
- [ ] Notification arrives for session end → verify it taps through to correct session

---

### Recommended Pre-Ship Work

Prioritized by impact and implementation effort:

#### P0 — Required for Ship

| Item | Script | Effort |
|---|---|---|
| Add read timeout to codex-2 `pre_tool_use.py` (prevent indefinite hang) | Codex | Small |
| Add test suite to claudecode-controller (match codex-2 coverage) | Claude | Medium |
| Fix TUI detection to handle at least 3 known prompt formats reliably | Claude | Medium |
| Surface permission timeout to iOS (notification + session block update) | Claude | Small |

#### P1 — High Value, Ship-Adjacent

| Item | Script | Effort |
|---|---|---|
| Persist codex-2 session registry to disk (survive daemon restarts) | Codex | Small |
| Add `reply` and `stop_session` tools to codex-2 | Codex | Medium |
| Increase activity feed preview from 120 to 300 chars | Claude | Tiny |
| Add terminal-manager health check + diagnostic block if unreachable | Both | Small |
| Display permission suggestions in iOS confirmation UI | Claude | Medium |

#### P2 — Post-Ship

| Item | Script | Effort |
|---|---|---|
| Glob/regex support in command allowlist | Both | Small |
| Shared allowlist across agents | Both | Medium |
| Full tool history stored in local file; detail view in iOS | Claude | Large |
| Clipboard routing (iPhone → terminal) | Both | Medium |
| Cross-agent session view (Codex + Claude on one screen) | iOS | Medium |
| Repo picker search/filter | Both | Small |

---

### Version Summary

| | Codex (codex-2) | Claude Code (claudecode-controller) |
|---|---|---|
| Version | 1.5.21 | 2.23.25 |
| Lines of code | ~1,700 | ~2,200 |
| Hook count | 6 | 9 |
| Block types emitted | 4 | 8 |
| Test suite | ✅ | ❌ |
| Message reply from iPhone | ❌ | ✅ |
| Session stop from iPhone | ❌ | ✅ |
| Daemon restart resilience | ❌ | Partial |
| TUI detection | ✅ (via TM) | Partial (regex) |
| Diagnostics block | ❌ | ✅ |
