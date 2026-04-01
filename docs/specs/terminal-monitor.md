# Terminal Session Monitor — Functional Specification

## Purpose

Provide scripts with a way to query which terminal sessions are currently active on the Mac, without each script implementing its own OS-level process scanning. The feature lives entirely in AskMac and is exposed to scripts as a new MCP tool. No data is emitted to the iOS app.

---

## Motivation

`claudecode-controller` and `codex-controller` each implement their own `_discover_active_processes()` function using `pgrep` + `lsof`. This is duplicated, runs in-process, and limited to the process names each controller knows about. A centralized service in AskMac can provide richer data (e.g. terminal app tab titles via AppleScript), be reused by any script, and serve as the foundation for more robust session liveness detection.

---

## New MCP Tool: `list_terminal_sessions`

Scripts call this tool via the existing JSON-RPC `tools/call` mechanism. It is a synchronous query — the Mac app responds immediately with current state.

### Request

```json
{
  "method": "tools/call",
  "params": {
    "name": "list_terminal_sessions",
    "arguments": {
      "filter": "claude"
    }
  }
}
```

### Arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `filter` | string | No | If provided, only return sessions whose process name contains this string (case-insensitive). Example: `"claude"`, `"codex"`. If omitted, return all interactive terminal sessions. |

### Response

```json
{
  "result": {
    "sessions": [
      {
        "pid": 1234,
        "name": "claude",
        "tty": "s003",
        "cwd": "/Users/kevin/code/ask",
        "tab_title": "ask — claude"
      }
    ]
  }
}
```

### Session Object Fields

| Field | Type | Always Present | Description |
|---|---|---|---|
| `pid` | int | Yes | Process ID |
| `name` | string | Yes | Process name (basename of executable) |
| `tty` | string | Yes | Controlling TTY (e.g. `s003`) |
| `cwd` | string | Yes | Working directory of the process |
| `tab_title` | string | No | Tab or window title from Terminal.app or iTerm2, if available |

### Error Behavior

- If the system call fails entirely, return an empty `sessions` array (never error)
- Individual processes that fail to resolve (e.g. permission denied on `lsof`) are silently skipped

---

## AskMac: `TerminalMonitorService`

A new Swift service in `AskMac/Sources/AskMac/Services/TerminalMonitorService.swift`.

### Responsibilities

- Scan for processes that have a controlling terminal (TTY != `?`)
- Resolve each process's working directory via `lsof`
- Optionally enrich with tab titles from Terminal.app and iTerm2 via AppleScript
- Return structured results synchronously to the MCP caller

### Data Collection

**Process scan:**
1. Run `pgrep -ax` to list all processes with their full command lines
2. For each candidate: run `ps -p {pid} -o tty=` — skip if result is `?` or empty
3. Run `lsof -a -p {pid} -d cwd -Fn` to get the working directory
4. Skip processes with CWD of `/` or `/private` (system processes)

**Tab title enrichment (best-effort, always attempted):**
- Query Terminal.app via AppleScript for tab names
- Query iTerm2 via AppleScript for session names
- Match tab titles to PIDs where possible; attach as `tab_title`
- Failures are silently ignored — tab title is omitted if unavailable

### Caching

- Results are cached for 5 seconds to avoid redundant `pgrep`/`lsof` calls if multiple scripts query simultaneously
- Cache is invalidated after 5 seconds or on the next query after expiry

### No Polling

- The service does not run on a background timer
- It is purely on-demand — called only when a script invokes `list_terminal_sessions`

---

## Integration with Existing Scripts

### `claudecode-controller` and `codex-controller`

Both scripts replace their internal `_discover_active_processes()` with a call to `list_terminal_sessions`:

- On startup: call `list_terminal_sessions` with `filter` set to their process name to seed initial sessions
- In the heartbeat: call `list_terminal_sessions` to detect newly started or dead sessions
- For liveness checks on non-pid sessions: check if the session's CWD appears in the response

This removes the `subprocess` dependency from both controllers for discovery purposes.

Both scripts expose a `call_tool(name, args)` method on their `MCPClient` that sends a `tools/call` request and awaits a response. `list_terminal_sessions` uses this same pathway.

---

## Tests

### AskMac: `TerminalMonitorServiceTests`

- Returns empty array when no processes match the filter
- Returns correct fields (pid, name, tty, cwd) for a known live process
- `filter` is case-insensitive and matches on process name substring
- Tab title is included when Terminal.app/iTerm2 AppleScript succeeds
- Tab title is omitted when AppleScript fails (graceful degradation)
- Cache returns the same result within 5 seconds without re-scanning
- Cache is invalidated after 5 seconds and a fresh scan is performed

### `claudecode-controller`: `test_list_terminal_sessions`

- `_discover_active_processes` calls `list_terminal_sessions` with `filter="claude"` via the MCP client
- A session is registered for each returned entry whose CWD is not already tracked
- A pid-session is marked dead and cleared when its CWD no longer appears in results
- No subprocess calls to `pgrep` or `lsof` remain in the controller

### `codex-controller`: `test_list_terminal_sessions`

- Same coverage as claudecode-controller with `filter="codex"`

---

## What This Does Not Do

- Does not emit any block to iOS
- Does not track session history or persist data
- Does not manage tmux sessions (tmux pane targeting remains in the individual scripts)
- Does not replace hook-based session registration — hooks remain the authoritative source for session IDs

---

## Changelog

- 2026-04-01 — v1.0 Initial spec
- 2026-04-01 — v1.1 Tab titles always included; `filter` kept general; script migration and tests added to scope
- 2026-04-01 — v1.2 Implementation complete; `TerminalMonitorService` in `AskMacCore` library target; `list_terminal_sessions` MCP tool added to `MCPConnection`; both controllers migrated; 11 Swift tests + 4 Python integration tests added
