# Ask — End-to-End Architecture

This document covers the full technical pipeline from script execution through CloudKit to the iOS app. For block payload specs see [design.md](design.md). For iOS UI conventions see [agent.md](agent.md).

---

## System Overview

```
~/.ask/scripts/          AskMac (menu-bar daemon)        CloudKit (private DB)      Ask iOS app
─────────────────        ────────────────────────        ─────────────────────      ──────────────
manifest.json  ──────▶  ScriptManager                         RKBlock records  ◀──── iOSCloudKitService
entry.py/js    ──stdio──▶ MCPConnection                        RKResponse records ───▶   (poll + push)
                │           │  emit_block / clear_block                                      │
                │           ▼                                                                 │
                │         BlockService ──────────────────────▶ CKRecord.save()           HomeView
                │                                                                             │
                │         ResponsePoller ◀───────────────────── RKResponse records       BlockView
                │           │  drainRKResponses                                               │
                └───stdin──◀┘  deliverResponse → notifications/message               user tap response
                                                                                              │
                                                                                    iOSCloudKitService
                                                                                    postResponse()
                                                                                              │
                                                                                     RKResponse.save()
```

---

## 1. Script Discovery and Launch (ScriptManager)

**Directory**: `~/.ask/scripts/`

Each script lives in its own subdirectory with a `manifest.json`:

```json
{
  "id": "brew-monitor",
  "name": "Homebrew Monitor",
  "version": "1.0",
  "entry": "main.py",
  "icon": "terminal.fill",
  "icon_file": "icon.svg"
}
```

**Startup sequence** (`ScriptManager.discoverAndLaunch`):

1. Enumerate `~/.ask/scripts/*/manifest.json`
2. For each manifest: load `NSImage` from `icon_file` (SVG/PNG), read raw SVG string if `.svg`
3. Create `MCPConnection(scriptID:, entryURL:, blockService:)`
4. Call `conn.start()` — spawns subprocess, wires stdin/stdout pipes
5. Send MCP `initialize` handshake on stdin
6. Script is now running and may call `emit_block` at any time

**Auto-restart**: `onTerminate` callback triggers `handleCrash()` which emits a crash `alert` block and schedules a 5-second delayed restart.

**Icon data** passed to every block emit:
- `scriptName` — from `manifest.name`
- `scriptIcon` — from `manifest.icon` (SF Symbol fallback)
- `scriptIconSVG` — raw SVG string from `icon_file` (nil if not SVG)
- `scriptIconData` — base64 PNG (32×32) rendered from `NSImage` via `NSBitmapImageRep`

---

## 2. MCP Protocol Layer (MCPConnection)

**Protocol**: JSON-RPC 2.0 over stdio (newline-delimited JSON)

**Direction**: script stdout → AskMac stdin; AskMac stdout → script stdin

### Initialization handshake

AskMac sends on connect:
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"AskMac","version":"1.0"}}}
```

AskMac then sends `notifications/initialized`.

### Tool calls (script → AskMac)

Scripts call AskMac tools by sending:
```json
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"emit_block","arguments":{...}}}
```

**Available tools**:

| Tool | Arguments | Effect |
|------|-----------|--------|
| `emit_block` | `blockId`, `blockType`, `payload`, `ttl?` | Write/overwrite RKBlock in CloudKit |
| `clear_block` | `blockId` | Delete RKBlock from CloudKit |
| `get_schema` | — | Returns JSON schema for all block types |

AskMac responds with:
```json
{"jsonrpc":"2.0","id":42,"result":{"content":[{"type":"text","text":"ok"}]}}
```

### Response delivery (AskMac → script)

When the iOS user responds to a block, AskMac sends on the script's stdin:
```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":{"type":"user_response","blockId":"some-id","value":"Yes"}}}
```

The script's MCP client library routes this to the handler registered for `user_response`.

---

## 3. Block Emission Pipeline

**`emit_block` call flow**:

```
MCPConnection.handleToolCall("emit_block", args)
  │
  ▼
BlockService.emitBlock(blockID:machineID:scriptID:scriptName:scriptIconSVG:blockType:payload:ttl:)
  │
  ▼
RKBlockRecord { blockID, machineID, scriptID, scriptName, scriptIcon,
                scriptIconData, scriptIconSVG, blockType, payload, createdAt, expiresAt }
  │
  ▼
CKDatabase.save(record, savePolicy: .allKeys)   ← always overwrites all fields
  │
  ▼
