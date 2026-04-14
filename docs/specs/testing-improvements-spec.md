# Functional Spec: Test Coverage Improvements

**Status:** Approved  
**Date:** April 9, 2026  

---

## Overview

The current test suite validates daemon logic with mocked inputs. This spec adds five new testing layers that move closer to production behavior, covering: hook scripts as real subprocesses, block payload contracts against the iOS schema, real tmux interaction, daemon restart end-to-end, and concurrency.

---

## Layer 1: Hook Script Subprocess Tests

### What

Run each hook `.py` file as a real subprocess — the same way Codex and Claude Code invoke them — with a controlled mock socket server and synthetic `stdin` payloads. Assert exit codes and what the hook sent over the socket.

### Why

The hook scripts are the actual entry points to the system. A bug in a hook (wrong field name, wrong exit code, broken allowlist logic) directly breaks the user experience. Currently nothing tests them as real executables.

### Hooks to cover

**codex-2:**

| Hook | Scenarios |
|---|---|
| `pre_tool_use.py` | Allow response → exit 0; Deny response → exit 2; daemon down → exit 0 (allow fallback); exact allowlist match → exit 0 no socket call; glob pattern match → exit 0 no socket call; glob no-match → exits via socket; preview truncated to 500 chars in socket payload; "Always Allow" → exit 0 and allowlist file updated |
| `session_start.py` | Sends `session_active` message with correct fields; daemon down → exits 0 silently |
| `post_tool_use.py` | Sends `tool_executed` with tool_name and last_message; daemon down → exits 0 silently |
| `session_stop.py` | Sends `session_active` with `is_working: false`; daemon down → exits 0 silently |

**claudecode-controller:**

| Hook | Scenarios |
|---|---|
| `permission_request.py` | No suggestions → options are `['Yes', 'No']`; with suggestions → options include `'Always allow Tool(path)'` labels; Allow → correct Claude decision JSON on stdout; Deny → decision with behavior=deny; Always-allow label → decision includes updatedPermissions; daemon down → exits 0 (fallback to console) |
| `pre_tool_use.py` | Sends `pre_tool_use` message with tool/preview/session_id; Bash preview truncated to 500; daemon down → exits 0 silently |
| `session_start.py` | Sends `session_start` with session_id, cwd, project; daemon down → exits 0 silently |

### Implementation

Each test starts a `threading.Thread` that listens on a Unix socket, accepts one connection, reads the message, and replies with a controlled value. The hook is run via `subprocess.run` with the socket path injected via env var and a JSON payload on `stdin`. The test asserts the exit code and the message received by the mock server.

---

## Layer 2: Block Payload Schema Validation

### What

Define the iOS-side payload schema (derived from `RemoteKitModels.swift`) as Python dicts with required/optional field specs. Assert every `emit_block` call in the test suite produces a conforming payload. Run this as a standalone validator against every block type the scripts emit.

### Why

The iOS `Codable` structs decode JSON strictly — a missing required field silently produces nil or crashes decoding. A field name typo (e.g., `is_workng`) renders silently wrong on device. Schema tests catch these at commit time, not after deploying to a device.

### Schemas to define (from `RemoteKitModels.swift`)

| Block type | Required fields | Optional fields |
|---|---|---|
| `agent_session` | `session_id` (str), `project` (str) | `cwd`, `last_message`, `is_working`, `current_tool`, `current_preview`, `tool_history` (list of `{tool,preview,ts}`), `is_headless`, `tty` |
| `confirmation` | `title` (str), `body` (str), `options` (list[str]) | `session_id`, `urgency`, `style` |
| `alert` | `title` (str), `body` (str) | `icon`, `urgency` |
| `tile` | `label` (str) | `status_color`, `body`, `action_required` |
| `start_session` | `repos` (list of `{name,path}`) | — |
| `activity_feed` | `session_id` (str), `project` (str), `entries` (list of `{tool,preview,ts}`) | — |
| `info_card` | `title` (str), `pairs` (list of `{key,value}`) | — |
| `quick_reply` | `title` (str), `options` (list[str]) | `description`, `allow_custom`, `urgency` |
| `diagnostics` | `version` (str), `hooks` (list), `hooks_ok` (bool), `socket_ok` (bool), `log_lines` (list[str]) | — |

