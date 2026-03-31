# Loading States — Functional Specification

## Overview

The iOS client application must provide clear, consistent visual feedback when async operations are in progress. Controls must be non-interactive while their associated operation is running. A loading indicator, once shown, must remain visible until the operation fully completes. The user must never see a state where the UI appears ready to accept input but is actually waiting on a background operation.

Loading feedback must be scoped to the individual control or component that triggered the operation — not the full screen. The app must feel native: individual buttons show spinners, individual list rows reflect their own loading state, and the rest of the screen remains visible and unblocked.

---

## Requirements

### 1. Control State During Operations

- Any control (button, text field, picker, navigation link) that triggers an async operation must become non-interactive immediately when that operation begins.
- A control must remain non-interactive until the operation has fully completed (whether successfully or with an error).
- A control must not briefly become interactive during an operation and then return to a loading state — the interactive period must be zero.

### 2. Visual Feedback

- Loading feedback must be inline and scoped to the control or component that triggered the operation. Full-screen spinners or overlays must not be used.
- A button that triggers an async operation must replace its label with a spinner for the duration of the operation, then restore its label when complete.
- A list row or card that is loading must show a spinner within that row/card — the rest of the list must remain visible and scrollable.
- The loading indicator must remain visible for the full duration of the operation, not flash briefly and disappear while the operation is still in progress.
- Controls in a loading state must appear visually distinct from ready controls (e.g., reduced opacity, label replaced by spinner).

### 3. Preventing Duplicate Operations

- Tapping a control multiple times while an operation is in progress must not enqueue multiple operations or produce duplicate results.
- A second tap on a control that is already loading must have no effect.

### 4. Navigation During Loading

- Navigation away from a view must not be possible if the view has an operation in progress that would produce an unresolvable inconsistent state.
- Navigation controls (back, close, dismiss) must follow the same non-interactive rules as action controls when a blocking operation is underway.

### 5. Scope of Affected Interactions

The following interactions are known to currently lack proper loading state coverage:

- **Message send:** Sending a message in MessagesView must be guarded — the send control and text input must become non-interactive from the moment "send" is invoked until the operation completes.
- **Machine selection:** Switching the active machine in HomeView triggers a data load; the machine picker must be non-interactive for the duration of that load.
- **Queue item send:** Sending an individual item from the offline queue must disable that item's send control until the send completes.
- **All block response actions:** Any block interaction (confirmation, prompt, picker, list action) that is already sending a response must prevent a second send of the same block. (This is mostly implemented but must be verified to be gapless.)

### 6. Error Recovery

- After a failed operation, controls must return to their interactive state so the user can retry.
- An error must be surfaced to the user before controls become interactive again.

---

## Non-Goals

- This spec does not cover server-side deduplication of responses.
- This spec does not require optimistic UI updates to be added where they do not exist today.
- Skeleton screens or shimmer effects are not required.
- Full-screen loading overlays or spinners are explicitly out of scope — all loading feedback must be component-level.

---

## Change Log

| Date | Change |
|---|---|
| 2026-03-31 | Initial spec created for GitHub issue #5 |
| 2026-03-31 | Clarified: loading feedback must be component-level (inline spinners), not full-screen overlays |
| 2026-03-31 | Implemented: removed full-screen "Waiting for response…" spinner from ScriptDetailView; added isSending guard + inline spinner to MessagesView send button |
