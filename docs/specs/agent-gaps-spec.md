# Functional Spec: Agent Integration Gap Remediation

**Status:** Draft — Pending Review  
**Date:** April 9, 2026  

---

## Overview

This spec covers all gaps identified in the Ask Agent Readiness Review for both the codex-2 (OpenAI Codex) and claudecode-controller (Claude Code) scripts, plus related iOS changes. Work is organized into three priority tiers: P0 (ship-blocking), P1 (high-value pre-ship), and P2 (post-ship).

---

## P0 — Ship-Blocking Fixes

### P0-1: Codex sessions must survive daemon restarts

**Problem:** codex-2 session state lives only in memory. A daemon restart clears all sessions. Active Codex jobs become invisible on iOS until a subsequent hook fires.

**Requirement:** The daemon must persist session state to disk and restore it on startup, so sessions re-appear immediately after a daemon restart without waiting for the next hook event.

**Behavior:**
- On every session state change (register, update, stop), write session state to `~/.ask/codex2-sessions.json` (mirrors claudecode's `claudecode_sessions.json`).
- On startup, load sessions from disk and immediately re-emit their blocks to CloudKit.
- Prune sessions from disk whose TTL has expired (same 300s TTL used for blocks).
- Session file format mirrors claudecode: `{ session_id: { cwd, project, tty, tmux_target, last_message, last_seen } }`.

---

### P0-2: Claude TUI detection must handle all known Claude Code prompt formats

**Problem:** `_parse_tmux_prompt` uses a single regex that detects numbered lists with a "press enter" footer. This misses prompts that use different layouts, e.g. Claude Code's trust prompt, y/n inline prompts, and any future Claude Code UI changes.

**Requirement:** The TUI parser must reliably detect the following three prompt formats that Claude Code is known to produce:

**Format 1 — Numbered menu (existing):** Already handled. Keep.

**Format 2 — Yes/No / single-line inline prompt:**
```
Do you want to proceed? (y/n) ›
```
- Detect: line ending in `(y/n)`, `[y/N]`, `[Y/n]`, or `› ` with no preceding numbered options.
- Surface as a confirmation block with options `["Yes", "No"]`.
- Send `y` or `n` as the keystroke.

**Format 3 — Trust prompt (directory approval):**
```
Trust the files in this folder?
  ~/Documents/code/myproject

❯ Yes, proceed
  No, exit
```
- Detect: lines with `❯` or `>` prefix followed by text options (no numbers required).
- Surface as a confirmation block with the extracted options.
- Send the corresponding arrow-key navigation + Enter.

**Behavior:**
- `_parse_tmux_prompt` is refactored to try each format in priority order and return the first match.
- Each format returns a `(body, options, reply_mode)` tuple where `reply_mode` is `"numbered"`, `"yn"`, or `"arrow"`.
- `_on_tmux_prompt_reply` dispatches on `reply_mode` to send the correct keystrokes.

---

### P0-3: claudecode-controller test suite

**Problem:** claudecode-controller has no automated tests. codex-2 has a full integration + unit suite. Any change to the Claude controller risks regressions with no safety net.

**Requirement:** A test suite in `ask/scripts/claudecode-controller/tests/` that covers:
- `_parse_tmux_prompt`: all three formats (numbered menu, y/n, trust/arrow). Both match and no-match cases.
- `_handle_permission_request`: Allow, Deny, Always Allow, timeout.
- `_handle_pre_tool_use`: tool history cap at 20, preview truncation, debounce.
- `_load_sessions` / `_save_sessions`: round-trip, expired TTL pruning.
- `_discover_active_processes`: mock `ps` output, dedup on TTY.
- `_prune_dead_pid_sessions` / `_prune_dead_real_sessions`: correct eviction behavior.

Tests must be runnable via `pytest` with no real AskMac connection (use mock MCP client).

---

## P1 — High-Value Pre-Ship

### P1-1: Reply to Codex from iPhone

**Problem:** Users cannot send text to Codex from iPhone. claudecode-controller supports this but codex-2 does not.

**Requirement:** Add a `reply` MCP tool to codex-2 that sends a text message to an active Codex session.

**Behavior:**
- Tool params: `session_id` (string), `message` (string).
- Routes `message` to the session's tmux pane via `send-keys` followed by `Enter`.
- If session has no tmux target, falls back to TTY write via terminal-manager's `inject_tty` call.
- Updates session block to show the user's message in the activity area.
- Error response if `session_id` is unknown.

---

### P1-2: Stop Codex session from iPhone

**Problem:** Users cannot interrupt a running Codex session from iPhone.

**Requirement:** Add a `stop_session` MCP tool to codex-2.

**Behavior:**
- Tool params: `session_id` (string).
- Sends `C-c` to the session's tmux pane (or TTY).
- Updates session block working state to `false`.
- If session is not found, returns an error message.

---

### P1-3: Increase tool preview length

**Problem:** Both scripts truncate command previews to 200 characters. Long shell commands and file paths lose critical context.

**Requirement:** Increase the preview truncation limit from 200 to 500 characters in both:
- `codex-2/hooks/pre_tool_use.py`
- `claudecode-controller/hooks/permission_request.py`
- `claudecode-controller/hooks/pre_tool_use.py`

Also increase the in-block preview (embedded in the `agent_session` payload) from whatever its current limit is to 500.

---

### P1-4: terminal-manager health check and diagnostic

**Problem:** If terminal-manager crashes or fails to start, TUI detection silently stops working for both agents. Neither controller emits any diagnostic.

**Requirement:** Both controllers must detect terminal-manager unavailability and surface it.

**Behavior:**
- On startup, after MCP initialization, each controller attempts a lightweight `ping` or `list_sessions` call to terminal-manager.
- If the call fails or times out within 5 seconds, the controller logs the failure and emits a diagnostic/alert block: `"terminal-manager is not running — TUI detection unavailable"`.
- The diagnostic block clears automatically if terminal-manager becomes available on a subsequent heartbeat.
- For claudecode-controller specifically, this integrates with the existing `_emit_diagnostics_block()` — add a new diagnostic item for TM status.

---

### P1-5: Display permission suggestions in iOS confirmation UI

**Problem:** Claude Code's `permission_suggestions` are captured in the hook and passed to the daemon, but the iOS confirmation block only shows Allow/Deny buttons. The richer "Always allow Read in ~/Documents/code/myproject" options are lost.

**Requirement:** The confirmation block's `options` array must include the human-readable `always_allow_labels` from `permission_request.py`. These are already assembled in the hook — the daemon must not discard them.

**Current state:** The `options` array is already sent correctly from the hook (`['Allow', 'Always allow Read(~/Documents/code/myproject)', 'Deny']`). The daemon passes these through to the CloudKit payload unchanged. The iOS `ConfirmationView` renders whatever is in the `options` array. This may already be working — needs verification in manual QA. If broken, fix the payload pass-through.

---

### P1-6: Glob/regex support in command allowlist

**Problem:** The allowlist in both scripts uses exact string matching. `npm run build` and `npm run test` are separate entries. Users cannot approve "any npm run command" with one rule.

**Requirement:** The allowlist format must support simple glob patterns (using `fnmatch` semantics):
- `npm run *` — match any npm run subcommand
- `git *` — match any git command
- `pytest *` — match any pytest invocation

**Behavior:**
- Allowlist entries that contain `*` or `?` are treated as glob patterns; all others are exact-match (existing behavior, no breaking change).
- Both `codex-2/hooks/pre_tool_use.py` and any equivalent allowlist check in claudecode-controller are updated.
- Existing allowlist files are valid without migration — exact entries continue to work.

## P2 — Deferred (Post-Ship)

P2 items are out of scope for this sprint. See the readiness review doc for the full list.

---

## Implementation Order

| # | Item | Scope | Size |
|---|---|---|---|
| 1 | P0-1: Codex session persistence | codex-2 daemon | S |
| 2 | P0-2: Claude TUI format expansion | claudecode daemon | M |
| 3 | P1-3: Preview length increase | both hooks | XS |
| 4 | P1-1: Codex reply tool | codex-2 daemon | M |
| 5 | P1-2: Codex stop_session tool | codex-2 daemon | S |
| 6 | P1-4: terminal-manager health check | both daemons | S |
| 7 | P1-5: Permission suggestions verification + tests | claudecode tests | S |
| 8 | P1-6: Glob allowlist | both hooks | S |
| 9 | P0-3: claudecode test suite | claudecode tests | M |

---

## Out of Scope

- Changes to AskMac daemon internals (block emission, response polling, CloudKit schema)
- Changing the MCP protocol between daemon and scripts
- opencode-controller (separate script, separate roadmap)

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-09 | Initial draft |
| 2026-04-09 | Per review: remove permission timeout items (indefinite wait is correct behavior); defer all P2; simplify to 9 items |
| 2026-04-09 | Implemented all 9 items. codex-2 → v1.6.0, claudecode-controller → v2.24.0. All 59 tests pass. |