### Known bug found during schema analysis

`codex-2` emits `info_card` with `{'title': ..., 'body': ...}` for the `__view_log__` action, but iOS expects `{'title': ..., 'pairs': [{key, value}]}`. `pairs` is non-optional in `RKInfoCardPayload` — decoding fails silently and the log view renders empty. **Fix as part of this implementation.**

---

## Layer 3: Real tmux Integration Tests

### What

Create an actual tmux session in the test process, `send-keys` known prompt strings into a pane, capture it with `tmux capture-pane`, run through `_parse_tmux_prompt`, and assert correct format detection. Also test that `_on_tmux_prompt_reply` actually delivers keystrokes to the pane.

### Why

Static strings don't have ANSI escape codes. Real tmux output does. The actual Claude Code trust prompt format may differ from what we assumed. Real keystroke delivery (Down, Enter) may have timing issues our static tests don't reveal.

### Scenarios

| Scenario | What it tests |
|---|---|
| Print a numbered menu to a pane, capture → parse | Numbered format detection with real tmux output |
| Print `Proceed? (y/n) ›` to a pane, capture → parse | y/n format with real output |
| Print arrow-prefix menu to a pane, capture → parse | Arrow format detection |
| Print plain terminal output, capture → parse | No false positives on normal output |
| Select option 2 from a numbered menu → verify tmux pane received `Down Enter Enter` | Keystroke delivery end-to-end |
| Send `y` for y/n → verify pane received `y Enter` | y/n reply delivery |

### Prerequisites

Tests skip automatically if `tmux` is not installed (CI-safe).

---

## Layer 4: Daemon Restart End-to-End Test

### What

Start daemon → fire `session_active` hook via socket → kill daemon with `SIGKILL` → start new daemon with same socket/file paths → verify the new daemon re-emits the session block within 5 seconds.

### Why

We added session persistence and tested the JSON round-trip in isolation. This test proves the actual crash-restart flow works: the daemon writes to disk, a new process reads it, and iOS would see the block reappear without needing the user to re-trigger a hook.

### Scenarios

| Scenario | Asserts |
|---|---|
| Kill and restart — session was active | New daemon emits `agent_session` block for the restored session |
| Kill and restart — session had `is_working: True` | Restored session block reflects the working state |
| Kill and restart — session TTL expired | Expired session is not re-emitted |
| Kill and restart — multiple sessions | All non-expired sessions reappear |

---

## Layer 5: Concurrent Session Stress Test

### What

Fire multiple simultaneous hook events from separate threads (using the Unix socket directly), assert no sessions are lost, no permission futures resolve with wrong values, and no data races corrupt the session registry.

### Why

The daemon is async. Multiple sessions with interleaved permission requests share `_pending_permissions`, `_tool_block_map`, and `_sessions`. These have never been tested under concurrent load.

### Scenarios

| Scenario | Asserts |
|---|---|
| 10 simultaneous `session_active` events | All 10 sessions registered, no duplicates |
| 5 simultaneous permission requests from different sessions | Each resolves with the correct response, none cross-contaminate |
| Rapid tool fire + permission request interleaved | Permission block cleared after tool fires, not before |

---

## Bug Fix: info_card payload

Fix `codex-2/main.py` `_handle_picker_response` `__view_log__` case to emit `pairs` format instead of `body`:

```python
# Before (wrong)
await self.emit_block(block_id_log, 'info_card', {
    'title': ...,
    'body': log_text[-2000:],
}, ttl=60)

# After (correct)
await self.emit_block(block_id_log, 'info_card', {
    'title': ...,
    'pairs': [{'key': 'output', 'value': log_text[-2000:]}],
}, ttl=60)
```

---

## Implementation Order

1. Fix `info_card` bug (found during schema analysis)
2. Define payload schemas (`tests/payload_schemas.py` shared between both scripts)
3. Layer 2: Schema validation tests (smallest, highest leverage — catches the bug above)
4. Layer 1: Hook subprocess tests for codex-2 (most findings expected here)
5. Layer 1: Hook subprocess tests for claudecode-controller
6. Layer 3: Real tmux tests
7. Layer 4: Daemon restart E2E
8. Layer 5: Concurrent stress tests

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-09 | Initial draft |
