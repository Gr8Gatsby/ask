# Functional Spec: Offline Detection, Heartbeat & Response Queue

## Overview

The Ask iOS app has no way to know whether the Mac is currently reachable. When the Mac goes offline, stale blocks persist in CloudKit and the user can unknowingly tap actions that will never be received. This spec adds machine liveness detection, correct offline UI, and a response queue with user review.

---

## What Already Exists (no changes needed)

- **`HeartbeatService`** (AskMac): updates the Machine CKRecord's `lastHeartbeat` field every 30 seconds.
- **`AskMachine.connectionStatus`** (iOS): derives online/offline from `lastHeartbeat` age — offline if > 90s.
- **`AskMachine.systemImage`** (iOS): returns `laptopcomputer` for any Mac named "MacBook".

---

## Machine Picker — Visual Update

The bottom toolbar's machine picker button (`machinePickerButton` in `HomeView`) currently:
- Uses a hardcoded `desktopcomputer` icon regardless of machine type.
- Shows no connectivity state.

**Required changes:**
- Replace hardcoded icon with `machine.systemImage` (so MacBook Pro shows a laptop).
- When `connectionStatus == .offline` or `.sleeping`: render the button in grey (`.secondary` foreground).
- When online: render normally (`.primary` foreground).
- No status dot or badge — greyed-out text/icon is sufficient.

---

## Offline Response Queue

### Trigger

When the user taps an interactive block (any `respondToBlock` call) while `activeMachine?.connectionStatus == .offline`:
- The response is **not** sent to CloudKit.
- The response is added to the **offline queue** (stored locally on device).
- A toast message reads: **"Queued — Mac is offline"**.
- The block is **not** optimistically removed (it stays visible).
- Haptic feedback fires as normal.

When the machine is online, `respondToBlock` works exactly as today.

### Queue Entry Model (`OfflineQueueEntry`)

```
id:           UUID string
scriptID:     String
blockID:      String
blockType:    String          // human label for display ("Confirmation", etc.)
blockTitle:   String          // readable description, e.g. "Upgrade All · Homebrew"
value:        String          // the response value
queuedAt:     Date
machineID:    String
```

### Storage

Persisted as JSON in `UserDefaults` under key `"offlineQueue"`. Queue entries survive app restart.

### Per-Script Opt-In (`queue_responses`)

Each script's `manifest.json` declares:

```json
{ "queue_responses": false }
```

- `false` (default, all current scripts): queued entries require **manual user review** before being sent. They are never auto-sent.
- `true` (future scripts): queued entries are auto-sent when the Mac comes back online, without requiring review.

**Current settings — all false:**

| Script              | queue_responses |
|---------------------|----------------|
| brew-monitor        | false          |
| github              | false          |
| ollama              | false          |
| claudecode-controller | false        |

---

## Recovery — Queue Review on Reconnect

When `activeMachine?.connectionStatus` transitions from offline → online **and** the offline queue is non-empty:
- A sheet is presented: **"Mac is back online"** with a list of queued entries.
- Each entry shows: script name, action description, time queued.
- Per-entry actions: **Send** / **Discard**.
- Bulk actions: **Send All** / **Discard All**.
- Sending an entry calls `cloudKit.postResponse(...)` for that entry.
- After review (all sent or discarded), normal polling resumes.

If queue is empty on reconnect: no sheet, silent recovery.

---

## Queue in Settings

A **"Queued Actions"** section is added to `SettingsSheetView`:
- Shown only when the queue is non-empty (hidden otherwise).
- Lists all pending entries with the same per-entry Send / Discard controls as the review sheet.
- Allows the user to inspect or clear the queue at any time.

---

## Blocks While Offline

- Blocks render identically whether Mac is online or offline.
- Interactive elements (buttons, text fields) remain visually enabled.
- On tap: the response is queued (see above) and a toast is shown.
- Blocks are never removed optimistically while offline.

---

## Files to Change

| File | Change |
|------|--------|
| `ask/ask/HomeView.swift` | `machinePickerButton` — correct icon + grey when offline |
| `ask/ask/HomeView.swift` | `respondToBlock()` — route to queue when offline |
| `ask/ask/HomeView.swift` | Detect machine online→offline transition; show review sheet |
| `ask/ask/AskModels.swift` | Add `OfflineQueueEntry` struct |
| `ask/ask/OfflineQueue.swift` | New — `OfflineQueue` observable, persistence, send logic |
| `ask/ask/HomeView.swift` | `SettingsSheetView` — add Queued Actions section |
| `~/.ask/scripts/*/manifest.json` | Add `"queue_responses": false` |

---

## Out of Scope

- Per-script offline health (script crashed, daemon alive) — separate concern.
- Network reachability APIs — heartbeat expiry is the signal.
- Syncing blocks the iOS app missed while offline — CloudKit handles this on reconnect.

---

## Changelog

| Date       | Change |
|------------|--------|
| 2026-03-30 | Initial spec |
| 2026-03-30 | Updated: CKRecord = existing Machine record (HeartbeatService already implemented); all offline taps queue locally; review sheet on reconnect; queue visible in Settings |
| 2026-03-30 | Implemented: OfflineQueue.swift, machinePickerButton (correct icon + grey when offline), respondToBlock offline path, startPolling reconnect detection, QueueReviewSheet, Settings queue section |
