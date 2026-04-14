# Ask — Agent Integration Readiness Review

**Version:** 2.0  
**Date:** April 9, 2026  
**Author:** Kevin Hill  
**Status:** Pre-ship gaps resolved — ready for QA

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
| **Version** | **1.6.0** | **2.24.0** |
| **Session Discovery** | Hook-driven (Codex fires on start) | Auto-discovers running `claude` processes via `ps` |
| **Session Identity** | Stable `tmux-{target}` ID survives restarts | TTY-based; stable across same terminal pane |
| **Permission Requests** | ✅ Blocks until iPhone responds | ✅ Blocks until iPhone responds |
| **Always Allow** | ✅ Glob/fnmatch patterns supported | ✅ Via Claude's permission suggestions |
| **Tool Activity Feed** | Partial (last message only) | ✅ Full 20-entry tool history timeline |
| **TUI / Interactive Prompts** | ✅ Via terminal-manager (3 formats) | ✅ Via tmux polling (3 formats: numbered, y/n, arrow) |
| **Session Chat (message reply)** | ✅ `reply` tool | ✅ `reply` tool |
| **Start Session from iPhone** | ✅ Repo picker → tmux launch | ✅ Repo picker → tmux launch |
| **Stop Session from iPhone** | ✅ `stop_session` tool | ✅ `stop_session` tool |
| **terminal-manager Health Check** | ✅ Alert block if TM unreachable | ✅ Alert block if TM unreachable |
| **Permission Suggestions** | N/A (allowlist-based) | ✅ Full labels shown on iPhone |
| **Diagnostics Block** | ✅ TM health alert | ✅ Setup validation card |
| **Compact Summarization Hooks** | ✅ Hooks exist | ✅ Hooks exist |
| **Notifications (transient)** | ✅ Push alert on session end | ✅ `notification.py` hook |
| **Session Persistence** | ✅ Disk-persisted, survives restarts | ✅ Disk-persisted, survives restarts |
| **Multiple Concurrent Sessions** | ✅ (one block per session) | ✅ (one block per TTY) |
| **Test Coverage** | ✅ 32 tests | ✅ 27 tests |

---

### Gaps Resolved

All ship-blocking and high-value pre-ship gaps have been addressed. The table below shows what changed between v1.0 and v2.0 of this review.

| Gap | Was | Now |
|---|---|---|
| Codex sessions lost on daemon restart | ❌ | ✅ Persisted to disk |
| Codex reply from iPhone | ❌ | ✅ `reply` MCP tool |
| Codex stop session from iPhone | ❌ | ✅ `stop_session` MCP tool |
| TUI detection (Claude) missed y/n and trust prompts | ❌ Partial | ✅ 3 formats handled |
| terminal-manager failure was silent | ❌ | ✅ Alert block emitted |
| Permission suggestions buried | ❌ | ✅ Full labels shown on iPhone |
| Tool preview too short (120–200 chars) | ❌ | ✅ 500 chars across all hooks |
| Allowlist exact-match only | ❌ | ✅ Glob patterns (`npm run *`) |
| claudecode had no test suite | ❌ | ✅ 27 tests, all passing |

### Remaining Known Limitations (Post-Ship)

| Item | Affects |
|---|---|
| Activity feed capped at 20 entries; no scrollback | Claude |
| Shared allowlist across both agents | Both |
| Clipboard routing (iPhone text → terminal paste) | Both |
| Cross-agent session view (Codex + Claude on one screen) | iOS |
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

**Version:** 1.6.0  
**Entry:** `ask/scripts/codex-2/main.py`  
**Tests:** 32 passing

#### How It Works

Codex-2 is a Python daemon that sits between Codex CLI and the iPhone. Codex fires shell hooks at lifecycle events (session start, before/after each tool use). The hooks connect to the daemon via a Unix socket and pass event payloads as JSON-RPC.

The daemon maintains a session registry (persisted to disk), debounces CloudKit writes (0.5s), and delegates terminal I/O to the `terminal-manager` script via MCP tool calls.

#### Session Identity

Sessions are keyed to `tmux-{window_index}` (e.g., `tmux-project:0`), not to Codex's own ephemeral session UUIDs. This gives stable CloudKit block identities across Codex restarts within the same tmux pane. The `session_start.py` hook discovers the tmux target from the calling process's TTY and sends it to the daemon.

#### Session Persistence

Session state is written to `~/.ask/codex2-sessions.json` on every change. On daemon restart, sessions are restored from disk and their blocks are immediately re-emitted to CloudKit. Entries older than 300 seconds are pruned on load. This means a daemon crash no longer causes sessions to vanish from iOS.

#### Permission Flow

