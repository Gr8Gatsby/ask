---
title: Machine Management — Ghost Deletion with Tombstones
status: draft
---

## Goal

Let users delete ghost machine records from the iOS app. A deleted machine does not reappear until a heartbeat from that machine is observed that is newer than the deletion timestamp.

## Requirements

### 1. Delete Machine from iOS

The machine list in Settings allows the user to delete a machine record. Deleting a machine:

- Removes the Machine CloudKit record and all of its RKBlocks.
- Removes the machine from the visible machine list immediately.
- Records a local tombstone (machineID → deletion timestamp) stored in UserDefaults.

### 2. Tombstone Semantics

When machines are fetched from CloudKit, each result is checked against the local tombstone store:

- If a tombstone exists for that machineID and the machine's `lastHeartbeat` is **older than or equal to** the tombstone timestamp, the machine is suppressed from the list — it is not shown and its blocks are not fetched.
- If the machine's `lastHeartbeat` is **newer than** the tombstone timestamp, the tombstone is cleared and the machine reappears normally.

This ensures a machine only comes back if it has genuinely re-registered after being removed.

### 3. Machine List UI

In the Settings sheet, each machine row has a swipe-to-delete gesture (or delete button). Before deleting, the app shows a confirmation alert listing what will be removed (machine record, all associated blocks). The confirmation alert has a destructive-style "Delete" button.

### 4. Tombstone Persistence

Tombstones are stored as a dictionary `[machineID: ISO8601 date string]` in `UserDefaults` under the key `"deletedMachineTimestamps"`. They are cleared automatically when a machine reappears with a newer heartbeat.

## Out of Scope

- Deleting associated AskSession, AskEvent, or AskDevice records (those are low-volume and self-expire).
- Syncing tombstones across devices.
- Bulk-delete of all machines.

## Change Log

| Date | Change |
|---|---|
| 2026-04-08 | Initial spec |
| 2026-04-08 | Implement delete UI (already existed) + MachineTombstoneStore + tombstone filtering in load() |
