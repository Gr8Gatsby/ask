# OpenCode Controller — Design Document

## Key Architecture Facts (from OpenCode docs)

1. **`opencode` (TUI)** starts both a server AND a TUI client in the terminal. The TUI is just
   a client talking to the server.
2. **`opencode serve`** is purely headless — no terminal session, no TUI. Pure HTTP API.
3. **Permissions are a first-class REST API** — `POST /session/:id/permissions/:permissionID`.
   No plugin-level blocking needed.
4. **TUI is controllable via API** — `/tui/append-prompt`, `/tui/submit-prompt`, etc. — these
   are the same endpoints IDE plugins use to drive the TUI.
5. **All message content streams via SSE** — `message.part.updated` — we never need to scrape
   the terminal screen for responses.
6. **TUI assigns a random port by default** — we must launch with `--port PORT` to know it.

---

## Two Operating Modes

### Mode A: TUI Mode (primary)
User runs `opencode --port PORT` in their terminal. Both TUI and server start. The user sees
the familiar TUI; we drive it via the HTTP API. Most users will use this mode.

### Mode B: Headless Mode (background tasks)
We start `opencode serve --port PORT`. No TUI, no terminal. Good for background agents and
tasks the user starts from iOS without needing to see a terminal. Responses surface entirely
on iOS via SSE streaming.

Terminal Manager is needed for Mode A (process discovery, TUI fallback). Mode B requires
no terminal interaction at all.

---

## Architecture

```
opencode TUI process              opencode HTTP server
  (running in terminal)  ←────→  (started by TUI or serve)
         │                                │
         │                        SSE event stream
         │                        REST API (OpenAPI 3.1)
         │                                │
         └──────────────┬─────────────────┘
                        │
              ┌─────────▼──────────────────────────────┐
              │         opencode-controller             │
              │  (Python MCP client, Ask script)        │
              ├─────────────────────────────────────────┤
              │  Session Registry                       │
              │  SSE Subscriber (per session)           │
              │  HTTP API Router                        │
              │  Heartbeat Tasks                        │
              └─────────┬───────────────────────────────┘
                        │
              ┌─────────┴──────────────┐
              │                        │
              ▼                        ▼
      terminal-manager           iOS Block Emitter
   (Mode A: process             (ask_sdk → AskMac
    discovery + fallback)        → CloudKit → iPhone)
              │
              ▼
      Terminal.app / tmux
```

---

## Components

### 1. `opencode-controller` (Python MCP client)

The main daemon. Runs as an Ask script (`type: tile`).

**Session metadata:**
```python
{
  "session_id": str,          # OpenCode session UUID
  "cwd": str,                 # Working directory (from project.current())
  "project_name": str,        # Display name
  "opencode_port": int,       # HTTP server port
  "opencode_pid": int | None, # TUI process PID (Mode A only)
  "tty": str | None,          # Terminal TTY (Mode A, fallback routing)
  "tmux_target": str | None,  # tmux target (Mode A, fallback routing)
  "mode": "tui" | "headless", # Operating mode
  "last_message": str,        # Last streamed assistant text
  "tool_history": list,       # Last 20 tool calls [{tool, preview, ts}]
  "pending_permission": dict | None, # Active permission request
}
```

**Initialization sequence:**
1. MCP handshake
2. Load persisted sessions from `~/.ask/opencode_sessions.json`
3. For each session: health-check `GET /global/health` on stored port
4. Drop dead sessions (port not responding)
5. Re-subscribe to SSE streams for live sessions
6. Re-register live TUI sessions with terminal-manager
7. Emit all session blocks to iOS
8. Emit `start_session` block (project/mode picker)
9. Emit `diagnostics` block
10. Scan for untracked `opencode` processes (heartbeat runs immediately)

**Input routing priority:**

| Priority | Method | Mode |
|----------|--------|------|
| 1 | `POST /tui/append-prompt` + `POST /tui/submit-prompt` | Mode A (TUI) |
| 2 | `POST /session/:id/message` | Mode B (headless) or Mode A fallback |
| 3 | `terminal-manager send_text` / `inject_tty` | Last resort |