```
Codex wants to run tool
  → pre_tool_use.py fires (hook script)
  → checks allowlist (glob patterns supported)
  → sends JSON-RPC to codex-2 daemon via socket
  → daemon emits confirmation block to CloudKit
  → user taps Allow / Always Allow / Deny on iPhone
  → daemon receives RKResponse (polled every 2s by AskMac)
  → delivers response to waiting hook via socket reply
  → pre_tool_use exits 0 (allow) or non-zero (deny)
  → Codex continues or skips tool
```

**Always Allow / Allowlist:** stored in `~/.ask/codex_allowlist.json`. Supports both exact-match strings (existing behavior) and glob patterns — entries containing `*` or `?` are matched via `fnmatch`. This allows rules like `npm run *` or `git *` that cover entire command families. Checked before the block is emitted, so there is zero latency for trusted commands.

**Permission wait:** The hook blocks indefinitely until the user responds. If the user wants to respond from the terminal instead, they can — the hook detects the socket close and falls through.

#### Reply and Stop Session

Both are now available as MCP tools callable from iOS:

- **`reply`** — routes `message` to the session's tmux pane via terminal-manager `send_text`, followed by Enter. Allows steering Codex from the iPhone conversation view.
- **`stop_session`** — sends `C-c` to the tmux pane, interrupting the current Codex task.

#### TUI / Interactive Prompt Detection

All terminal-screen interaction is delegated to `terminal-manager`. Codex-2 registers each session via `register_session` and receives TUI event callbacks when terminal-manager detects interactive content (numbered menus, slash-command pickers, checkbox lists). The selected option is sent back to the terminal as keystrokes.

#### terminal-manager Health Check

On startup, after MCP initialization, codex-2 calls `list_sessions` on terminal-manager with a 5-second timeout. If terminal-manager is unreachable, an alert block is emitted to iOS: *"terminal-manager not running — TUI detection unavailable."* The block expires after 5 minutes.

#### Remaining Limitations

- **No diagnostics/setup validation block** (beyond the TM health check). First-run configuration failures surface only as missing session blocks.
- **Payload hash deduplication** may skip a re-emit if content is accidentally identical to the last emitted payload (e.g., a permission request for the same tool twice in a row). This is an optimization trade-off.

---

### Claudecode-Controller — Technical Detail

**Version:** 2.24.0  
**Entry:** `ask/scripts/claudecode-controller/main.py`  
**Tests:** 27 passing

#### How It Works

Claudecode-controller is a Python async daemon. Unlike codex-2 which relies entirely on Codex's own hook system, this controller also runs background process-discovery tasks that scan `ps` output for `claude` processes, resolving their TTY to identify active sessions. This dual approach (hooks + discovery) makes it more resilient to daemon restarts — a Claude process already running when the daemon starts will be rediscovered automatically.

#### Session Identity

Sessions are keyed to TTY (e.g., `s003`), discovered from the hook script's process parent chain. TTY-based identity means the same terminal pane always maps to the same CloudKit block, surviving both Claude restarts and daemon restarts. Sessions are persisted to `~/.ask/claudecode_sessions.json`.

#### Permission Flow

Uses the dedicated `PermissionRequest` hook — a Claude Code-specific hook type that provides structured `permission_suggestions`. These suggestions are now surfaced as human-readable option labels on the iOS confirmation block (e.g., *"Always allow Read(~/Documents/code/myproject)"*). Selecting one writes that rule back to Claude Code's own permission config.

**Permission wait:** Like codex-2, the hook blocks until the user responds. If the user responds in the terminal, the daemon detects the socket close and falls through without blocking Claude further.

#### Session Chat (Reply)

The `reply` tool routes text from the iOS conversation view through terminal-manager to the correct tmux pane TTY. This allows users to steer Claude, answer its questions, or give it new instructions without touching the keyboard.

#### TUI / Interactive Prompts

`_parse_tmux_prompt` detects three prompt formats by polling `tmux capture-pane` every 1–5 seconds:

| Format | Example | Reply Mode |
|---|---|---|
| Numbered menu | `1. Option A` + footer | Arrow keys + Enter (×2) |
| y/n inline | `Proceed? (y/n) ›` | Literal `y` or `n` + Enter |
| Arrow/trust prompt | `❯ Yes, proceed` / `  No, exit` | Arrow keys + Enter |

When a format is detected, a confirmation block is emitted to iOS with the extracted options. When the prompt disappears from the pane, the block is cleared automatically.

#### terminal-manager Health Check

Same pattern as codex-2 — a `list_sessions` call with a 5-second timeout at the end of `initialize()`. If TM is unreachable, `_tm_healthy` is set to `False` and an alert block is emitted. Integrates with the existing diagnostics block infrastructure.

#### Activity Feed

