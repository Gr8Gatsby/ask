# Ask Block System

Blocks are the UI primitives that Mac scripts push to the iOS app via CloudKit. Each block has a `blockType`, a JSON `payloadJSON`, and script identity metadata (`scriptName`, `scriptIcon`, `scriptIconData`, `scriptIconSVG`) embedded in the record.

**This file must be kept up to date whenever a block type is added, removed, or modified.**

---

## Block Summary Table

| Block Type | JSON Value | Requires Response | Purpose |
|---|---|:---:|---|
| [Confirmation](#confirmation) | `confirmation` | Yes | Present choices to the user |
| [Alert](#alert) | `alert` | No | Notify the user of an event |
| [Status](#status) | `status` | No | Show a labeled status with color |
| [Prompt](#prompt) | `prompt` | Yes | Free-text input from the user |
| [Chat Prompt](#chat-prompt) | `chat_prompt` | Yes | Conversational reply with context |
| [Info Card](#info-card) | `info_card` | No | Key-value data display |
| [Icon Card](#icon-card) | `icon_card` | No | Script identity card with icon |
| [Tile](#tile) | `tile` | No | Home-screen tile update |
| [Countdown](#countdown) | `countdown` | No | Live countdown to a timestamp |
| [Picker](#picker) | `picker` | Yes | Select one option from a list |
| [List](#list) | `list` | Yes | Selectable item list with actions |
| [Detail](#detail) | `detail` | Yes | Long-form text with action buttons |

---

## Block Model

Every block record (`RKBlock`) carries:

```
id              String        — unique block ID (CloudKit record name)
machineID       String        — source machine
scriptID        String        — source script
scriptName      String?       — display name for section headers
scriptIcon      String?       — SF Symbol name (fallback icon)
scriptIconData  String?       — base64-encoded 32×32 PNG
scriptIconSVG   String?       — raw SVG markup (preferred)
blockType       RKBlockType   — enum value
payloadJSON     String        — JSON blob decoded per block type
createdAt       Date
expiresAt       Date?
```

**Implementations:**
- Type enum + payload structs: [`ask/ask/RemoteKitModels.swift`](../ask/ask/RemoteKitModels.swift)
- CloudKit field names (iOS): [`ask/ask/AskModels.swift`](../ask/ask/AskModels.swift)
- CloudKit field names (Mac): [`AskMac/Sources/AskMac/Models/CloudKitSchema.swift`](../AskMac/Sources/AskMac/Models/CloudKitSchema.swift)

---

## Confirmation

Presents a question with labelled buttons. Renders buttons inline when ≤ 2 options, as a vertical list when > 2.

```
╭─────────────────────────────────╮
│  Deploy to production?          │
│                                 │
│  This will push v2.4.1 to all   │
│  production servers.            │
│                                 │
│  ┌─────────────┐ ┌───────────┐  │
│  │   Deploy    │ │  Cancel   │  │
│  └─────────────┘ └───────────┘  │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Main prompt text |
| `body` | `String` | Supporting description |
| `options` | `[String]` | Button labels |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ConfirmationBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `ConfirmationPreview`

---

## Alert

Notifies the user of an event. No response required.

```
╭─────────────────────────────────╮
│  🔔  Build Failed               │
│                                 │
│  Unit tests failed on step 3    │
│  of the CI pipeline. Check      │
│  the logs for details.          │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Alert heading |
| `body` | `String` | Alert message |
| `icon` | `String?` | SF Symbol name (default: `bell.fill`) |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `AlertBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `AlertPreview`

---

## Status

Shows a labeled status indicator with optional color and detail text.

```
╭─────────────────────────────────╮
│  ● Deployment Running           │
│    Step 3 of 7 — uploading      │
│    assets to S3                 │
╰─────────────────────────────────╯
```

Color values for `●`: `green`, `blue`, `orange`, `red`, `yellow` (or secondary if omitted).

**Payload:**

| Field | Type | Description |
|---|---|---|
| `label` | `String` | Status text |
| `detail` | `String?` | Secondary detail text |
| `icon` | `String?` | SF Symbol name |
| `color` | `String?` | Dot color: `green` `blue` `orange` `red` `yellow` |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `StatusBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `StatusPreview`

---

## Prompt

Collects free-text input from the user. Supports single-line or multi-line entry.

```
╭─────────────────────────────────╮
│  Commit message                 │
│                                 │
│  ┌─────────────────────────┐    │
│  │ Fix login timeout bug   │    │
│  └─────────────────────────┘    │
│                                 │
│         ┌──────────┐            │
│         │  Submit  │            │
│         └──────────┘            │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Label above the input field |
| `placeholder` | `String?` | Input field placeholder text |
| `multiline` | `Bool?` | Expand to ~4 lines when true |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `PromptBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `PromptPreview`

---

## Chat Prompt

A conversational reply block. Shows Claude's previous message as context above the input field.

```
╭─────────────────────────────────╮
│  ╭───────────────────────────╮  │
│  │ I found 3 failing tests.  │  │
│  │ Should I attempt auto-    │  │
│  │ fixes or open a ticket?   │  │
│  ╰───────────────────────────╯  │
│                                 │
│  ┌─────────────────────────┐    │
│  │ Reply to Claude…        │    │
│  └─────────────────────────┘    │
│         ┌──────────┐            │
│         │  Send    │            │
│         └──────────┘            │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Input field label |
| `context` | `String?` | Claude's message shown above the input |
| `placeholder` | `String?` | Placeholder (default: "Reply to Claude…") |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ChatPromptBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `PromptPreview` (shared with prompt)

---

## Info Card

Displays a set of key-value pairs in a card layout.

```
╭─────────────────────────────────╮
│  Pull Request #482              │
│  ─────────────────────────────  │
│  Branch       feature/auth      │
│  Author       kevin             │
│  Status       ● Ready           │
│  Changed      14 files          │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Card heading |
| `pairs` | `[{key, value}]` | Array of key-value rows |
| `pairs[].key` | `String` | Left column (secondary style) |
| `pairs[].value` | `String` | Right column (bold) |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `InfoCardBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `InfoCardPreview`

---

## Icon Card

Displays the script's icon prominently with a title and optional subtitle. Icon comes from the block's script metadata, not the payload.

```
╭─────────────────────────────────╮
│                                 │
│         ┌──────────┐            │
│         │  [ICON]  │            │
│         └──────────┘            │
│                                 │
│       Deploy Manager            │
│    Production environment       │
│                                 │
╰─────────────────────────────────╯
```

Icon source priority: `scriptIconData` (base64 PNG) → `scriptIcon` (SF Symbol).

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Card title |
| `subtitle` | `String?` | Secondary text below title |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `IconCardBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `IconCardPreview`

---

## Tile

Drives the home-screen tile for a script. Not shown in the block detail view — iOS extracts this block to update the tile display.

```
╭───────────────────────╮
│  Deploy Manager       │
│  ● Running  14:32     │
│                       │
│  Uploading assets…    │
╰───────────────────────╯
   (home screen tile)
```

`actionRequired: true` triggers an orange border and a toast notification on the home screen.

**Payload:**

| Field | Type | JSON Key | Description |
|---|---|---|---|
| `label` | `String` | `label` | Short status text (<50 chars) |
| `statusColor` | `String?` | `status_color` | Color of the status dot |
| `body` | `String?` | `body` | Multi-line update text below label |
| `actionRequired` | `Bool?` | `action_required` | Triggers action-required styling |

**Implementations:**
- iOS home tile: [`ask/ask/HomeView.swift`](../ask/ask/HomeView.swift) — `ScriptTileView`
- Mac: renders as `EmptyView` (tile blocks are iOS-only)

---

## Countdown

Displays a live countdown to an ISO 8601 timestamp. Updates every 30 seconds. Shows "overdue" when past the target time.

```
╭─────────────────────────────────╮
│  ⏱  Code Freeze                 │
│                                 │
│         about 2 hours           │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `label` | `String` | Countdown label |
| `time` | `String` | ISO 8601 UTC timestamp (e.g. `2025-03-31T18:00:00Z`) |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `CountdownBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `CountdownPreview`

---

## Picker

Presents a dropdown picker. The user selects one option and taps Select.

```
╭─────────────────────────────────╮
│  Target environment             │
│                                 │
│  ┌────────────────────────┐     │
│  │  staging            ▼  │     │
│  └────────────────────────┘     │
│                                 │
│         ┌──────────┐            │
│         │  Select  │            │
│         └──────────┘            │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Picker label |
| `options` | `[String]` | Selectable options |
| `selected` | `String?` | Pre-selected value (defaults to first option) |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `PickerBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `PickerPreview`

---

## List

A selectable list of items with optional action buttons below. Tapping an item typically triggers a navigation push to a Detail block. Mac shows max 5 items with a "+ N more" indicator.

```
╭─────────────────────────────────╮
│  Open Pull Requests             │
│  ─────────────────────────────  │
│  #482  feature/auth          >  │
│        Ready for review         │
│  #479  fix/timeout           >  │
│        2 reviewers approved     │
│  #471  chore/deps            >  │
│        Needs rebase             │
│  ─────────────────────────────  │
│  ┌──────────────────────────┐   │
│  │       Refresh            │   │
│  └──────────────────────────┘   │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String?` | Optional list header |
| `items` | `[Item]` | List items |
| `items[].id` | `String` | Unique item identifier |
| `items[].label` | `String` | Item display text |
| `items[].subtitle` | `String?` | Secondary text |
| `actions` | `[String]?` | Action button labels below the list |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ListBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `ListPreview`

---

## Detail

Long-form text view with optional action buttons. Often pushed as a navigation destination after selecting a List item.

```
╭─────────────────────────────────╮
│  PR #482 — feature/auth         │
│  ─────────────────────────────  │
│  Adds OAuth2 token refresh      │
│  logic to the auth middleware.  │
│  Fixes the 401 loop seen in     │
│  staging after token expiry.    │
│                                 │
│  Tests: 42 added, 0 failing.    │
│  Coverage: 87% (+3%).           │
│                                 │
│  ┌──────────┐  ┌─────────────┐  │
│  │  Merge   │  │  Close PR   │  │
│  └──────────┘  └─────────────┘  │
╰─────────────────────────────────╯
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Detail heading |
| `body` | `String` | Long-form text content (scrollable) |
| `actions` | `[String]?` | Action button labels |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `DetailBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `DetailPreview`
