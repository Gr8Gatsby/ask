---
title: CloudKit Communication Optimization
status: in-progress
---

## Goal

Reduce CloudKit read/write volume while improving perceived responsiveness on iOS. The system should feel instant for user-facing interactions, use push notifications as the primary update signal, and reserve polling as a reliability fallback only.

## Requirements

### 1. Push-First Polling on iOS

The normal poll interval increases from 3s to 15 seconds. A push notification immediately triggers a fetch (unchanged). Burst polling (post-response) interval stays at 1s but duration drops from 20s to 8s, and only activates when the responded-to block had `requiresResponse = true`. The 2-consecutive-empty guard before clearing blocks is preserved.

### 2. Same-BlockID Write Debouncing on Mac

BlockService holds a pending-write buffer keyed by `blockID`. If a new `emit_block()` arrives for the same `blockID` within 500ms of the previous write, the earlier write is cancelled and replaced with the newer payload. If 500ms passes with no further update for that `blockID`, the write fires. `clear_block()` calls bypass debounce and execute immediately, cancelling any pending debounced write for that `blockID`. Blocks with `requiresResponse = true` bypass debounce and write immediately.

### 3. Expiry Cleanup Moves to Mac

Mac's HeartbeatService adds an expiry-cleanup step on each 30s heartbeat cycle — queries all RKBlocks for the machine, deletes any with `expiresAt < now`. iOS `fetchBlocks()` removes the CloudKit delete calls for expired records and simply skips them in the returned list. iOS does not delete records it did not create.

### 4. Push Subscription Filtered to Actionable Blocks

The CKQuerySubscription predicate changes to `requiresResponse == 1`. Non-actionable blocks are caught by the 15s poll. Old unfiltered subscription (`ask-rkblock-changes-v2`) is deleted and replaced with `ask-rkblock-actionable-v1`. Silent push behavior is unchanged (no alert/badge/sound).

### 5. Typing Indicator Debouncing

On both Mac and iOS, `updateTyping()` debounces writes to once every 2 seconds — if called again within 2s, the pending write is replaced, not fired. `clearTyping()` bypasses debounce on both sides and fires immediately so dots disappear promptly.

## Out of Scope

- Batching unrelated block writes across different blockIDs
- Changing CloudKit record schema
- CKServerChangeToken / delta sync (deferred to follow-on spec)
- Changes to the response flow (already fast)

## Change Log

| Date | Change |
|---|---|
| 2026-04-08 | Initial spec |
| 2026-04-08 | Implement all 5 requirements |
