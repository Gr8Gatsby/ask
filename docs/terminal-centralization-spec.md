# Terminal Manager Centralization — Functional Spec

## Goal

Centralize all terminal session lifecycle management — liveness checking, process
discovery, and routing — in terminal-manager. claude-3 and codex-3 delegate fully.
No terminal logic lives in individual script `transport.py` files after this refactor.

**Motivation:** The same logic (TTY liveness, tmux send, process discovery) is
duplicated across claude-3 and codex-3 with diverging implementations, making bugs
hard to find and fixes hard to land in one place. Centralizing in terminal-manager
gives a single point of truth, a single place to add logging, and a clear contract
for any future controller scripts.

---

## What terminal-manager Will Own After This Refactor

| Capability | Currently in | After |
|---|---|---|
| TTY liveness check | claude-3/transport.py, codex-3/transport.py | terminal-manager only |
| Tmux pane liveness | codex-3/transport.py (`pane_exists`), terminal-manager (`pane_alive`, unexposed) | terminal-manager only, exposed as `session_alive` |
| Process discovery | claude-3/transport.py (`discover_claude_processes`), codex-3/transport.py (`discover_codex_panes`, `discover_codex_processes`) | terminal-manager only (`discover_sessions`) |
| TTY→tmux resolution | codex-3/transport.py (`find_tmux_target_for_tty`) | terminal-manager internal, surfaced via `discover_sessions` |
| Direct tmux sends | codex-3/transport.py (`send_text`, `send_interrupt`, `send_quit`) | terminal-manager only |
| Routing decision (tmux vs inject_tty) | claude-3/main.py (`_route_text`), codex-3/main.py (`_route_text`) | terminal-manager internal, hidden behind `send_text` / `send_interrupt` |
| Interactive prompt detection | claude-3/transport.py (`parse_tmux_prompt`) | terminal-manager detector: `interactive_prompt` type |

---

## New and Changed Tool Contracts

### `register_session` (changed)

Adds an optional `pid` field. When provided, terminal-manager stores the PID
alongside tty/tmux_target and uses it for liveness checks via `kill -0`.

```
pid  (optional integer)  — PID of the process owning this session
```

Existing parameters and behavior unchanged. Backward compatible.

---

### `session_alive` (new)

Unified liveness check. Given a session_id, returns whether the session's
underlying process is still running.

**Parameters:** `session_id`

**Returns:** `{ alive: bool, reason: string }`

**Behavior by session type:**

| Session type | Check method |
|---|---|
| tmux | `tmux display-message #{pane_dead}` — pane not dead |
| TTY with stored PID | `os.kill(pid, 0)` — process exists |
| TTY without PID | `ps -t {tty}` returns at least one process |
| No routing (no tty, no tmux_target) | Always `alive: false` |

The `reason` field returns a short string for debugging: `"tmux_pane_dead"`,
`"pid_not_found"`, `"no_processes_on_tty"`, `"no_routing"`, `"alive"`.

**Replaces:** `tty_is_live()` in claude-3/transport.py; `tty_exists()` and
`pane_exists()` in codex-3/transport.py.

---

### `discover_sessions` (new)

Scans the running process table for instances of a given executable and returns
candidate sessions. For each match, resolves tmux context if the process is
running inside a tmux pane.

**Parameters:**
- `executable` — process name to match (e.g. `"claude"`, `"codex"`)
- `exclude_session_ids` (optional list) — session IDs already tracked; omit them from results

**Returns:** list of candidate sessions:
```json
[
  {
    "pid": 12345,
    "tty": "/dev/ttys003",
    "cwd": "/Users/kevin/code/myrepo",
    "tmux_target": "main:1.0"   // null if not in tmux
  }
]
```

**Behavior:**
- Uses `ps` to find matching processes
- For each process with a TTY, queries tmux to check if that TTY belongs to a pane
- Returns `tmux_target` if found, null otherwise
- Excludes processes whose TTYs are already registered and tracked

**Replaces:** `discover_claude_processes()` in claude-3/transport.py;
`discover_codex_processes()` and `discover_codex_panes()` in codex-3/transport.py;
`find_tmux_target_for_tty()` in codex-3/transport.py.

---

### `send_text` (contract clarified, no signature change)

Terminal-manager routes internally based on session type (tmux send-keys or
inject_tty via AppleScript). The caller never needs to know the session type.

**Replaces:** direct tmux `send_text()` in codex-3/transport.py;
`_route_text()` split logic in claude-3/main.py and codex-3/main.py.

---

### `send_interrupt` (contract clarified, no signature change)

Sends Ctrl-C to the session via the appropriate backend. Already exposed in
terminal-manager; codex-3 currently bypasses it with direct tmux calls.

**Replaces:** `send_interrupt()` in codex-3/transport.py.

---

### `interactive_prompt` detector type (new)

A new built-in detector type usable in hook configs passed to `register_session`.
Detects user-actionable prompts in terminal output.

**Detects:**

