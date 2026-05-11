# Terminal Manager — Functional Spec

## Overview

A **system script** that contributes MCP tools into AskMac's central tool
namespace. App scripts call these tools through their existing AskMac MCP
connection — they have no awareness of terminal-manager directly. AskMac routes
the calls internally.

Terminal-manager has no iPhone UI responsibilities — no blocks, no CloudKit. App
scripts remain responsible for their own cards and responses.

---

## Script Types

Scripts declare a `type` in their `manifest.json`:

All scripts are persistent services — AskMac starts them and keeps them alive.
The `type` field controls only who can call their tools:

| Type | Tools callable by | Emits blocks to iPhone |
|---|---|---|
| `tile` | iPhone app + other scripts | Yes |
| `feed` | iPhone app + other scripts | Yes |
| `system` | Other scripts only | No |

**System scripts contribute their tools to AskMac's MCP server** the same way
tile/feed scripts do. Any script can call them through its existing AskMac
connection — no separate connections, no service discovery.

---

## Architecture

```
iPhone
  │  (CloudKit)
  ▼
AskMac  ──────────────────────────────────────────────┐
  │                                                   │
  │  MCP namespace (what scripts can call):           │
  │  ┌─────────────────────────────────────────────┐  │
  │  │  from tile scripts:  emit_block, clear_block │  │
  │  │  from system scripts: register_session,      │  │
  │  │    detect_tui, send_key, send_text, ...      │  │
  │  └─────────────────────────────────────────────┘  │
  │                                                   │
  ├── codex-controller (tile)                         │
  │     calls: register_session, detect_tui, send_key │
  │     calls: emit_block  ──────────────────────────►│─► iPhone
  │                                                   │
  ├── claudecode-controller (tile)                    │
  │     calls: register_session, detect_tui, send_key │
  │     calls: emit_block  ──────────────────────────►│─► iPhone
  │                                                   │
  └── terminal-manager (system)  ◄── AskMac routes   │
        provides: register_session, detect_tui,       │
                  send_key, send_text, read_output,   │
                  list_sessions                       │
```

App scripts call one MCP endpoint. AskMac routes system tool calls to the
appropriate system script internally. App scripts just call tools by name.

---

## Sessions

### Session types

| Type | Read mechanism | Write mechanism |
|---|---|---|
| **Terminal.app** | AppleScript `history of t` | AppleScript `key code` / `keystroke` |
| **tmux** | `tmux capture-pane` | `tmux send-keys` |
| **PTY** (future) | PTY master fd | PTY master fd |

### Session registration

App scripts call `register_session` when a session starts, providing a TTY path
or tmux target and an optional **hook config** — a descriptor that tells
terminal-manager which TUI patterns to scan for in that session's output.

---

## TUI Hook Config

Passed by the app script at registration. Tells terminal-manager what to look
for. Terminal-manager returns structured detection results; the app script
decides what to do with them.

```json
{
  "scan_lines": 80,
  "patterns": [
    {
      "id": "model_selector",
      "detect": {
        "type": "numbered_menu",
        "footer": "Press enter to confirm"
      }
    },
    {
      "id": "slash_commands",
      "detect": {
        "type": "slash_command_list",
        "commands": [
          { "cmd": "/model",        "desc": "choose model and reasoning effort" },
          { "cmd": "/fast",         "desc": "toggle Fast mode" },
          { "cmd": "/permissions",  "desc": "choose what Codex is allowed to do" },
          { "cmd": "/experimental", "desc": "toggle experimental features" },
          { "cmd": "/skills",       "desc": "use skills to improve Codex" },
          { "cmd": "/review",       "desc": "review changes and find issues" },
          { "cmd": "/rename",       "desc": "rename the current thread" },
          { "cmd": "/new",          "desc": "start a new chat" }
        ]
      }
    },
    {
      "id": "toggle_menu",
      "detect": {
        "type": "checkbox_menu",
        "footer": "Press space to select"
      }
    }
  ]
}
```

---

## Built-in Detectors

| Detector | Params | Returns on match |
|---|---|---|
| `numbered_menu` | `footer` | `{ title, options[], current_index }` |
| `slash_command_list` | `commands[]` | `{ commands[] }` — fires when `› /` visible; returns full static list |
| `checkbox_menu` | `footer` | `{ title, options[{label, checked}], current_index }` |
| `text_prompt` | `pattern` (regex) | `{ prompt_text }` |
| `keyword_match` | `keywords[]` | `{ matched_keywords[] }` |
| `custom` | `expr` (Python string) | whatever the expression returns |