For Mode A (TUI), appending to the prompt and submitting is preferred because it lets the user
see what was sent before it executes. The TUI shows the prefilled prompt before submission.

---

### 2. SSE Event Subscription

One SSE subscription per session, started on session registration.

```
GET http://localhost:{port}/event
```

**Event handling table:**

| Event | Action |
|-------|--------|
| `server.connected` | Log — server is alive |
| `session.created` | Register if unknown, emit session block |
| `session.idle` | Mark session inactive, stop streaming indicator on iOS |
| `session.error` | Emit error notification to iOS |
| `session.compacted` | Emit compact summary block |
| `message.part.updated` | Stream content to iOS agent_session block (incremental) |
| `message.updated` | Final message content — update block |
| `permission.asked` | Show confirmation block on iOS |
| `permission.replied` | Clear confirmation block |
| `tool.execute.before` | Update activity_feed on iOS |
| `tool.execute.after` | Update activity_feed (result/error) |
| `session.status` | Update running indicator on iOS |

**SSE subscriber (per session):**
```python
async def _subscribe_sse(self, session_id: str, port: int):
    import aiohttp
    async with aiohttp.ClientSession() as http:
        async with http.get(f"http://localhost:{port}/event") as resp:
            async for line in resp.content:
                event = _parse_sse_line(line)
                if event:
                    await self._handle_event(session_id, port, event)
```

---

### 3. Permission Handling

OpenCode has a native permission API. No plugin needed.

**Flow:**
```
SSE: permission.asked → {permissionID, sessionID, tool, description, ...}
  │
  ▼
controller: _emit_confirmation_block(session_id, permissionID, tool, description)
  │
  ▼
iOS: user taps Allow / Deny
  │
  ▼
controller: POST /session/{session_id}/permissions/{permissionID}
            body: { response: "allow" | "deny", remember: false }
  │
  ▼
SSE: permission.replied → controller clears confirmation block
```

The confirmation block on iOS includes:
- Tool name + description
- Allow / Deny buttons
- "Remember for this session" toggle (maps to `remember: true`)

---

### 4. Terminal Manager Integration (Mode A only)

Terminal Manager's role is reduced vs. `claudecode-controller` because:
- Responses come via SSE (no screen scraping)
- Input goes via TUI API (no TTY injection)
- TUI navigation goes via API (`/tui/open-models`, etc.)

Terminal Manager is still used for:

| Use | Tool | When |
|-----|------|------|
| Process discovery | (ps scan in heartbeat) | Find running `opencode` PIDs |
| Port discovery fallback | `read_output` | Read `opencode` startup output for port |
| TUI fallback input | `send_text` / `inject_tty` | If `/tui` API fails |
| Window focus | `focus_window` | Bring TUI to front from iOS |
| Register session | `register_session` | Mode A only, for fallback routing |

