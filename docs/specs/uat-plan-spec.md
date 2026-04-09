# UAT Plan — Ask iOS + macOS

## Status: Draft
## Version: 1.0

---

## 1. Overview

This spec defines the User Acceptance Testing strategy for Ask before each release. It covers four areas:

1. **XCUITest on iOS Simulator** — automated UI tests for the iPhone app
2. **XCUITest on macOS** — automated UI tests for the AskMac menu bar app
3. **Structured daemon logging** — JSON log lines for daemon + hook correlation
4. **Graceful error recovery** — daemon resilience improvements

---

## 2. XCUITest Capabilities

### Screenshot capture on failure
XCTest automatically captures a screenshot on assertion failure and attaches it to the `.xcresult` bundle. Screenshots are visible in Xcode's test report navigator with the exact UI state at the moment of failure.

We additionally call `XCTAttachment(screenshot: app.screenshot())` at the start and end of each test and at key assertion points, so the full before/after state is always captured regardless of pass/fail.

### Screen recordings
Xcode scheme settings → Test → Video Recording: "On" for all tests. Each test gets a `.mov` video embedded in the result bundle that can be reviewed in Xcode or extracted with `xcrun xcresulttool`.

### Result bundle storage
CI runs produce `TestResults.xcresult` which can be archived as a build artifact. `xcrun xcresulttool get --format json` extracts test results including all attached screenshots and video clips.

### Failure highlights
`XCTContext.runActivity(named:)` groups test steps into named activities. Screenshots attached inside an activity appear inline under that activity name in the test report, making failures self-documenting.

---

## 3. iOS Simulator UAT

### 3.1 Strategy
- Launch app with `--uitesting` flag to switch `BlockStore` to `MockBlockStore`
- `MockBlockStore` returns canned `RKBlock` objects without any CloudKit calls
- `accessibilityIdentifier` set on all tappable/inspectable UI elements
- Tests assert on accessibility labels and identifiers, not pixel coordinates

### 3.2 Test infrastructure

**MockBlockStore** (injected at app launch in test mode):
- Returns a configurable set of `RKBlock` objects
- Supports scenario presets: `confirmation`, `alert`, `agentSession`, `prompt`, `quickReply`, `startSession`, `sessionWithTool`, `multipleScripts`
- Responses captured in-memory and exposed via launch arguments for test assertions

**Accessibility identifiers** (added to key views):

| Element | Identifier |
|---------|-----------|
| Home screen list | `home-script-list` |
| Script group row | `script-group-{scriptID}` |
| Script group tile label | `tile-label` |
| Script group tile badge (pending count) | `tile-badge` |
| Block view container | `block-{blockID}` |
| Confirmation option button | `confirm-option-{index}` |
| Alert body text | `alert-body` |
| Agent session project label | `agent-session-project` |
| Agent session tool label | `agent-session-tool` |
| Agent session status dot | `agent-session-status` |
| Quick reply option button | `quick-reply-option-{index}` |
| Prompt text field | `prompt-textfield` |
| Prompt submit button | `prompt-submit` |
| Chat prompt text field | `chat-prompt-textfield` |
| Chat prompt submit button | `chat-prompt-submit` |
| Start session repo row | `start-session-repo-{index}` |
| Session chat view | `session-chat-view` |
| Session chat send button | `session-chat-send` |
| Machine row | `machine-row-{machineID}` |
| Machine status indicator | `machine-status` |

### 3.3 iOS test scenarios

#### Scenario 1: Confirmation block — Allow
1. Launch app with preset `confirmation` (title: "Allow Bash?", options: ["Allow", "Deny"])
2. Assert script group row appears with orange badge
3. Tap script group row → block detail appears
4. Assert confirmation block title = "Allow Bash?"
5. Assert two option buttons: "Allow" and "Deny"
6. Screenshot: before tap
7. Tap "Allow"
8. Assert block disappears (response sent)
9. Assert response value == "Allow" in MockBlockStore
10. Screenshot: after tap

#### Scenario 2: Confirmation block — Deny
1. Launch with `confirmation` preset
2. Navigate to block detail
3. Tap "Deny"
4. Assert block disappears
5. Assert response value == "Deny"

#### Scenario 3: Confirmation block — Always Allow (3-option list)
1. Launch with `confirmationList` preset (options: ["Allow", "Always allow Bash(/tmp)", "Deny"])
2. Assert all three options render
3. Tap "Always allow Bash(/tmp)"
4. Assert response value == "Always allow Bash(/tmp)"

#### Scenario 4: Alert block
1. Launch with `alert` preset (title: "Error", body: "daemon not running")
2. Navigate to block detail
3. Assert title = "Error"
4. Assert body text contains "daemon not running"
5. Assert no interactive buttons (alert is read-only)

#### Scenario 5: Agent session block — idle
1. Launch with `agentSession` preset (project: "ask", isWorking: false)
2. Assert project label = "ask"
3. Assert no tool subtitle (idle state)
4. Assert status indicator color = green/idle

#### Scenario 6: Agent session block — working with tool
1. Launch with `agentSessionWorking` preset (project: "ask", isWorking: true, currentTool: "Bash", currentPreview: "git status")
2. Assert project label = "ask"
3. Assert tool subtitle visible and contains "Bash"
4. Tap agent session → SessionChatView opens
5. Assert chat view shows project name

#### Scenario 7: Quick reply block
1. Launch with `quickReply` preset (title: "Deploy to prod?", options: ["Deploy", "Cancel"])
2. Assert title and both options visible
3. Tap "Deploy"
4. Assert response == "Deploy"

#### Scenario 8: Prompt block — text input
1. Launch with `prompt` preset (title: "Enter branch name:", placeholder: "feature/...")
2. Assert prompt title visible
3. Tap text field
4. Type "feature/my-branch"
5. Tap submit
6. Assert response == "feature/my-branch"

