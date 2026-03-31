# Functional Spec: New Block Types — Progress, Log, Image, Multi-select, Toggle

## Overview

Add five new block types to the Ask block system to cover common supervision patterns not served by existing blocks.

---

## Progress Block (`progress`)

**Requires response:** No

Displays a progress bar with a label and optional step indicator. Used for long-running tasks where the script emits incremental updates.

**Payload fields:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `label` | String | Yes | Description of the current operation |
| `value` | Float | Yes | Progress from `0.0` (empty) to `1.0` (complete) |
| `detail` | String? | No | Secondary text below the bar (e.g. "14 of 47 files") |

**Behavior:**
- The progress bar fills proportionally to `value`.
- `value` of `1.0` renders a full bar; no automatic "done" state or visual change — scripts send a different block type (e.g. `status`) to signal completion.
- `detail` is optional; when omitted only the label and bar are shown.

---

## Log Block (`log`)

**Requires response:** No

Displays scrollable monospace terminal output. Designed for script stdout/stderr or structured command output.

**Payload fields:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | String? | No | Optional header above the output |
| `lines` | [String] | Yes | Lines of output text, rendered in order |
| `status` | String? | No | `running` · `done` · `failed` · `warning` — shown as a colored indicator next to the title |

**Behavior:**
- Text is rendered in a monospace font.
- Output is scrollable; the view scrolls to the last line on initial display.
- `status` is optional; when provided it shows a colored dot next to the title (`running` → blue, `done` → green, `failed` → red, `warning` → orange).
- When `title` is omitted and `status` is omitted, only the raw output is shown.

---

## Image Block (`image`)

**Requires response:** No

Displays an image with an optional caption. Used for screenshots, charts, or diagrams generated or captured by a script.

**Payload fields:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `data` | String | Yes | Base64-encoded image (PNG or JPEG) |
| `caption` | String? | No | Optional text below the image |
| `alt` | String? | No | Accessibility description of the image |

**Behavior:**
- The image is decoded from base64 and displayed at full available width, maintaining aspect ratio.
- Tapping the image presents it full-screen.
- `caption` is displayed below the image in secondary style when provided.
- `alt` is used as the accessibility label; falls back to `caption` if omitted, then to "Image".

---

## Multi-select Block (`multi_select`)

**Requires response:** Yes

Like `list` but allows the user to select multiple items before submitting. Returns the array of selected item IDs.

**Payload fields:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | String? | No | Optional header above the list |
| `items` | [Item] | Yes | Selectable items |
| `items[].id` | String | Yes | Unique identifier returned in response |
| `items[].label` | String | Yes | Item display text |
| `items[].subtitle` | String? | No | Secondary text |
| `items[].selected` | Bool? | No | Pre-selected state (default: false) |
| `submit_label` | String? | No | Submit button label (default: "Submit") |
| `min` | Int? | No | Minimum number of selections required before submit is enabled |
| `max` | Int? | No | Maximum number of selections allowed |

**Behavior:**
- Items render with a checkmark when selected and no checkmark when deselected. Tapping toggles selection.
- The submit button is disabled until `min` selections are met (if specified).
- When `max` is reached, unselected items are visually disabled.
- Response value is a JSON array of selected item IDs: `["id1", "id3"]`.

---

## Toggle Block (`toggle`)

**Requires response:** Yes

Presents a set of labeled on/off switches. Used for feature flags, options, or settings before executing a command. Returns a JSON object of key → boolean values.

**Payload fields:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | String? | No | Optional header above the toggles |
| `items` | [Item] | Yes | Toggle switches |
| `items[].key` | String | Yes | Identifier returned in response |
| `items[].label` | String | Yes | Display label next to the switch |
| `items[].detail` | String? | No | Optional description below the label |
| `items[].value` | Bool? | No | Initial state (default: false) |
| `submit_label` | String? | No | Submit button label (default: "Submit") |

**Behavior:**
- Each item renders as a labeled `Toggle` switch.
- The user can change any combination of switches before submitting.
- Response value is a JSON object: `{"feature_x": true, "debug_mode": false}`.

---

## Out of Scope

- **Form block** — a composite block combining multiple input types. Deferred; the existing blocks cover most cases.
- Server-side validation of `value` ranges (scripts are responsible for interpreting responses).
- Animated progress bar transitions (static render at the current `value`).

---

## Changelog

| Date | Change |
|---|---|
| 2026-03-31 | Initial spec |