| Prompt style | Example | Returns |
|---|---|---|
| Numbered menu | `1) Option A\n2) Option B` | `{ type: "numbered", options: ["Option A", "Option B"] }` |
| Arrow cursor menu | Lines prefixed with `❯` or `›` | `{ type: "arrow", options: [...], selected_index: N }` |
| Binary y/n | `[Y/n]`, `[y/N]`, `(yes/no)` | `{ type: "binary", prompt_text: "..." }` |

**Usage in hook config:**
```json
{
  "id": "interactive_prompt",
  "detect": { "type": "interactive_prompt" }
}
```

**Replaces:** `parse_tmux_prompt()` in claude-3/transport.py. Claude-3 includes
this detector in its hook config at `register_session` time and handles the
structured result in its polling loop.

---

### `list_sessions` (extended)

Returns full session state for debugging, not just the summary fields.

**Returns per session:**
```json
{
  "session_id": "...",
  "type": "tmux | terminal_app",
  "tty": "...",
  "tmux_target": "...",
  "pid": 12345,
  "app_id": "claude-3",
  "alive": true,
  "alive_reason": "alive",
  "registered_at": 1714500000.0,
  "last_activity": 1714500120.0
}
```

`alive` and `alive_reason` are computed at call time using the same logic as
`session_alive`. This makes `list_sessions` a diagnostic snapshot of all terminal
sessions and their health without needing to call `session_alive` per session.

---

## What Scripts Remove After This Refactor

### claude-3/transport.py

Remove entirely:
- `tty_is_live()` — replaced by `session_alive` tool
- `discover_claude_processes()` — replaced by `discover_sessions` tool
- `parse_tmux_prompt()` — replaced by `interactive_prompt` detector type

Retain:
- `find_repos()` — Claude-specific git repo discovery, not terminal-management
- `discover_*` for repos if still needed

If nothing remains after removals, delete `transport.py` and its import in `main.py`.

### claude-3/main.py

- `_route_text()` becomes a single `send_text` tool call — routing decision removed
- `_monitor_tty_session()` polling loop calls `detect_tui` with `interactive_prompt`
  detector instead of calling local `parse_tmux_prompt()`
- `_refresh_sessions()` liveness check calls `session_alive` instead of `tty_is_live()`
- `_discover_active_processes()` calls `discover_sessions` instead of
  `discover_claude_processes()`

### codex-3/transport.py

Remove:
- `tty_exists()` — replaced by `session_alive`
- `pane_exists()` — replaced by `session_alive`
- `send_text()` — replaced by `send_text` tool call
- `send_interrupt()` — replaced by `send_interrupt` tool call
- `send_quit()` — replaced by `send_text(text="/quit")`
- `discover_codex_processes()` — replaced by `discover_sessions`
- `discover_codex_panes()` — replaced by `discover_sessions`
- `find_tmux_target_for_tty()` — moved into terminal-manager internals
- `get_pane_pid()` — terminal-manager uses this internally; remove from script layer

Retain:
- `find_repos()` — Codex-specific
- `ensure_repo_trusted()` — Codex-specific config writing
- `resolve_codex_bin()`, `launch_codex()` — Codex-specific process launching

### codex-3/main.py

- `_route_text()` becomes a single `send_text` tool call
- `_tm_send_interrupt()` becomes a single `send_interrupt` tool call
- Liveness checks (wherever they exist) use `session_alive`

---

## Testing

### Layer 1 — Unit tests (automated, run in CI)

All new terminal-manager logic must have unit tests before the PR is merged.
Each test must assert one specific behavior with a clear failure message.

**`session_alive` — one test per branch:**

| Test | Setup | Expected |
|---|---|---|
| `test_alive_pid_exists` | Register with pid; mock `os.kill` to succeed | `alive: true, reason: "alive"` |
| `test_dead_pid_not_found` | Register with pid; mock `os.kill` raises `ProcessLookupError` | `alive: false, reason: "pid_not_found"` |
| `test_alive_tty_has_process` | Register with tty, no pid; mock `ps -t` returns a row | `alive: true, reason: "alive"` |
| `test_dead_tty_device_exists_but_no_process` | Register with tty, no pid; mock `os.path.exists=True` but `ps -t` returns empty | `alive: false, reason: "no_processes_on_tty"` |
| `test_dead_no_routing` | Register with no tty, no tmux_target | `alive: false, reason: "no_routing"` |
| `test_dead_tmux_pane_dead` | Register with tmux_target; mock `#{pane_dead}=1` | `alive: false, reason: "tmux_pane_dead"` |
| `test_alive_tmux_pane_live` | Register with tmux_target; mock `#{pane_dead}=0` | `alive: true, reason: "alive"` |
| `test_unknown_session_id` | Call `session_alive` with unregistered id | error response |

**`discover_sessions` — one test per scenario:**