#### Scenario 9: Start session block
1. Launch with `startSession` preset (repos: ["ask", "life"])
2. Assert repo list shows "ask" and "life"
3. Tap "ask"
4. Assert response sent with repo path

#### Scenario 10: Multiple scripts — home screen
1. Launch with `multipleScripts` preset (2 scripts: claude-code and codex-2, each with a pending confirmation)
2. Assert home screen shows both script group rows
3. Assert both rows have urgency badges
4. Navigate to first script → confirmation appears
5. Respond → badge clears for that script
6. Assert second script still has badge

#### Scenario 11: Urgency ordering
1. Launch with mixed urgency preset (urgent confirmation + warning alert)
2. Assert confirmation (urgent) sorts above alert (warning) in inbox

#### Scenario 12: Empty state
1. Launch with empty preset (no blocks)
2. Assert home screen shows empty state or tile-only view with no badges

#### Scenario 13: Machine offline
1. Launch with `machineOffline` preset (machine heartbeat > 5 min ago)
2. Navigate to machines view
3. Assert machine status indicator shows offline

---

## 4. macOS App UAT

### 4.1 Strategy
- `XCUIApplication` targeting `AskMac` bundle
- Activate menu bar item via accessibility API (`systemBars.menuBars`)
- Test the popover/panel that opens
- Same `--uitesting` flag injects mock blocks

### 4.2 macOS test scenarios

#### Scenario 1: Menu bar item state — pending
1. Launch AskMac with `confirmation` mock
2. Assert menu bar item icon shows alert/badge state
3. Click menu bar item → popover opens
4. Assert confirmation block visible in popover
5. Click "Allow"
6. Assert block disappears, menu bar icon returns to idle

#### Scenario 2: Menu bar item state — idle
1. Launch AskMac with empty mock
2. Assert menu bar icon shows idle state

#### Scenario 3: Settings
1. Open settings
2. Assert version number field populated
3. Toggle a setting
4. Restart app (new `XCUIApplication().launch()`)
5. Assert setting persisted

#### Scenario 4: Script list
1. Launch AskMac with multiple scripts
2. Open popover
3. Assert script sections visible

---

## 5. Structured Daemon Logging

### 5.1 Requirement
Both `codex-2` and `claudecode-controller` emit JSON-structured log lines so that a single `grep`/`jq` pipeline can correlate a permission request from hook invocation through daemon processing to iOS response.

### 5.2 Log format
```json
{"ts": "2026-04-09T15:00:00.123", "level": "INFO", "script": "codex-2", "event": "permission_request", "session": "tmux-codex:ask.0", "tool": "Bash", "preview": "git status", "block_id": "perm-abc123"}
{"ts": "2026-04-09T15:00:05.456", "level": "INFO", "script": "codex-2", "event": "permission_resolved", "session": "tmux-codex:ask.0", "block_id": "perm-abc123", "value": "Allow", "elapsed_s": 5.3}
```

### 5.3 Key events to log
| Event | Fields |
|-------|--------|
| `daemon_start` | version, socket_path |
| `mcp_init` | protocol_version |
| `session_active` | session_id, cwd, tmux_target |
| `session_stop` | session_id, last_message |
| `permission_request` | session_id, tool, preview, block_id |
| `permission_resolved` | session_id, block_id, value, elapsed_s |
| `emit_block` | block_type, block_id |
| `tm_unreachable` | error |
| `tm_session_registered` | session_id, tm_session_id |
| `hook_error` | hook_name, error |

### 5.4 Log rotation
Rotate logs when > 5 MB; keep last 3 files (`codex-2.log`, `codex-2.log.1`, `codex-2.log.2`).

---

## 6. Graceful Error Recovery

### 6.1 terminal-manager unavailable
- Current: emits one-time diagnostic alert, TUI detection silently fails forever
- Fix: retry `list_sessions` every 60s; emit "restored" block when it becomes reachable again; log each retry attempt

### 6.2 tmux session death detection
- Current: daemon keeps polling until 300s TTL expires
- Fix: in `_poll_session`, check if `tmux has-session -t {target}` returns non-zero; if so, call `_handle_session_stop` immediately

### 6.3 Socket file left after crash
- Current: if socket file exists from a previous crash, new daemon fails to bind
- Fix: if `bind()` raises `AddressAlreadyInUse`, remove the stale file and retry once; log the recovery

### 6.4 CloudKit write failure (iOS)
- Current: `RKResponse` write failure is logged but response appears lost
- Fix: retry up to 3× with exponential backoff (1s, 2s, 4s); show local error toast after all retries exhausted

---

## 7. Release Checklist

### Automated (CI)
- [ ] 151+ Python tests pass (`pytest ask/scripts/codex-2/tests/ ask/scripts/claudecode-controller/tests/`)
- [ ] iOS unit tests pass (`xcodebuild test -scheme ask -destination 'platform=iOS Simulator,...'`)
- [ ] iOS UI tests pass (`xcodebuild test -scheme askUITests`)
- [ ] macOS tests pass (`xcodebuild test -scheme AskMac`)

### Manual smoke test (per release)
- [ ] Start codex-2 daemon; fire a `pre_tool_use.py` hook; confirm iPhone receives block within 3s
- [ ] Tap Allow → hook exits 0
- [ ] Tap Deny → hook exits 2
- [ ] Start Claude Code session; fire `permission_request.py` hook; confirm block appears
- [ ] Confirm session chat message routes to Claude terminal
- [ ] Confirm AskMac menu bar badge appears when block is pending
- [ ] Confirm badge clears when block is responded to
- [ ] Restart AskMac; confirm sessions restore from disk

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-04-09 | Initial draft |