**Hook config for Mode A sessions:**
```json
{
  "scan_lines": 20,
  "patterns": [
    {
      "id": "idle_prompt",
      "detect": { "type": "keyword_match", "keywords": ["> "] }
    }
  ]
}
```
(Minimal — we don't need rich TUI detection since API handles navigation.)

---

### 5. `opencode-plugin` (TypeScript — optional, for enhanced experience)

The plugin is **not required** for core functionality (permissions, routing, streaming).
It adds:
- Pre-execution tool context injection (richer previews on iOS before tool runs)
- Custom tools surfaced on iOS
- Shell env injection (e.g., inject `ASK_SESSION_ID` for scripts to use)
- Compaction context injection

**Plugin location:** `~/.config/opencode/plugins/ask-bridge.ts` (global)

```typescript
import type { Plugin } from "@opencode-ai/plugin"

export const AskBridgePlugin: Plugin = async ({ client, project }) => {
  return {
    // Inject context into all shell executions
    "shell.env": async (input, output) => {
      output.env.ASK_ACTIVE = "1"
      output.env.ASK_PROJECT = project.path
    },

    // Richer compaction — inject task state
    "experimental.session.compacting": async (input, output) => {
      output.context.push("## Ask iOS Session\nUser is supervising from iPhone.")
    },
  }
}
```

Note: `tool.execute.before` and `tool.execute.after` events already arrive via SSE
(`tool.execute.before` / `tool.execute.after` event types) — no need to duplicate in plugin.

---

## Port Management

### Mode A: TUI sessions

The user (or controller) launches: `opencode --port PORT`

The controller pre-allocates a port:
```python
def _allocate_port() -> int:
    import socket
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]
```

The `start_session` tool launches:
```bash
# In new terminal via terminal-manager or osascript:
opencode --port {port}
```

Port is saved in session registry immediately. SSE subscription starts after
`GET /global/health` confirms the server is up (poll with 200ms interval, 10s timeout).

### Mode B: Headless sessions

Controller spawns subprocess:
```python
proc = await asyncio.create_subprocess_exec(
    'opencode', 'serve', '--port', str(port),
    cwd=project_path
)
```

No terminal interaction needed.

### Existing session detection

For `opencode` processes the user already started, the heartbeat scans:
```bash
ps aux | grep 'opencode'
```
Then checks process args for `--port PORT`. If no `--port` in args, the server is on the
default port `4096` (opencode's default). Controller attempts `GET localhost:4096/global/health`.

---

## iOS Block Types

### Reused from claudecode-controller

| Block | Purpose | TTL |
|-------|---------|-----|
| `tile` | Controller status card | 600s |
| `agent_session` | Per-session I/O + streaming output | 3600s |
| `start_session` | Project + mode picker | 620s |
| `confirmation` | Tool permission dialog | 300s |
| `session_event` | Started/stopped/errored notifications | 3600s |
| `activity_feed` | Tool history (last 20) | 3600s |
| `notification` | Toast notifications | 300s |
| `compact_summary` | Context compaction summary | 86400s |
| `diagnostics` | Server health + SSE status | 3600s |

### New for OpenCode

| Block | Purpose | Notes |
|-------|---------|-------|
| `share_session` | Shared session URL | `POST /session/:id/share` |

### `agent_session` streaming

Unlike claudecode-controller (which polls for idle), we get streaming chunks via SSE
`message.part.updated`. The block updates incrementally — each SSE chunk appends to the
displayed output. On `session.idle`, streaming stops and final content is locked in.

---

## MCP Tools (iOS-facing)

| Tool | Description |
|------|-------------|
| `reply` | Send text to active session (TUI API or direct message) |
| `start_session` | Launch opencode for a project (TUI or headless) |
| `approve` | Approve pending permission (`response: "allow"`) |
| `deny` | Deny pending permission (`response: "deny"`) |
| `stop_session` | Abort session + kill process if Mode A |
| `share_session` | Generate shareable session URL |
| `open_models` | Invoke `POST /tui/open-models` (Mode A only) |
| `open_sessions` | Invoke `POST /tui/open-sessions` (Mode A only) |

---

## Session Lifecycle

### Mode A start

```
iOS: user picks project + "TUI mode"
  │
controller: allocate port, spawn terminal with `opencode --port PORT`
  │
controller: poll GET /global/health until healthy (10s timeout)
  │
controller: GET /project/current → get cwd/name
  │
controller: create session entry in registry
  │
controller: start SSE subscription
  │
controller: register with terminal-manager (for fallback)
  │
controller: emit agent_session block to iOS
```

### Mode B start

```
iOS: user picks project + "Headless mode"
  │
controller: allocate port, spawn subprocess `opencode serve --port PORT`
  │
controller: poll GET /global/health until healthy
  │
controller: POST /session → create new OpenCode session
  │
controller: start SSE subscription
  │
controller: emit agent_session block to iOS
```

### Active turn

```
SSE: tool.execute.before {tool, args, sessionID}
  → controller: emit activity_feed update (tool name + preview)

SSE: permission.asked {permissionID, tool, description}
  → controller: emit confirmation block (blocks tool)
  → iOS user: taps Allow
  → controller: POST /session/:id/permissions/:permissionID {response: "allow"}
  → SSE: permission.replied → clear confirmation block

SSE: message.part.updated {content chunk}
  → controller: append to agent_session block (streaming)

SSE: session.idle
  → controller: finalize agent_session block, clear activity indicator
```

### Session stop

```
SSE: session.error OR port stops responding (heartbeat)
  → controller: emit session_event "stopped"
  → controller: unregister from terminal-manager
  → controller: remove from registry
```

---

## Heartbeat Tasks (5-minute interval)

1. Health-check all sessions: `GET /global/health` on each stored port
2. Drop sessions where port is dead
3. Scan `ps` for new `opencode` processes not in registry
4. For each discovered process: read `--port` arg or try default 4096
5. Attempt `GET /global/health` to confirm
6. Register newly discovered sessions, start SSE subscriptions
7. Re-emit all session blocks
8. Re-emit tile

---

## Comparison: claudecode-controller vs opencode-controller

| Aspect | claudecode-controller | opencode-controller |
|--------|----------------------|---------------------|
| Session detection | Process scan + hook socket | Process scan + HTTP health check |
| Session lifecycle events | Python hook scripts → Unix socket | SSE event stream |
| Input routing | TTY injection (primary) | `/tui/append-prompt`+`submit` (primary) |
| Response capture | `wait_for_idle` polling + screen read | SSE `message.part.updated` (streaming) |
| Permission handling | Hook blocks stdin, iOS resolves | SSE `permission.asked` → REST API |
| TUI navigation | terminal-manager `send_key` | REST `/tui/open-models` etc. |
| Terminal Manager role | Core (routing + response capture) | Reduced (discovery + fallback only) |
| Hook scripts needed | 9 Python scripts | 0 (optional TypeScript plugin) |
| Screen scraping | Yes (response capture) | No (all via API/SSE) |
| Streaming responses | No (polling) | Yes (SSE chunks) |
| Share session | No | Yes (`POST /session/:id/share`) |
| Headless mode | No | Yes (`opencode serve`) |

---

## Open Questions

1. **Does OpenCode write the active server port anywhere on disk?**  
   If so (e.g., `~/.cache/opencode/server.json`), we can auto-discover existing TUI sessions
   without process arg scanning.

2. **What exactly are the `tool.execute.before` / `tool.execute.after` SSE event payloads?**  
   The plugins docs show these as plugin hook names — are they also emitted as SSE event types?
   Need to verify in the OpenAPI spec at `/doc`.

3. **Does `opencode` default to port 4096 or truly random?**  
   Docs say "randomly assigns" but SDK default is 4096. If random, process arg scanning is
   required for untracked sessions. If 4096 is fixed default, simpler detection.

4. **`permission.asked` event payload** — what fields? Does it include tool name, description,
   and the full options list, or just a permissionID requiring a follow-up GET?

5. **Mode A + no `--port` flag** — if the user started `opencode` without our `--port` flag,
   can we still connect? Only if they used the default 4096 or we can find the port from ps args.

---

## iOS Block Design

The goal is **simplicity** — fewer surfaces, no redundant containers. OpenCode's richer
API (streaming, native permissions, share URLs) is expressed as extensions to existing
block types rather than new ones. New block types are introduced only where no existing
primitive fits.

### Existing blocks reused as-is

| Block | How used |
|-------|---------|
| `tile` | Controller status tile on home screen |
| `confirmation` | Tool permissions — three options: "Allow", "Allow for Session", "Deny" |
| `alert` | Session error, server unreachable |
| `feed_item` | Session started / stopped / errored events |
| `info_card` | Diagnostics (server health, SSE status, port) |
| `detail` | Share session — title "Session Link", body = URL, action "Copy" |

### Extensions to existing blocks

#### `agent_session` — four new optional fields

The session card is the primary surface. Tool activity and streaming state are expressed
inline rather than in a separate activity block.

```
+-----------------------------------------+
|  code/myapp [a3f9]                  ^   |
|  * Reading src/auth.ts                  |  ← current_tool_preview (while working)
|                                         |
|  +---------------------------------+    |
|  | I've updated the middleware.    |    |  ← last_message (after idle)
|  | All 42 tests pass.              |    |
|  +---------------------------------+    |
|                                         |
|  claude-opus-4-6 · headless        (->)  |  ← model + mode
|  +-----------------------------+        |
|  | Reply...                    |        |
|  +-----------------------------+        |
+-----------------------------------------+
```

| New Field | Type | Description |
|-----------|------|-------------|
| `current_tool` | `String?` | SF Symbol name for the tool running (`doc.text`, `terminal`, `network`, …) |
| `current_tool_preview` | `String?` | One-line description shown while `is_working` is true |
| `mode` | `String?` | `"tui"` or `"headless"` — shown as a subtle label below the reply field |
| `model` | `String?` | Model short name (e.g. `claude-opus-4-6`) — shown alongside mode |

`current_tool_preview` replaces a generic spinner with a meaningful description:
`Reading src/auth.ts` · `Running npm test` · `Searching for AuthMiddleware`.

On `session.idle`, `current_tool` and `current_tool_preview` are cleared. `last_message`
is set to the final response text.

#### `start_session` — mode selector

Adds an optional `modes` array. If present, the repo picker sheet shows a segmented
control or inline picker above the repo list. The response value changes from a bare
path string to a JSON object.

```
+-----------------------------------------+
|  + Start Session                        |
|                                         |
|  +-------+ +----------+                 |
|  |  TUI  | | Headless |                 |  ← mode picker (if modes present)
|  +-------+ +----------+                 |
|                                         |
|  code/myapp                        >    |
|  code/api-server                   >    |
|  code/dashboard                    >    |
+-----------------------------------------+
```

| New Field | Type | Description |
|-----------|------|-------------|
| `modes` | `[{id, label, detail}]?` | Available launch modes. If absent, no mode picker shown (defaults to TUI) |
| `modes[].id` | `String` | Response value: `"tui"` or `"headless"` |
| `modes[].label` | `String` | Display label: `"TUI"` / `"Headless"` |
| `modes[].detail` | `String?` | One-line explanation shown below label |

Response (when `modes` present): `{"path": "/Users/kevin/code/myapp", "mode": "tui"}`  
Response (when `modes` absent): `"/Users/kevin/code/myapp"` (unchanged, backward-compatible)

### New blocks

#### `session_share`

Surfaces the shareable URL from `POST /session/:id/share`. Distinct from `detail` because
it has a single focused action (copy) and renders the URL in a fixed-width copyable field
rather than prose text. Disappears when the user copies or dismisses.

```
+-----------------------------------------+
|  Session Link                           |
|                                         |
|  +-------------------------------------+|
|  | https://opencode.ai/s/a3f91c2b     ||  ← tap to copy
|  +-------------------------------------+|
+-----------------------------------------+
```

Payload:

| Field | Type | Description |
|-------|------|-------------|
| `title` | `String` | Header (e.g. `"Session Link"`) |
| `url` | `String` | The full shareable URL |
| `session_id` | `String?` | Links this to an agent session for grouping |

Response: any value (iOS dismisses the block on tap). Controller then calls
`DELETE /session/:id/share` if the user taps a "Stop Sharing" action.

No response required for the basic copy case — block auto-expires at 300s.

---

### Block mapping summary

| OpenCode event / action | Block emitted |
|------------------------|---------------|
| Session registered | `agent_session` (new or refresh) |
| `tool.execute.before` | `agent_session` update (`is_working=true`, `current_tool`, `current_tool_preview`) |
| `tool.execute.after` | `agent_session` update (clear tool fields) |
| `message.part.updated` | `agent_session` update (`last_message` incremental append, `is_working=true`) |
| `session.idle` | `agent_session` update (`is_working=false`, clear tool fields, final `last_message`) |
| `permission.asked` | `confirmation` (3 options, linked `session_id`) |
| `permission.replied` | delete `confirmation` block |
| `session.error` | `alert` |
| `session.created` | `feed_item` |
| `session.compacted` | `feed_item` (brief summary text) |
| Session stopped | `feed_item` + delete `agent_session` |
| `POST /session/:id/share` | `session_share` |
| Controller startup | `tile` + `start_session` + `info_card` (diagnostics) |

---

## Change Log

| Date | Change |
|------|--------|
| 2026-04-08 | Initial design — claudecode-controller-mirrored approach with TypeScript plugin bridge |
| 2026-04-08 | Major revision — native HTTP/SSE API, native permission API, TUI API routing, no plugin required for core features |
| 2026-04-08 | Added iOS block design — extensions to agent_session and start_session, new session_share block |