| Test | Mocked `ps` output | Expected |
|---|---|---|
| `test_discovers_process_no_tmux` | One matching process, TTY not in any tmux pane | Returns pid, tty, cwd; `tmux_target: null` |
| `test_discovers_process_in_tmux` | One matching process, TTY belongs to a tmux pane | Returns pid, tty, cwd, `tmux_target: "main:1.0"` |
| `test_excludes_already_tracked` | Two matching processes; one session_id in `exclude_session_ids` | Returns only the untracked one |
| `test_no_matches` | `ps` output has no matching executable | Returns empty list |
| `test_process_with_no_tty` | Process exists but TTY is `??` or empty | Included with `tty: null` |

**`interactive_prompt` detector — one test per prompt style:**

| Test | Terminal content | Expected |
|---|---|---|
| `test_detects_numbered_menu` | `"1) Option A\n2) Option B\nEnter number:"` | `type: "numbered", options: ["Option A", "Option B"]` |
| `test_detects_arrow_menu` | Lines with `❯` prefix | `type: "arrow", options: [...], selected_index: N` |
| `test_detects_binary_yn` | `"Continue? [Y/n]"` | `type: "binary", prompt_text: "Continue?"` |
| `test_detects_binary_yesno` | `"Are you sure? (yes/no)"` | `type: "binary", prompt_text: "Are you sure?"` |
| `test_no_prompt_no_match` | Normal Claude output, no prompt | No match (returns `null`) |
| `test_old_prompt_not_detected` | Prompt in scrollback beyond `scan_lines` window | No match |

**`list_sessions` with alive fields:**

| Test | Setup | Expected |
|---|---|---|
| `test_list_includes_alive_status` | Two sessions, one with live pid, one with dead pid | Each entry has `alive`, `alive_reason`, `pid`, `registered_at` |

**Regression tests — each named after the bug it prevents:**

| Test | What it guards |
|---|---|
| `test_no_routing_session_reports_dead` | No-tty + no-tmux session must not be `alive: true` under any condition |
| `test_tty_file_exists_but_process_gone` | `os.path.exists(tty)=True` + `ps -t` empty → must be dead (the false-positive that caused 53 stale sessions) |

---

### Layer 2 — tmux integration test (required before merge, run locally)

A scripted test in `test_local.py` (or a new `test_integration.py`) that requires
a real tmux installation (always present on dev machine) but no manual interaction:

```
1. Create a tmux pane running: tmux new-session -d -s test_session "sleep 1000"
2. Get the pane's TTY and PID
3. Register the session with terminal-manager (real subprocess)
4. Call session_alive → assert alive: true
5. Kill the sleep process: kill {pid}
6. Call session_alive → assert alive: false, reason: pid_not_found
7. Verify TTY device file still exists (os.path.exists) to confirm the false-positive scenario
8. Verify session_alive still returns false despite the device file existing
9. Kill the tmux session: tmux kill-session -t test_session
10. Call session_alive → assert alive: false, reason: tmux_pane_dead
11. Clean up
```

This test runs with `pytest -m integration` and is skipped in CI if tmux is
absent. It is required to pass locally before any PR that touches `session_alive`
or `discover_sessions`.

---

### Layer 3 — What stays manual

- Real AppleScript injection into Terminal.app / iTerm2
- Real Gatekeeper / notarization behavior
- iPhone app end-to-end (tap → block appears → session visible)

These cannot be automated. The manual smoke test after each deploy:
1. `list_sessions` shows correct alive status for known running Claude sessions
2. Sending a message from iPhone reaches the Claude session
3. Killing a Claude process causes the session to be cleaned up within one refresh cycle

---

## Acceptance Criteria

1. Neither claude-3 nor codex-3 contains `os.path.exists` on a TTY path.
2. Neither script calls `tmux` via subprocess directly.
3. Neither script uses `ps` directly for process discovery.
4. `session_alive` returns `alive: false` for a session whose process has exited, even
   if the TTY device file still exists (the false-positive case the old check had).
5. `discover_sessions("claude")` returns `tmux_target` for Claude processes running
   inside tmux panes, and `null` for those running in native Terminal.app windows.
6. Interactive prompt detection (`y/n`, numbered menus, arrow menus) works the same
   as before from the user's perspective in the iPhone app.
7. `list_sessions` output is sufficient to diagnose a stale session without reading
   any script log file — it shows pid, alive status, and registered_at.
8. All session liveness decisions in `_refresh_sessions()` (claude-3) go through
   terminal-manager — no local fallback path.
9. All Layer 1 unit tests pass in CI.
10. Layer 2 integration test passes locally before merge.

---

## Out of Scope

- PTY spawning
- SSH / remote sessions
- Changing polling cadence (scripts still drive their own loops)
- Changes to block emission or CloudKit logic

---

## Implementation Order

1. terminal-manager: add `session_alive`, `discover_sessions`, `interactive_prompt`
   detector, extended `list_sessions`, PID storage in `register_session`
2. claude-3: remove transport.py terminal functions, update main.py to delegate
3. codex-3: remove transport.py terminal functions, update main.py to delegate
4. Bump manifest versions for all three scripts
5. Deploy and verify with `list_sessions` showing correct alive status

---

## Change Log

| Date | Change |
|---|---|
| 2026-04-30 | Initial spec |
