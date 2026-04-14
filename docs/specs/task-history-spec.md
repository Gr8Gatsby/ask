# Functional Spec: Persistent Task History (A2A Protocol)

**Status:** Draft — Pending Review
**Date:** April 10, 2026
**Supersedes:** `chat-history-spec.md`

---

## Overview

Scripts currently communicate with iOS through ephemeral CloudKit blocks — live UI state that disappears when a session ends. There is no persistent history. When a session restarts, all context is gone. Files and outputs produced by an agent are never surfaced on iOS. Caching is scattered across feature-specific implementations with no coherent model.

This spec introduces **Tasks** as a first-class persistent primitive, modeled on the [Agent-to-Agent (A2A) protocol](https://google.github.io/A2A/). A Task is a unit of work with an identity, a status, a full message history, and a set of artifacts (files and outputs). Scripts write to tasks via AskMac. iOS reads tasks from CloudKit and renders them as a persistent thread list. The feed becomes the task list.

By adopting A2A as the standard, any script can persist history and surface files on iOS without modifying the iOS app.

---

## Goals

- Any script can open a task, append messages, and attach artifacts without modifying iOS.
- The full history of a task survives session restarts, daemon restarts, and app backgrounding.
- iOS surfaces tasks in the feed as persistent cards that link to full thread history.
- Files and outputs produced by agents are downloadable and viewable on iOS.
- iOS has a single, coherent data architecture — no scattered per-feature caching.
- Scripts do not implement CloudKit directly — they use the existing MCP tool interface.
- The desktop service has comprehensive automated tests covering messages, files, and history.

---

## Non-Goals

- Syncing history across multiple iOS devices (history is local to the device).
- Real-time collaboration between multiple users on the same task.
- Replacing existing live block types (confirmation, alert, status, prompt) — these remain for real-time interaction. Tasks are the persistence layer alongside them.
- Full-text search across history.

---

## Core Concepts

### Task

A Task is an ongoing or completed unit of work owned by a script. It has:

- A stable **task ID** chosen by the script (e.g. `repo:code/ask`, `pr:142`, `build:main-2026-04-10`)
- A **title** set by the script (e.g. `code/ask`, `PR #142 · auth refactor`)
- A **status**: `working` | `input-required` | `completed` | `failed`
- A **message history** — an ordered log of turns
- A set of **artifacts** — files and structured outputs produced during the task

The full identity of a task in the system is `machineID / scriptID / taskID`.

### Message

A Message is one turn in a task's history. Each message has:

- A **role**: `agent` or `user`
- One or more **parts** (the content)
- A **timestamp**

### Part

A Part is the content of a message. Three part types are supported:

- **TextPart** — plain text or markdown. Rendered as a chat bubble.
- **FilePart** — a reference to an artifact by artifact ID. Rendered as a tappable file card.
- **DataPart** — structured JSON data. Rendered as a collapsible detail card.

### Artifact

An Artifact is a file or structured output produced by a task. It has:

- An **artifact ID**
- A **filename** and **MIME type**
- **Content** (binary file data)
- A **size** in bytes
- A **description** (optional, human-readable)

---

## Script Interface (MCP Tools)

Scripts interact with tasks through the existing MCP tool interface in AskMac. Three new tools are added alongside the existing `emit_block` / `clear_block`:

### `open_task`

Opens a task or updates its status and title. Idempotent — calling `open_task` on an existing task ID updates it in place without affecting its history.

```json
{
  "taskId": "string",
  "title": "string",
  "status": "working" | "input-required" | "completed" | "failed"
}
```

### `append_message`

Appends a message to a task's history. Messages are immutable once written.

```json
{
  "taskId": "string",
  "role": "agent" | "user",
  "parts": [
    { "type": "text", "text": "string" },
    { "type": "file", "artifactId": "string" },
    { "type": "data", "data": { }, "label": "string" }
  ]
}
```

### `put_artifact`

Adds or replaces an artifact on a task.

The preferred way to provide content is `filePath` — an absolute path to a file on the Mac's filesystem that AskMac reads directly. Since scripts and AskMac run on the same machine, no data crosses the MCP boundary.

For programmatically-generated content that has not been written to disk, `content` (base64-encoded bytes) may be used instead, up to a maximum of **10 MB decoded**. Passing content larger than 10 MB via `content` is an error; the script must write the file to disk and use `filePath` instead.

Exactly one of `filePath` or `content` must be provided. If both are provided, `filePath` takes precedence.

```json
{
  "taskId": "string",
  "artifactId": "string",
  "filename": "string",
  "mimeType": "string",
  "description": "string?",
  "filePath": "string?",
  "content": "string?",
  "encoding": "base64?"
}
```

**Error responses from AskMac:**

| Condition | Error |
|---|---|
| Neither `filePath` nor `content` provided | `"put_artifact requires filePath or content"` |
| `filePath` does not exist or is not readable | `"filePath not found: <path>"` |
| Decoded `content` exceeds 10 MB | `"content exceeds 10 MB limit — write to disk and use filePath"` |
| `content` is not valid base64 | `"content is not valid base64"` |
| CloudKit write fails | `"CloudKit write failed: <reason>"` |

---

## AskMac Behavior

- AskMac receives `open_task`, `append_message`, and `put_artifact` calls from scripts over the existing MCP stdio connection.
- AskMac writes task state, messages, and artifacts to CloudKit immediately on receipt.
- AskMac does not buffer or batch — each call results in a CloudKit write.
- AskMac maintains a local task registry so scripts can query current task state and resume after a daemon restart.
- When a script restarts and calls `open_task` with an existing task ID and status `working`, AskMac updates the task status but does not clear its history.

**Artifact handling:**

- When `filePath` is provided, AskMac reads the file from disk, records its byte size, creates a `CKAsset`, and saves the `AskArtifact` record. AskMac does not delete the source file — that is the script's responsibility.
- When `content` is provided, AskMac decodes the base64 string, verifies the decoded size is ≤ 10 MB, writes the bytes to a temporary file, creates a `CKAsset` from it, saves the record, then deletes the temporary file.
- If decoded `content` exceeds 10 MB, AskMac returns an error immediately without writing anything to CloudKit. No temporary file is created.
- AskMac guarantees that temporary files created during `content` uploads are always deleted, including in error paths.

---

## CloudKit Schema

### New record types

Three new record types are added to the `iCloud.simple.ask` private database.

#### AskTask

One record per task. Updated in place as status changes.

| Field | Type | Description |
|-------|------|-------------|
| `taskID` | String | Record name. Script-chosen identifier scoped to machineID+scriptID. |
| `machineID` | String | Mac that owns this task |
| `scriptID` | String | Script that opened the task |
| `scriptName` | String | Human-readable script name |
| `scriptIcon` | String? | SF Symbol fallback |
| `scriptIconData` | String? | Base64 PNG (32×32) |
| `title` | String | Task title set by script |
| `status` | String | working / input-required / completed / failed |
| `lastActivityAt` | Date | Timestamp of most recent message or artifact write |
| `messageCount` | Int | Total messages written (updated on each `append_message`) |
| `artifactCount` | Int | Total artifacts attached |

#### AskTaskMessage

One record per message. Records accumulate and are never deleted by the system.

| Field | Type | Description |
|-------|------|-------------|
| `messageID` | String | Stable UUID, record name |
| `taskID` | String | Parent task ID |
| `machineID` | String | Mac that owns the parent task |
| `scriptID` | String | Script that owns the parent task |
| `role` | String | agent / user |
| `partsJSON` | String | JSON array of Part objects |
| `timestamp` | Date | Message creation time |
| `sequenceNumber` | Int | Monotonically increasing per task, for ordering |

#### AskArtifact

One record per artifact. Updated in place when `put_artifact` is called with the same artifact ID.

| Field | Type | Description |
|-------|------|-------------|
| `artifactID` | String | Stable ID, record name |
| `taskID` | String | Parent task ID |
| `machineID` | String | Mac that owns the parent task |
| `scriptID` | String | Script that owns the parent task |
| `filename` | String | Original filename |
| `mimeType` | String | MIME type |
| `description` | String? | Human-readable description |
| `sizeBytes` | Int | File size in bytes |
| `content` | CKAsset | File content |
| `updatedAt` | Date | Last write time |

### Unchanged record types

The following existing record types are unchanged by this work.

| Record type | Purpose |
|---|---|
| `RKBlock` | Ephemeral live blocks from scripts — confirmations, alerts, status, agent session state |
| `RKResponse` | iOS user responses to live blocks |
| `Machine` | Mac heartbeat and discovery |
| `AskDevice` | iOS device registration; Mac uses this to know which iPhones are active |
| `Agent` | Agent records per machine; used in machine detail view |
| `Job` | Job pipeline records; used in job creation and detail views |
| `OutputChunk` | Streaming job output; used in job detail view |
| `FeedSchedule` | Per-script feed schedule overrides |
| `AskMessage` | iOS→Mac chat message delivery; iOS writes this when the user sends a reply, Mac's `MessageWatcherService` polls and delivers it to the script, then writes `readAt` |

### Deprecated record types

The following record types exist in the CloudKit schema but are dead code — neither iOS nor AskMac reads or writes them in any active code path. All code referencing these types is removed as part of this work. Existing records in CloudKit are left in place (Apple does not permit deleting record types from production containers) but no new records are written.

| Record type | Why deprecated |
|---|---|
| `AskEvent` | Legacy notification system superseded by `RKBlock`. `saveEvent()` in AskMac is defined but never called. `fetchPendingEvents()` and `fetchEvents()` on iOS are defined but never called from any view. |
| `AskResponse` | Legacy response to `AskEvent`. `drainResponses()` in AskMac is defined but never called. `saveResponse()` on iOS is defined but never called from any view. |
| `AskSession` | Legacy session record with no active writer. No `saveSession()` exists in AskMac. `fetchSessions()` on iOS is defined but never called from any view. |

---

## iOS — What Changes

This section is a complete inventory of every iOS component that is removed, replaced, or modified by this work. Components not listed here are unchanged.

### Removed — SwiftData models

The SwiftData container is redefined. Existing local data is not migrated; history starts fresh from the point the new schema is deployed.

| Removed | Replaced by | Reason |
|---|---|---|
| `ChatSession` (@Model) | `TaskRecord` in Task Store | Keyed by ephemeral `sessionId`; replaced by stable task identity |
| `ChatEntry` (@Model) | `TaskMessage` in Task Store | View-level capture replaced by app-level `TaskHistoryStore` |
| `FeedHistoryEntry` (@Model) | `TaskMessage` in Task Store | Feed history unified into task message model |

### Removed — Stores and caches

| Removed | Replaced by | Reason |
|---|---|---|
| `FeedStore` (JSON file + in-memory `[LocalFeedItem]`) | Feed reads from SwiftData via `@Query` | Ad-hoc JSON file eliminated; SwiftData is the single local store |
| `ActionInboxStore` (in-memory block grouping by scriptID) | Task feed active section (`input-required` tasks) | Inbox concept unified into the task feed |

### Removed — View-level message capture logic

All of the following functions and observers are removed. Their responsibility moves to `TaskHistoryStore`, which runs at the app level regardless of which screen is visible.

| Removed | Location | Replaced by |
|---|---|---|
| `seedAssistantMessageToChatEntry(msg:sessionId:)` | `HomeView` | `TaskHistoryStore` CloudKit observer |
| `onChange(of: sessionBlocks.compactMap { ... lastMessage })` | `HomeView` | `TaskHistoryStore` CloudKit observer |
| `seedInitialEntries()` | `SessionChatView` | Task Store pre-populated by `TaskHistoryStore` |
| `appendAssistantEntry(_:)` | `SessionChatView` | `TaskHistoryStore` CloudKit observer |
| `captureActivityGroup()` | `SessionChatView` | Activity groups written by script via `append_message` |
| `appendInlineBlockEntry(_:)` | `SessionChatView` | Confirmation blocks rendered inline from live block layer |
| `onChange(of: livePayload?.lastMessage)` | `SessionChatView` | `TaskHistoryStore` CloudKit observer |
| `onChange(of: isActive)` auto-dismiss | `SessionChatView` | Thread view stays open on disconnect |

### Removed — Dead CloudKit code

The following methods exist in `iOSCloudKitService` and `AskModels` but are never called. They are removed along with their corresponding model structs.

| Removed | File |
|---|---|
| `fetchPendingEvents(machineID:)` | `iOSCloudKitService` |
| `fetchEvents(sessionID:machineID:)` | `iOSCloudKitService` |
| `saveResponse(eventID:machineID:choice:)` | `iOSCloudKitService` |
| `fetchSessions(machineID:)` | `iOSCloudKitService` |
| `updateSessionStatus(_:sessionID:machineID:)` | `iOSCloudKitService` |
| `AskEvent` struct | `AskModels` |
| `AskSession` struct | `AskModels` |
| `CKSchema.Event`, `CKSchema.Response`, `CKSchema.Session` constants | `AskModels` |

### Replaced — Views

#### `SessionChatView` → Task Thread View

| Aspect | Current | New |
|---|---|---|
| History key | `sessionId` (ephemeral, changes every session) | `taskId` (stable across sessions) |
| SwiftData access | Reads and writes | Read-only (`@Query`) |
| Message capture | View-level `onChange` observers | `TaskHistoryStore` app-level observer |
| On disconnect | Auto-dismisses after 600 ms | Stays open; compose field disabled |
| Pending confirmations | Floating bar above compose field | Inline interactive cards in the thread |
| "Session ended" | Fires on any block disappearance | Only fires when script sets status `completed` or `failed` |
| History on open | Blank if new session | Full history from all prior sessions visible immediately |

#### Feed (`FeedView` + `HomeView` tile section) → Task Feed

| Aspect | Current | New |
|---|---|---|
| Data source | Hybrid: live `RKBlock` groupings + `FeedHistoryEntry` from SwiftData | Single source: `TaskRecord` from SwiftData via `@Query` |
| Structure | Script tile grid derived from `ScriptGroup` | Two-section list: Active (working/input-required) and Recent (completed/failed) |
| Per-item | Script tile with live status | Task card with title, last message preview, artifact badge, unread indicator |
| Unread tracking | None | Unread dot per task |
| Artifact awareness | None | Artifact count badge per task card |

`ScriptGroup` and all its derived properties (`tileLabel`, `tileBody`, `tileStatusColor`, `brandBackground`, etc.) are removed.

#### Settings — new screen added

There are no history or storage settings today. A new **History & Storage** screen is added. See the Settings section below.

### Modified — Existing components extended

| Component | What changes |
|---|---|
| `iOSCloudKitService` | Add CloudKit subscriptions and fetch methods for `AskTask`, `AskTaskMessage`, `AskArtifact` record types |
| `PushService` | Add push notification subscriptions for the three new record types |
| `askApp.swift` | Register `TaskHistoryStore` at launch; redefine SwiftData container schema with new models |

### Unchanged — Not touched by this work

`BlockViews`, `MachinesView`, `MachineDetailView`, `JobDetailView`, `NewJobView`, `ScriptIconView`, `ScriptLoadingView`, `ScriptIconCache`, `OfflineQueue`, `UITestingSupport`, `NotificationBellToolbar`, and all live `RKBlock` rendering and response logic.

---

## iOS Data Architecture

### Layer 1 — Live State (in memory)

The set of currently active `RKBlock` records fetched from CloudKit. This layer drives all real-time interaction: pending confirmations, live session status, alerts. It is ephemeral — rebuilt from CloudKit on every app launch.

**Owns:** `[RKBlock]` in memory, managed by `iOSCloudKitService`. Unchanged from today.

### Layer 2 — Task Store (SwiftData, on-device)

The persistent record of all task history. Written exclusively by `TaskHistoryStore`. Views are read-only consumers.

**Owns:**
- `TaskRecord` — mirrors `AskTask` CloudKit record, one row per task
- `TaskMessage` — mirrors `AskTaskMessage`, one row per message
- `ArtifactRecord` — mirrors `AskArtifact` metadata (not file content), one row per artifact

**Written by:** `TaskHistoryStore` — subscribes to `AskTask`, `AskTaskMessage`, and `AskArtifact` CloudKit record changes and writes to SwiftData immediately on receipt, regardless of which screen is visible.

**Read by:** Feed view, thread view, Settings history view via `@Query`.

**Not synced to CloudKit.** SwiftData is the local read cache. CloudKit is the source of truth.

### Layer 3 — Artifact File Cache (file system)

On-device cache of downloaded artifact content.

**Owns:** Downloaded `CKAsset` files stored in the app's Caches directory, keyed by `artifactID`.

**Written by:** On demand when the user taps a file card.

**Eviction:** Least-recently-accessed files evicted when cache exceeds its size limit. Default: 500 MB. User-configurable in Settings.

**Not backed up.** Files can always be re-downloaded from CloudKit.

---

## iOS — TaskHistoryStore

`TaskHistoryStore` is a new app-level service instantiated at app launch. It is the sole writer to the Task Store.

**Responsibilities:**

- Subscribe to CloudKit push notifications for `AskTask`, `AskTaskMessage`, and `AskArtifact` record types.
- On notification receipt, fetch changed records and write to SwiftData.
- On app foreground, poll for records missed during background using the same catch-up mechanism as `iOSCloudKitService`.
- Deduplicate — never write the same `messageID` or `artifactID` twice.
- Maintain message ordering by `sequenceNumber` within each task.
- If a message arrives for an unknown `taskID`, fetch the parent `AskTask` record and create the `TaskRecord` before inserting the message.
- Expose no write methods to views.

---

## iOS — Feed

The feed is the unified task list. All tasks across all machines and scripts appear in a single scrollable list.

### Layout

**Active section** — tasks with status `working` or `input-required`, sorted by `lastActivityAt` descending. `input-required` tasks appear above `working` tasks.

**Recent section** — tasks with status `completed` or `failed`, sorted by `lastActivityAt` descending. Tasks older than 30 days are hidden by default behind a "Show older" disclosure control.

### Task card

- Script icon (left edge)
- Task title (bold)
- Machine name · Script name (secondary)
- Status chip: spinner for `working`; orange dot for `input-required`; no chip for `completed`; red dot for `failed`
- Last message preview — first 120 characters of the most recent agent TextPart
- Artifact badge — e.g. `2 files`, shown only when artifacts exist
- Relative timestamp — time since `lastActivityAt`
- Unread indicator dot — shown when there are messages the user has not viewed

Tapping opens the task thread view.

### Empty state

No tasks: centered illustration with text "Scripts will appear here when they start working."

### Live block coexistence

Scripts may continue to emit live `RKBlock` records alongside task messages.

- A `confirmation` or `prompt` block associated with a task causes the task card to show `input-required` and surfaces interactive UI inside the thread view.
- An `alert` block not associated with any task appears as a transient banner at the top of the feed, auto-dismissing after 5 seconds.
- A `status` block not associated with any task appears in the machine section (existing behavior).

---

## iOS — Task Thread View

Shows full message history for a task, oldest at top, newest at bottom. Scrolls to bottom on open.

### Message rendering

**Agent TextPart** — left-aligned, markdown rendered (headings, bold, italic, inline code, fenced code blocks).

**User TextPart** — right-aligned bubble.

**FilePart** — inline file card:
- File type icon derived from MIME type
- Filename and file size (from `sizeBytes`, shown before download)
- Download states: idle → spinner → preview ready
- On tap when idle: begins download
- On tap when ready: QuickLook for PDF, images, common document types; share sheet for others
- Retry button on failure

**DataPart** — collapsible card with label header and formatted JSON.

**Session boundary** — centered date/time label: `"New session · Apr 10, 9:30 AM"` when the script calls `open_task` on an existing task ID after a restart.

### Live interaction

When a live session block is present for this task's machine and script:

- Compose field appears at the bottom.
- Pending confirmations from live blocks appear as inline interactive cards above the compose field.
- User messages are written immediately as `TaskMessage` records (role: `user`) and sent to the script via `AskMessage` / CloudKit.
- Script responses appear via `TaskHistoryStore`.

### Disconnection behavior

- Thread view stays open when the live session block disappears.
- Compose field shows "Reconnecting…" and is disabled.
- No automatic "Session ended" event. The script sets task status to `completed` or `failed` to signal true termination, which causes a `"Session ended"` label in the thread.
- No automatic dismissal. User navigates away with the back button only.

---

## iOS — Settings

A dedicated **History & Storage** section in Settings.

### History & Storage screen

**Per-script groups** — each script with task history shows:
- Script icon and name
- Task count, total message count, total downloaded artifact size
- Disclosure chevron to per-script task list

**Per-task list (drill-down)** — each task shows title, last activity date, message count, artifact count. Swipe-to-delete clears all messages, artifact metadata, and cached files for that task from the device and deletes the corresponding CloudKit records.

**Global storage summary:**
- Total task history size (SwiftData store estimate)
- Artifact cache size (sum of cached files on disk)
- Artifact cache size limit — segmented control: 100 MB / 500 MB / 1 GB / Unlimited

**Actions:**
- **Clear Artifact Cache** — deletes all downloaded artifact files from disk. Metadata is retained; files can be re-downloaded. No confirmation prompt required.
- **Clear All History** — deletes all task records, messages, artifact metadata, and cached files from the device, and deletes the corresponding CloudKit records. Requires confirmation: *"This will permanently delete all task history from this device and CloudKit. This cannot be undone."*

---

## iOS — Local Persistence Rules

- `TaskHistoryStore` is the sole writer to the Task Store. No view writes to SwiftData.
- Messages are sorted for display by `sequenceNumber`.
- Artifact metadata is written when the `AskArtifact` CloudKit record arrives. File content is not fetched until the user taps the file card.
- Artifact files are stored in the app's Caches directory and excluded from iCloud and device backups.
- When the cache exceeds its size limit, the least-recently-accessed files are deleted. Metadata is never evicted.
- When the user deletes a task, all associated `TaskMessage` rows, `ArtifactRecord` rows, and cached artifact files are deleted from the device, and the corresponding `AskTask`, `AskTaskMessage`, and `AskArtifact` CloudKit records are deleted.

---

## Script Migration Path

### Phase 1 — Client-derived tasks (no script changes)

iOS derives task identity from existing `agentSession` block fields (`machineID`, `scriptID`, `project`). The task ID is derived from `project`. Messages are captured from `lastMessage` changes by `TaskHistoryStore`. Artifacts are not available in Phase 1.

### Phase 2 — Script-declared tasks

Scripts call `open_task`, `append_message`, and `put_artifact` explicitly, unlocking custom task IDs, titles, artifacts, and multi-task workflows. claudecode-controller and codex-2 are migrated in this phase.

### Phase 3 — Open platform

Any script in the vault can open tasks and append messages with no iOS changes required. The A2A task API is the documented standard for all scripts that want persistent history or file delivery.

---

## Desktop Testing Plan

Tests cover AskMac's task API from MCP tool call through to CloudKit record. Each suite is independently runnable.

### Suite 1 — MCP Tool Validation

| Test | Input | Expected result |
|---|---|---|
| `open_task` with all required fields | valid taskId, title, status | success |
| `open_task` missing `taskId` | no taskId | error: missing required field |
| `open_task` missing `title` | no title | error: missing required field |
| `open_task` invalid status | status = "unknown" | error: invalid status value |
| `append_message` with text part | valid taskId, role agent, text part | success |
| `append_message` with file part | valid taskId, role agent, file part with artifactId | success |
| `append_message` with data part | valid taskId, role agent, data part with label | success |
| `append_message` with multiple parts | text + file parts | success |
| `append_message` missing `taskId` | no taskId | error: missing required field |
| `append_message` invalid role | role = "system" | error: invalid role |
| `append_message` empty parts array | parts = [] | error: at least one part required |
| `put_artifact` with `filePath` | valid path, file exists | success |
| `put_artifact` with `content` under 10 MB | valid base64, ~1 MB | success |
| `put_artifact` with `content` exactly 10 MB | valid base64, exactly 10,485,760 bytes decoded | success |
| `put_artifact` with `content` over 10 MB | valid base64, 10,485,761 bytes decoded | error: content exceeds 10 MB limit |
| `put_artifact` with both `filePath` and `content` | both provided | success using filePath |
| `put_artifact` with neither | neither provided | error: requires filePath or content |
| `put_artifact` with non-existent `filePath` | path does not exist | error: filePath not found |
| `put_artifact` with unreadable `filePath` | path exists, no read permission | error: filePath not found |
| `put_artifact` with invalid base64 `content` | content = "not-base64!!!" | error: content is not valid base64 |
| `put_artifact` missing `filename` | no filename | error: missing required field |
| `put_artifact` missing `mimeType` | no mimeType | error: missing required field |

### Suite 2 — Task Lifecycle

| Test | Steps | Expected CloudKit state |
|---|---|---|
| Create new task | `open_task` status working | `AskTask` record exists, status = working |
| Update task status | `open_task` twice, second with status completed | `AskTask` status = completed, history unchanged |
| Task survives daemon restart | create task, restart AskMac, `open_task` same ID | `AskTask` record unchanged, messageCount preserved |
| Multiple concurrent tasks same script | `open_task` for taskId A and B | two `AskTask` records exist |
| Task with no messages | `open_task` then nothing | `AskTask` exists, messageCount = 0 |
| Task status input-required | `open_task` with status input-required | `AskTask` status = input-required |
| Task failure | `open_task` with status failed | `AskTask` status = failed |

### Suite 3 — Message History

| Test | Steps | Expected CloudKit state |
|---|---|---|
| Single agent message | `append_message` role agent, text part | one `AskTaskMessage`, role = agent |
| Single user message | `append_message` role user, text part | one `AskTaskMessage`, role = user |
| Message ordering | append 5 messages in sequence | 5 records, sequenceNumbers 1–5 |
| Message ordering after restart | append 3, restart AskMac, append 2 more | 5 records, sequenceNumbers 1–5 continuous |
| `lastActivityAt` updated | `open_task` then `append_message` | `AskTask.lastActivityAt` equals message timestamp |
| `messageCount` incremented | append 3 messages | `AskTask.messageCount` = 3 |
| Message with all part types | text + file + data parts in one message | `partsJSON` contains all three parts |
| Message referencing unknown artifact | FilePart with unknown artifactId | success — reference stored, no artifactId validation |
| Messages survive task status change | append message, update task status | message record unchanged |

### Suite 4 — File Handling

| Test | Steps | Expected result |
|---|---|---|
| Upload PDF via filePath | create PDF, `put_artifact` with filePath | `AskArtifact` with CKAsset, sizeBytes = file size |
| Upload JPG via filePath | create JPG, `put_artifact` with filePath | `AskArtifact` with CKAsset |
| Upload binary via filePath | create binary, `put_artifact` with filePath | `AskArtifact` with CKAsset |
| Upload via base64 content under limit | encode 500 KB JPG, `put_artifact` | `AskArtifact` with CKAsset, sizeBytes = 500 KB |
| Upload via base64 content at limit | encode exactly 10 MB file | success |
| Reject oversized base64 content | encode 11 MB file | error, no `AskArtifact` record created |
| No temp file leak on oversized content | encode 11 MB, verify filesystem | no temp files in tmp directory |
| No temp file leak on CloudKit failure | simulate CloudKit failure during content upload | no temp files in tmp directory |
| filePath wins over content | provide both; filePath = 1 KB, content = 2 KB | `AskArtifact` sizeBytes = 1 KB |
| Overwrite artifact same ID | `put_artifact` twice same artifactId | one `AskArtifact`, content = second upload |
| Source file not deleted | `put_artifact` with filePath | source file still exists after upload |
| Large file via filePath | 50 MB file | success, sizeBytes = 50 MB |
| `sizeBytes` correct | upload known-size file | `AskArtifact.sizeBytes` equals actual file size |
| `updatedAt` set on overwrite | upload, wait 1s, upload again same ID | `updatedAt` equals second upload time |

### Suite 5 — End-to-End (MCP call → CloudKit record)

| Test | Steps | Verification |
|---|---|---|
| Task appears in CloudKit | call `open_task` | query CloudKit for `AskTask`, verify all fields |
| Message appears in CloudKit | `open_task` then `append_message` | query for `AskTaskMessage`, verify taskID, role, partsJSON, timestamp |
| Artifact appears in CloudKit | `open_task` then `put_artifact` with filePath | query for `AskArtifact`, verify filename, mimeType, sizeBytes, CKAsset present |
| `messageCount` correct in CloudKit | append 5 messages | `AskTask.messageCount` = 5 |
| `artifactCount` correct in CloudKit | put 3 artifacts | `AskTask.artifactCount` = 3 |
| `lastActivityAt` updates on message | append message at known time | `AskTask.lastActivityAt` within 1s of message time |
| `lastActivityAt` updates on artifact | put artifact at known time | `AskTask.lastActivityAt` within 1s of artifact time |
| Full workflow | open → append message → put artifact → complete | all CloudKit records present and consistent |

### Suite 6 — Error Recovery

| Test | Condition | Expected behavior |
|---|---|---|
| CloudKit unavailable on `open_task` | CloudKit returns error | MCP error returned, no partial record |
| CloudKit unavailable on `append_message` | CloudKit returns error | MCP error returned, `messageCount` unchanged |
| CloudKit unavailable on `put_artifact` | CloudKit returns error | MCP error returned, no `AskArtifact` record, no temp file leak |
| `append_message` for unknown taskId | taskId not previously opened | error: task not found |
| Concurrent `open_task` same ID | two simultaneous calls | one `AskTask` record, no duplicate |
| Concurrent `append_message` same task | two simultaneous calls | two `AskTaskMessage` records, sequenceNumbers not duplicated |

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-10 | Initial draft — supersedes chat-history-spec.md, adopts A2A model |
| 2026-04-10 | `put_artifact`: file path is preferred; in-memory content supported up to 10 MB; larger files must use file path |
| 2026-04-10 | Expanded: iOS three-layer data architecture, unified feed design, comprehensive Settings, full desktop testing plan |
| 2026-04-10 | Added: full iOS changes inventory (removed models, stores, views, dead code); full CloudKit schema inventory (new, unchanged, deprecated record types) |
| 2026-04-10 | **Implemented (AskMac):** CloudKit schema constants + record structs (`AskTaskRecord`, `AskTaskMessageRecord`, `AskArtifactRecord`); `TaskRegistryActor` + `TaskServiceError` in AskMacCore; `TaskService` with `open_task`, `append_message`, `put_artifact`; CloudKit write methods (`saveTask`, `saveTaskMessage`, `saveArtifact`); MCP tool declarations in `MCPConnection`; 26 unit tests (Suites 1–4) passing |
| 2026-04-10 | **Implemented (iOS):** `TaskRecord`, `TaskMessage`, `ArtifactRecord` SwiftData models; task schema constants in `CKSchema`; `fetchTasks`, `fetchMessages`, `fetchArtifacts`, `downloadArtifactContent` in `iOSCloudKitService`; `TaskHistoryStore` (app-level service); `TaskThreadView` + `TaskListRow` + `ArtifactCard` UI; Task History section in Settings with per-script clear and clear-all |