---

## MCP Tools

These are contributed to AskMac's namespace. App scripts call them with no
knowledge of terminal-manager.

### `register_session`
Register a session for monitoring.

Parameters:
- `session_id` — caller-assigned ID
- `tty` — full TTY path (e.g. `/dev/ttys003`), OR
- `tmux_target` — tmux session/window/pane target
- `app_id` — which script owns this session
- `hook` — hook config (optional)

### `unregister_session`
Stop monitoring and remove the session.
Parameters: `session_id`

### `detect_tui`
Run hook patterns against recent session output. Returns the first match.

Parameters: `session_id`
Returns: `{ pattern_id, result }` or `{ pattern_id: null }`

### `read_output`
Return recent output lines.
Parameters: `session_id`, `lines` (default 80)
Returns: `{ lines: [string] }`

### `send_key`
Send a named key to the session.
Parameters: `session_id`, `key` — `up` `down` `left` `right` `enter` `escape` `space` `tab` `ctrl_c` `ctrl_u`

### `send_text`
Clear the input line, type a string, press Enter.
Parameters: `session_id`, `text`

### `send_raw`
Write a raw string to the session without modification.
Parameters: `session_id`, `text`

### `list_sessions`
Return all registered sessions.
Returns: `{ sessions: [{ session_id, type, tty, tmux_target, app_id }] }`

---

## Example: Codex Controller Flow

```
# Session start
codex-controller → register_session(session_id, tty="/dev/ttys003",
                                    app_id="codex-controller", hook={...})

# Polling loop (1.5s cadence in codex-controller)
codex-controller → detect_tui(session_id)
                ← { pattern_id: "slash_commands",
                    result: { commands: ["/model", "/fast", ...] } }

# codex-controller handles the result
codex-controller → emit_block(...)   # its own iPhone card
                ← user taps "/model"
codex-controller → send_text(session_id, "/model")
codex-controller → detect_tui(session_id)   # verify cleared
                ← { pattern_id: null }
codex-controller → clear_block(...)
```

---

## Polling

Terminal-manager does not poll on its own. App scripts call `detect_tui` from
their own loop. This keeps terminal-manager stateless on timing and lets each
app control its own cadence.

---

## Stale Detection Prevention

`detect_tui` scans only the last `scan_lines` lines (default 80). Old TUI
content in scrollback is never detected.

---

## Manifest

```json
{
  "id": "terminal-manager",
  "name": "Terminal Manager",
  "type": "system",
  "version": "1.0.0",
  "description": "Local terminal session registry and TUI detector. Tools are available to all scripts via AskMac MCP.",
  "entry": "main.py",
  "tools": [
    { "name": "register_session",   ... },
    { "name": "unregister_session", ... },
    { "name": "detect_tui",         ... },
    { "name": "read_output",        ... },
    { "name": "send_key",           ... },
    { "name": "send_text",          ... },
    { "name": "send_raw",           ... },
    { "name": "list_sessions",      ... }
  ]
}
```

---

## Compatibility Path

- `codex-controller` and `claudecode-controller` continue working unchanged today.
- Migration path: swap their internal TTY read / TUI detect code for calls to
  `detect_tui` and `send_key`; their block emission logic stays untouched.
- New scripts use these tools from day one.

---

## Non-Goals (v1)

- No PTY spawning.
- No SSH / remote sessions.
- No block emission.
- No polling — callers drive cadence.

---

## Change Log

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-04-04 | Initial spec |
| 0.2 | 2026-04-04 | Hook config pattern; detector/card/action specs |
| 0.3 | 2026-04-04 | Reframed as system script; app scripts own iPhone UI and polling |
| 0.4 | 2026-04-04 | System scripts contribute tools to AskMac MCP namespace; no script-to-script connections |
| 0.5 | 2026-04-04 | Dropped lifecycle field — all scripts are services; type controls iPhone visibility only |
| 0.6 | 2026-04-30 | Added session_alive (PID-based liveness), discover_sessions (process discovery with tmux resolution), interactive_prompt detector type; pid + registered_at fields on Session; list_sessions now includes alive status |
