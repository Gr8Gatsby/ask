# Unified Action Queue

**Issue:** #35
**Status:** In Progress

## Overview

The home screen transitions from a script-tile layout to a unified action queue that surfaces actionable blocks across all machines in a single prioritized feed. Same-script alerts from multiple machines collapse into one card. Resolved and dismissed actions are saved to the Feed tab as collapsed history entries. A new `quick_reply` block type enables compact inline responses.

---

## Block Model Additions

### `urgency` field

An optional field added to the payload of `confirmation`, `prompt`, `chat_prompt`, `quick_reply`, and `alert` blocks.

| Value | Badge | Sort position |
|---|---|---|
| `urgent` | `[!]` red | Top |
| `warning` | `[~]` yellow/orange | Middle |
| `info` | `[i]` gray/blue | Bottom |

- Blocks with `requiresResponse: true` that omit `urgency` default to `warning`.
- `requiresResponse: false` blocks are not shown in the Needs Response queue.

### `quick_reply` block type

A compact response block for the home queue.

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | `String` | Yes | The question or action required |
| `description` | `String?` | No | One-line context (truncated at 60 chars) |
| `options` | `[String]` | Yes | Button labels (max 3) |
| `allow_custom` | `Bool?` | No | Adds a free-text input option |
| `urgency` | `String?` | No | `urgent` / `warning` / `info` (default: `warning`) |

Response value: the tapped option label, or free-text string if `allow_custom` was used. Delivered via the existing `RKResponse` CloudKit mechanism.

---

## Home Screen Layout

### "Needs Response" section

- Contains all actionable blocks across all machines in a single unified feed.
- Section header shows a count badge with the number of actionable items.
- Sort order: urgent → warning → info → unset; oldest first within each tier.

**Multi-machine collapse:** When the same `scriptID` has actionable blocks on N > 1 machines, they collapse into a single card. The card shows a secondary badge indicating the machine count (e.g. "2 machines"). Machine names appear as small secondary text, not primary organizers.

**Multi-machine response:** Tapping a response button on a collapsed card sends the same response to all N machines simultaneously, unless N > 5, in which case a machine picker is shown first so the user can select which machines to respond to.

### "Recent" section

- Contains currently non-actionable blocks (informational, status, tile, icon).
- Sorted by time, most recent first.
- No urgency badge or collapse behavior.

### Resolved / dismissed actions → Feed tab

- When the user responds to or dismisses a block, the block is saved as a collapsed history entry in the Feed tab before the response is submitted.
- In the Feed tab, resolved action entries appear small and collapsed by default.
- Tapping a collapsed entry expands it to show the full block detail and the user's response.

---

## `quick_reply` Card Behavior

- Renders urgency badge, title, description, and option buttons inline — both in the home queue and in `ScriptDetailView`.
- Tapping an option button submits the response without navigating away from the current view.
- If `allow_custom` is true, a text input button is also shown inline.
- After response is submitted, the card is saved to Feed history and removed from the queue.

---

## Mac Script SDK

- Scripts can include `urgency` in the payload of `confirmation`, `alert`, `prompt`, `chat_prompt`, and `quick_reply` blocks.
- Scripts can emit `quick_reply` blocks with the payload fields above.
- No changes to the response format — `RKResponse` CloudKit record is unchanged.

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-08 | Initial spec created from issue #35 |
| 2026-04-08 | `quick_reply` inline response confirmed for both home queue and ScriptDetailView |
| 2026-04-08 | Multi-machine response: respond to all if N ≤ 5, show picker if N > 5 |