CloudKit private database → triggers CKQuerySubscription push to iOS
```

**Save policy `.allKeys`**: Every save overwrites all record fields. Re-emitting the same `blockID` with new payload updates the block in-place. This is the mechanism for live-updating blocks (e.g., `chat_prompt` context updates).

**TTL**: If `ttl` is provided (seconds), `expiresAt = now + ttl` is stored in the record. iOS filters expired blocks client-side at render time.

---

## 4. CloudKit Schema

**Container**: `iCloud.simple.ask` (private database)

### RKBlock
The primary UI record. One record per active block.

| Field | Type | Description |
|-------|------|-------------|
| `blockID` | String | Stable ID; record name = blockID |
| `machineID` | String | Mac that owns this block |
| `scriptID` | String | Script that emitted it |
| `scriptName` | String | Human-readable script name |
| `scriptIcon` | String? | SF Symbol name (fallback) |
| `scriptIconData` | String? | Base64 PNG (32×32) |
| `scriptIconSVG` | String? | Raw SVG markup |
| `blockType` | String | confirmation / alert / status / prompt / chat_prompt / info_card / icon_card |
| `payload` | String | JSON blob (type-specific) |
| `createdAt` | Date | Block creation time |
| `expiresAt` | Date? | Auto-filter time (optional) |

### RKResponse
Written by iOS when user responds to a block.

| Field | Type | Description |
|-------|------|-------------|
| `blockID` | String | The block being responded to |
| `machineID` | String | Target Mac |
| `scriptID` | String | Target script |
| `value` | String | User's response text/choice |
| `timestamp` | Date | When response was submitted |

### Machine
Heartbeat record per Mac. iOS uses this to discover available machines.

| Field | Type | Description |
|-------|------|-------------|
| `machineID` | String | Stable UUID per Mac |
| `name` | String | Computer name |
| `lastHeartbeat` | Date | Last keepalive write |
| `status` | String | idle / busy |

### AskDevice
Heartbeat record per iOS device. Mac uses this to know which iPhones are active.

| Field | Type | Description |
|-------|------|-------------|
| `deviceID` | String | UIDevice identifier |
| `deviceName` | String | iPhone name |
| `machineID` | String | Mac this device is watching |
| `lastSeen` | Date | Last iOS foreground time |

---

## 5. iOS Sync Mechanisms

iOS uses three overlapping mechanisms to stay current — each covers a different failure mode.

### 5a. CKQuerySubscription (push)

Registered once at app launch via `PushService`:

```swift
CKQuerySubscription(
    recordType: "RKBlock",
    predicate: NSPredicate(value: true),
    subscriptionID: "ask-rkblock-changes-v2",
    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
)
// notificationInfo.shouldSendContentAvailable = true  ← silent push
```

**Flow**: Script emits block → CloudKit saves → subscription fires → APNs silent push → iOS wakes → `PushService.handleRemoteNotification()` → posts `Notification.Name.askRefreshRequired` → `HomeView.load()`.

Covers: immediate updates when app is backgrounded or foregrounded after a script change.

### 5b. Foreground refresh (scenePhase)

`HomeView` observes `scenePhase`:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active { Task { await load() } }
}
```

Covers: app-switch back to Ask after any period away; guaranteed fresh data on every foreground regardless of push delivery.

### 5c. Polling (backstop)

`HomeView.startPolling()` runs every 5 seconds while the view is visible:

```swift
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(5))
    // fetchMachines() + fetchBlocks()
}
```

Covers: push delivery failures, CloudKit propagation delays, and live-updating blocks (e.g., chat_prompt context).

---

## 6. iOS Fetch Logic

`iOSCloudKitService.fetchBlocks(machineID:)` queries:

```
recordType = "RKBlock"
machineID == <current machine>
```

Results are filtered client-side:
- `blockType != .alert` — alert blocks are ephemeral; filtered from the list view
- `expiresAt == nil || expiresAt > now` — expired TTL blocks hidden

Blocks are grouped by `scriptID` for section rendering. Section headers use `scriptName`, `scriptIconSVG` (primary), `scriptIconData` (fallback), `scriptIcon` SF Symbol (final fallback).

---

## 7. Response Routing

**iOS → CloudKit**:

```swift
iOSCloudKitService.postResponse(blockID:machineID:scriptID:value:)
  → CKRecord(recordType: "RKResponse")
  → database.save()
```

**Mac polling** (`ResponsePoller`, every 2 seconds):

```swift
cloudKit.drainRKResponses(machineID:)
  // CKQueryOperation: RKResponse where machineID == self.machineID
  // Deletes each record after reading (drain semantics)
```

**Delivery to script**:

```swift
scriptManager.connection(for: response.scriptID)
  .deliverResponse(blockID: response.blockID, value: response.value)
  // Writes notifications/message JSON-RPC to script's stdin
```

**Script receives**:
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "info",
    "data": { "type": "user_response", "blockId": "...", "value": "Yes" }
  }
}
```

---

## 8. Machine Presence

**Mac → CloudKit**: `HeartbeatService` writes `Machine` record every ~60 seconds. Sets `lastHeartbeat = now`.

**iOS → CloudKit**: `HomeView.load()` calls `cloudKit.saveDeviceHeartbeat(machineIDs:)` at most every 30 minutes, writing `AskDevice` records for each machine the phone is watching.

**iOS discovery**: `fetchMachines()` queries all `Machine` records. Machines are sorted by `lastHeartbeat` descending; the most recently active becomes `activeMachine` by default.

---

## 9. Script Identity in Blocks

Every CloudKit `RKBlock` record carries the script's full identity. This means iOS never needs a local lookup table — the block itself tells the app how to render its section header.

**Mac write path** (`ScriptManager` → `BlockService`):
- Reads raw SVG string from `icon_file` if extension is `.svg`
- Renders `NSImage` to 32×32 PNG via `NSBitmapImageRep`, base64-encodes it
- Passes `scriptName`, `scriptIcon`, `scriptIconSVG`, `scriptIconData` to every `emitBlock` call

**iOS render priority** (`ScriptIconView`):
1. `scriptIconSVG` → `SVGImageView` (WKWebView renders SVG as HTML)
2. `scriptIconData` → base64 → `UIImage`
3. `scriptIcon` → `Image(systemName:)` SF Symbol
4. Hardcoded fallback: `terminal.fill`
