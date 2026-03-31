# Codex Script — Functional Specification

## Purpose

A Mac daemon script that supervises OpenAI Codex CLI sessions and surfaces them on iPhone, mirroring the `claudecode-controller` experience. The user sees active sessions, receives tool permission prompts, and can reply to Codex from their phone.

---

## Hook Integration

- On first run, the script installs hooks into `~/.codex/hooks.json` targeting `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop` events
- On first run, the script enables the `codex_hooks = true` feature flag in `~/.codex/config.toml` if not already present
- Hook shell scripts communicate with the daemon over a Unix socket at `~/.ask/sockets/codex-controller.sock`
- `PreToolUse` hooks block until the daemon responds; the daemon blocks until the user responds on iPhone (no timeout — waits indefinitely)
- `SessionStart` and `Stop` are fire-and-forget (no blocking)

---

## Session Tracking

- A session is one invocation of `codex`, identified by the session ID present in hook payloads
- Multiple concurrent sessions are supported
- Sessions persist to disk so they survive daemon restarts
- Session state: project name, working directory, last activity timestamp, last message, working flag
- Working state is set on `PreToolUse` and cleared on `PostToolUse` or `Stop`

---

## Blocks Emitted

| Block | Type | Trigger | Persistent |
|---|---|---|---|
| Home tile | `tile` | Always; re-emitted every 5 min | Yes |
| Session card | `agent_session` | One per active session | Yes, until cleared |
| Tool permission | `confirmation` | `PreToolUse` (Bash) | Until responded to |
| Notification | `alert` | `Stop` with final message | Short TTL |

---

## Generalized `agent_session` Block Type

`claude_session` is renamed to `agent_session` to serve both Claude Code and Codex sessions. The payload gains two new fields for branding:

| Field | Type | Description |
|---|---|---|
| `session_id` | String | Unique session identifier |
| `project` | String | Project or directory name |
| `cwd` | String? | Full working directory path |
| `last_message` | String? | Most recent agent message |
| `placeholder` | String? | Reply input placeholder text |
| `is_working` | Bool? | Whether the agent is actively running a tool |
| `agent_name` | String? | Display name shown in working indicator (e.g. "Claude", "Codex") |
| `brand_color` | String? | Hex color for the working/active accent (e.g. `#74AA9C` for Codex) |

The iOS view uses `agent_name` in place of hardcoded "Claude" strings (e.g. "Codex is working…", "Reply to Codex…"). The `brand_color` tints the working indicator.

---

## Tool Permissions

- `PreToolUse` fires before Bash commands
- Daemon emits a `confirmation` block linked to the session, showing the command preview and Allow / Deny options
- Allow → exits 0 (Codex proceeds)
- Deny → exits 2 with reason (Codex blocks the tool call)
- Daemon waits indefinitely for the user to respond — no automatic timeout

---

## Reply Routing

- User replies typed into the `agent_session` card are routed to the active Codex terminal session
- Routing uses AppleScript to paste the reply into the frontmost Terminal or iTerm2 window associated with the session (same mechanism as claudecode-controller)

---

## OpenAI Brand Colors

| Role | Hex |
|---|---|
| Primary / logo | `#000000` |
| Background | `#FFFFFF` |
| Working indicator | `#74AA9C` (ChatGPT teal) |

---

## Code Changes Required

### New script: `ask/scripts/codex-controller/`
- `manifest.json` — script metadata
- `main.py` — daemon implementing socket server, hook installer, block emission
- `icon.svg` — OpenAI Blossom mark in black
- `hooks/pre_tool_use.sh`, `hooks/post_tool_use.sh`, `hooks/session_start.sh`, `hooks/session_stop.sh` — shell scripts registered in `~/.codex/hooks.json`
- `tests/test_main.py` — integration tests mirroring claudecode-controller test coverage

### iOS app: `ask/ask/`
- `RemoteKitModels.swift` — rename `claudeSession` → `agentSession`, rename `RKClaudeSessionPayload` → `RKAgentSessionPayload`, add `agentName` and `brandColor` fields, rename computed property
- `BlockViews.swift` — rename `ClaudeSessionBlockView` → `AgentSessionBlockView`, use `agentName` in place of hardcoded "Claude" strings, apply `brandColor` to working indicator

### iOS app: `ask/ask/HomeView.swift`
- Update `claudeSession` references to `agentSession`

### Mac app: `AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`
- Update `claude_session` → `agent_session` case

### `ask/scripts/claudecode-controller/main.py`
- Emit `agent_session` block type (was `claude_session`)
- Pass `agent_name: "Claude"` and `brand_color: "#D97757"` in payload

---

## Limitations (current Codex CLI)

- `PreToolUse` / `PostToolUse` only fire for the Bash tool today; other tools (Write, Read, etc.) are not yet supported upstream
- The `codex_hooks` feature flag is required; the script enables it automatically on first run

---

## Changelog

- 2026-03-31 — v1.0 Initial spec
- 2026-03-31 — v1.1 Implementation complete; `claude_session` generalized to `agent_session` across iOS, Mac app, and claudecode-controller; codex-controller script created with 39 passing integration tests