Every `pre_tool_use` and `post_tool_use` hook updates a per-session tool history list (capped at 20 entries). Tool previews are now captured at up to 500 characters. The last 20 invocations — name, preview, timestamp, status — are embedded in the `agent_session` block payload and rendered as an inline timeline in `SessionChatView`.

#### Remaining Limitations

- **Activity feed capped at 20 / no scrollback.** Full history is not persisted to disk. This is a P2 item.
- **Process discovery race on startup.** A `claude` process started in the last few seconds before daemon startup may not yet have a TTY registered in terminal-manager. The session appears but TTY routing is established on the next discovery cycle (within seconds).
- **Tool history lost on daemon restart.** Sessions are re-discovered and blocks re-emitted, but the in-memory tool history is cleared. Activity feed starts empty until new tools are called.

---

### Shared Infrastructure

#### terminal-manager Script

Both controllers delegate terminal I/O to `terminal-manager`, a shared MCP script that:
- Discovers tmux sessions and panes
- Routes keystrokes to the correct pane via TTY or `send-keys`
- Detects TUI content (numbered menus, prompts)

Both controllers now emit an alert block to iOS if terminal-manager is unreachable on startup, making TM failures visible rather than silent.

#### Block Expiry & Cleanup

Blocks have a server-side TTL. Expired blocks are deleted from CloudKit automatically. SwiftData on iOS caches block records locally — if a block expires while the app is backgrounded, the stale record persists until the next foreground query refresh. This is a known minor limitation (P2).

---

### Pre-Ship Testing Checklist

The following scenarios are high-priority for manual QA before release. Automated tests cover unit and integration behavior; these scenarios verify the full end-to-end user experience.

#### Codex Scenarios
- [ ] Start Codex in a tmux session → session block appears on iOS
- [ ] Run a tool → permission block appears; Allow works, Deny works
- [ ] Type `npm run build` once → tap "Always Allow" → run again → no block appears
- [ ] Type `npm run test` → verify `npm run *` pattern matches and auto-approves
- [ ] Kill and restart the codex-2 daemon mid-session → session reappears immediately on iOS
- [ ] Start multiple Codex sessions in different tmux panes → each gets its own block
- [ ] TUI menu (slash commands, model picker) → surfaces on iOS, selection routes back correctly
- [ ] Codex session ends → block clears; "No sessions" tile shown
- [ ] Start new session from iPhone repo picker → tmux session launches, block appears
- [ ] Send reply from iPhone → text appears in Codex terminal
- [ ] Tap Stop Session → C-c delivered, Codex stops
- [ ] Stop terminal-manager → verify "TM not running" alert block appears on iOS

#### Claude Code Scenarios
- [ ] Start `claude` in a tmux pane → session block appears within 30s
- [ ] Run a tool → permission block with "Always allow Read(~/...)" option appears
- [ ] Tap "Always allow" option → Claude Code config updated, no block on next use
- [ ] Send a message from iPhone via SessionChatView → text appears in terminal
- [ ] Stop session from iPhone → C-c delivered, Claude stops
- [ ] Trust prompt on first run in a new directory → surfaces on iOS, "Yes, proceed" routes correctly
- [ ] y/n inline prompt → appears as two-option card, correct key sent
- [ ] Kill and restart the claudecode-controller daemon mid-session → sessions re-discovered, blocks reappear
- [ ] Run 25+ tools → activity feed shows last 20; previews up to 500 chars visible
- [ ] Compact context summarization fires → pre/post blocks appear appropriately
- [ ] Diagnostics block shows correct setup state on first install
- [ ] Stop terminal-manager → verify "TM not running" alert block appears on iOS

#### Cross-Cutting Scenarios
- [ ] Mac goes to sleep and wakes → blocks refresh correctly on iOS
- [ ] iPhone backgrounded during active permission request → block still present on return
- [ ] Two permission blocks arrive simultaneously → both render, neither lost
- [ ] AskMac daemon restart → both controllers reconnect and session blocks reappear
- [ ] Block expires while app backgrounded → stale block gone after foreground
- [ ] Notification arrives for session end → taps through to correct session

---

### Version Summary

| | Codex (codex-2) | Claude Code (claudecode-controller) |
|---|---|---|
| Version | 1.6.0 | 2.24.0 |
| Hook count | 6 | 9 |
| Block types emitted | 5 | 8 |
| Test suite | ✅ 32 tests | ✅ 27 tests |
| Message reply from iPhone | ✅ | ✅ |
| Session stop from iPhone | ✅ | ✅ |
| Daemon restart resilience | ✅ | ✅ |
| TUI detection | ✅ (via TM, 3 formats) | ✅ (tmux polling, 3 formats) |
| Glob/pattern allowlist | ✅ | N/A (uses Claude suggestions) |
| Permission suggestions on iOS | N/A | ✅ |
| terminal-manager health check | ✅ | ✅ |
