# Ask Block System

Blocks are the UI primitives that Mac scripts push to the iOS app via CloudKit. Each block has a `blockType`, a JSON `payloadJSON`, and script identity metadata (`scriptName`, `scriptIcon`, `scriptIconData`, `scriptIconSVG`) embedded in the record.

**This file must be kept up to date whenever a block type is added, removed, or modified.**

---

## Block Summary Table

### Implemented

| Block Type | JSON Value | Requires Response | Purpose |
|---|---|:---:|---|
| [Confirmation](#confirmation) | `confirmation` | Yes | Present choices to the user |
| [Alert](#alert) | `alert` | No | Notify the user of an event |
| [Status](#status) | `status` | No | Show a labeled status with color |
| [Prompt](#prompt) | `prompt` | Yes | Free-text input from the user |
| [Chat Prompt](#chat-prompt) | `chat_prompt` | Yes | Conversational reply with context |
| [Claude Message](#claude-message) | `claude_message` | No | Display Claude's last message in formatted markdown |
| [Agent Session](#agent-session) | `agent_session` | Yes | Interactive session card for Claude Code / Codex |
| [Start Session](#start-session) | `start_session` | Yes | Repo picker to launch a new agent session |
| [Info Card](#info-card) | `info_card` | No | Key-value data display |
| [Icon Card](#icon-card) | `icon_card` | No | Script identity card with icon |
| [Tile](#tile) | `tile` | No | Home-screen tile update |
| [Countdown](#countdown) | `countdown` | No | Live countdown to a timestamp |
| [Picker](#picker) | `picker` | Yes | Select one option from a list |
| [List](#list) | `list` | Yes | Selectable item list with actions |
| [Detail](#detail) | `detail` | Yes | Long-form text with action buttons |
| [Feed Item](#feed-item) | `feed_item` | No | Entry in the Feed tab |

### Planned (not yet implemented)

| Block Type | JSON Value | Requires Response | Purpose |
|---|---|:---:|---|
| [Quick Reply](#quick-reply) | `quick_reply` | Yes | Compact inline response — title, description, and buttons on 2-3 lines |
| [Progress](#progress) | `progress` | No | Progress bar for long-running tasks |
| [Log](#log) | `log` | No | Scrollable monospace terminal output |
| [Image](#image) | `image` | No | Display a base64-encoded image |
| [Multi-select](#multi-select) | `multi_select` | Yes | Select multiple items before submitting |
| [Toggle](#toggle) | `toggle` | Yes | Set of on/off switches |

---

## Block Model

Every block record (`RKBlock`) carries:

```
id              String        -- unique block ID (CloudKit record name)
machineID       String        -- source machine
scriptID        String        -- source script
scriptName      String?       -- display name for section headers
scriptIcon      String?       -- SF Symbol name (fallback icon)
scriptIconData  String?       -- base64-encoded 32x32 PNG
scriptIconSVG   String?       -- raw SVG markup (preferred)
blockType       RKBlockType   -- enum value
payloadJSON     String        -- JSON blob decoded per block type
createdAt       Date
expiresAt       Date?
```

**Implementations:**
- Type enum + payload structs: [`ask/ask/RemoteKitModels.swift`](../ask/ask/RemoteKitModels.swift)
- CloudKit field names (iOS): [`ask/ask/AskModels.swift`](../ask/ask/AskModels.swift)
- CloudKit field names (Mac): [`AskMac/Sources/AskMac/Models/CloudKitSchema.swift`](../AskMac/Sources/AskMac/Models/CloudKitSchema.swift)

### Urgency

Blocks that appear in the home screen "Needs Response" queue support an optional `urgency` field in their payload. This controls sort order and badge style in the queue.

| Value | Badge | Sort |
|---|---|---|
| `urgent` | `[!]` red | Top |
| `warning` | `[~]` yellow | Middle |
| `info` | `[i]` gray | Bottom |

If omitted, `requiresResponse: true` blocks default to `warning`; `requiresResponse: false` blocks are not shown in the queue.

Applicable to: `confirmation`, `prompt`, `chat_prompt`, `quick_reply`, `alert` (when `action_required` is set).

---

## Confirmation

Presents a question with labelled buttons. Renders buttons inline when <= 2 options, as a vertical list when > 2.

```
+---------------------------------+
|  Deploy to production?          |
|                                 |
|  This will push v2.4.1 to all   |
|  production servers.            |
|                                 |
|  +-------------+ +-----------+  |
|  |   Deploy    | |  Cancel   |  |
|  +-------------+ +-----------+  |
+---------------------------------+
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Main prompt text |
| `body` | `String` | Supporting description |
| `options` | `[String]` | Button labels |
| `session_id` | `String?` | Links this confirmation to an agent session |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ConfirmationBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `ConfirmationPreview`

---

## Alert

Notifies the user of an event. No response required.

```
+---------------------------------+
|  [!]  Build Failed              |
|                                 |
|  Unit tests failed on step 3    |
|  of the CI pipeline. Check      |
|  the logs for details.          |
+---------------------------------+
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
+---------------------------------+
|  * Deployment Running           |
|    Step 3 of 7 -- uploading     |
|    assets to S3                 |
+---------------------------------+
```

Color values for `*`: `green`, `blue`, `orange`, `red`, `yellow` (or secondary if omitted).

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
+---------------------------------+
|  Commit message                 |
|                                 |
|  +-------------------------+    |
|  | Fix login timeout bug   |    |
|  +-------------------------+    |
|                                 |
|         +----------+            |
|         |  Submit  |            |
|         +----------+            |
+---------------------------------+
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

A conversational reply block. Shows Claude's previous message as context above the input field. The `context` field is rendered as formatted markdown.

```
+---------------------------------+
|  +---------------------------+  |
|  | (o) Claude Code           |  |
|  |                           |  |
|  | I found **3 failing       |  |
|  | tests**. Should I attempt |  |
|  | auto-fixes or open a      |  |
|  | ticket?                   |  |
|  +---------------------------+  |
|                                 |
|  +-------------------------+    |
|  | Reply to Claude...      |    |
|  +-------------------------+    |
|         +----------+            |
|         |   Send   |            |
|         +----------+            |
+---------------------------------+
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Input field label |
| `context` | `String?` | Claude's message shown above the input -- rendered as markdown |
| `placeholder` | `String?` | Placeholder (default: "Reply to Claude...") |

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ChatPromptBlockView`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `PromptPreview` (shared with prompt)

---

## Claude Message

Displays Claude Code's last response in formatted markdown. Emitted by the Claude Code `Stop` hook when Claude finishes a response that does not require user input to continue. No reply input -- informational only.

```
+---------------------------------+
|  (o) Claude Code                |
|  -----------------------------  |
|  ## Analysis complete           |
|                                 |
|  I've reviewed the codebase     |
|  and found **3 issues**:        |
|                                 |
|  - Auth token not refreshed     |
|  - Missing error handling in    |
|    `fetchUser()`                |
|  - Stale cache on logout        |
|                                 |
|  All fixes are committed.       |
+---------------------------------+
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `text` | `String` | Claude's full response -- rendered as markdown |
| `session_id` | `String?` | Claude Code session ID (for context grouping) |

**Markdown rendering:** Supports headings, bold, italic, inline code, fenced code blocks, bulleted and numbered lists, and blockquotes. Tables are rendered as plain key-value rows.

**Implementations:**
- iOS view: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `ClaudeMessageBlockView`
- Mac: not applicable (Stop hook is the source, not a script)

---

## Agent Session

An interactive session card for an active Claude Code or Codex session. One block per session, keyed by a hash of the session ID. Shows the agent's last message (or working indicator) and a reply input. Supports collapse to save space when multiple sessions are open.

```
+---------------------------------+
|  code/myapp [a3f9]          ^   |
|                                 |
|  +--------------------------+   |
|  | I've updated the auth    |   |
|  | middleware. All tests     |   |
|  | pass.                    |   |
|  +--------------------------+   |
|                                 |
|  +---------------------+  (->)  |
|  | Reply to Claude...  |        |
|  +---------------------+        |
+---------------------------------+
```

Collapsed state shows last message inline in the header row.

**Payload:**

| Field | Type | JSON Key | Description |
|---|---|---|---|
| `session_id` | `String` | `session_id` | Unique session identifier |
| `project` | `String` | `project` | Display label (e.g. `code/myapp [a3f9]`) |
| `cwd` | `String` | `cwd` | Working directory of the session |
| `last_message` | `String?` | `last_message` | Agent's most recent text response |
| `is_working` | `Bool?` | `is_working` | Shows spinner when true |
| `agent_name` | `String?` | `agent_name` | Display name (e.g. `Claude Code`, `Codex`) |
| `brand_color` | `String?` | `brand_color` | Hex color for accents (e.g. `#74AA9C`) |
| `placeholder` | `String?` | `placeholder` | Reply field placeholder text |

**Block ID:** `sha256(session_id)[:8]` prefixed with the script ID (e.g. `claudecode-session-a3f91c2b`). This makes IDs stable across restarts.

**Sources:**
- `claudecode-controller` — emits on session start, tool use, and stop
- `codex-controller` — emits on session start, tool use, stop, and tmux pane response capture

**Implementations:**
- iOS session list row: [`ask/ask/SessionChatView.swift`](../ask/ask/SessionChatView.swift) — `SessionRowView` (shown in ScriptDetailView session list)
- iOS session chat: [`ask/ask/SessionChatView.swift`](../ask/ask/SessionChatView.swift) — `SessionChatView` (full-screen chat; navigated to from the session list row)
- iOS legacy card: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `AgentSessionBlockView` (used in Mac Blocks builder preview only)
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `AgentSessionPreview`

**iOS navigation context:**
Tapping a script tile on the home screen opens `ScriptDetailView`, which shows one `SessionRowView` per `agent_session` block. Tapping a row navigates into `SessionChatView` — a full-screen chat thread that accumulates local history via SwiftData (`ChatSession`, `ChatEntry`). The session chat shows outgoing messages (user), incoming agent responses (`last_message` updates), inline block cards (confirmation/permission blocks linked to this `session_id`), and system events. When the `agent_session` block is cleared (session ended), the chat history is deleted and the view pops back to the session list.

---

## Start Session

Emitted persistently by `claudecode-controller` and `codex-controller`. Drives the "+" button in the script detail view's bottom bar. When the user picks a repo, the response value (repo path) is routed back to the controller which launches a new session via tmux or Terminal.app.

```
+---------------------------------+
|  + Start Session                |
|                                 |
|  (opens repo picker sheet)      |
|                                 |
|  +---------------------------+  |
|  | code/myapp                |  |
|  | code/api-server           |  |
|  | code/dashboard            |  |
|  +---------------------------+  |
+---------------------------------+
```

**Payload:**

| Field | Type | Description |
|---|---|---|
| `repos` | `[{name, path}]` | Git repos discovered on the Mac |
| `repos[].name` | `String` | Display name (last 2 path components) |
| `repos[].path` | `String` | Absolute path used as the response value |

**Block ID:** Fixed per controller: `claudecode-start-session` / `codex-start-session`.

**Implementations:**
- iOS "+" button: rendered in `detailBottomBar` of [`ask/ask/HomeView.swift`](../ask/ask/HomeView.swift) — `ScriptDetailView`; visible only when this block is present
- iOS repo picker: [`ask/ask/BlockViews.swift`](../ask/ask/BlockViews.swift) — `RepoPickerSheet`
- Mac preview: [`AskMac/Sources/AskMac/Views/BlockPreviewViews.swift`](../AskMac/Sources/AskMac/Views/BlockPreviewViews.swift) — `StartSessionPreview`

---

## Info Card

Displays a set of key-value pairs in a card layout.

```
+---------------------------------+
|  Pull Request #482              |
|  -----------------------------  |
|  Branch       feature/auth      |
|  Author       kevin             |
|  Status       * Ready           |
|  Changed      14 files          |
+---------------------------------+
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
+---------------------------------+
|                                 |
|         +----------+            |
|         |  [ICON]  |            |
|         +----------+            |
|                                 |
|       Deploy Manager            |
|    Production environment       |
|                                 |
+---------------------------------+
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

Drives the home-screen tile for a script. Not shown in the block detail view -- iOS extracts this block to update the tile display.

```
+-----------------------+
|  Deploy Manager       |
|  * Running  14:32     |
|                       |
|  Uploading assets...  |
+-----------------------+
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
+---------------------------------+
|  [T]  Code Freeze               |
|                                 |
|         about 2 hours           |
+---------------------------------+
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
+---------------------------------+
|  Target environment             |
|                                 |
|  +------------------------+     |
|  |  staging            v  |     |
|  +------------------------+     |
|                                 |
|         +----------+            |
|         |  Select  |            |
|         +----------+            |
+---------------------------------+
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
+---------------------------------+
|  Open Pull Requests             |
|  -----------------------------  |
|  #482  feature/auth          >  |
|        Ready for review         |
|  #479  fix/timeout           >  |
|        2 reviewers approved     |
|  #471  chore/deps            >  |
|        Needs rebase             |
|  -----------------------------  |
|  +---------------------------+  |
|  |         Refresh           |  |
|  +---------------------------+  |
+---------------------------------+
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
+---------------------------------+
|  PR #482 -- feature/auth        |
|  -----------------------------  |
|  Adds OAuth2 token refresh      |
|  logic to the auth middleware.  |
|  Fixes the 401 loop seen in     |
|  staging after token expiry.    |
|                                 |
|  Tests: 42 added, 0 failing.    |
|  Coverage: 87% (+3%).           |
|                                 |
|  +----------+  +-------------+  |
|  |  Merge   |  |  Close PR   |  |
|  +----------+  +-------------+  |
+---------------------------------+
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

---

## Feed Item

An entry displayed in the iOS Feed tab. Feed items are aggregated chronologically across all scripts. Not shown in the script detail block list.

**Payload:**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Item heading |
| `body` | `String?` | Item body text |
| `timestamp` | `String?` | ISO 8601 timestamp for display ordering |
| `icon` | `String?` | SF Symbol name |
| `color` | `String?` | Accent color: `green` `blue` `orange` `red` `yellow` |

**Implementations:**
- iOS view: Feed tab (`FeedView.swift`)
- Mac: not applicable

---

## Quick Reply

A compact response block designed for the home screen "Needs Response" queue. Renders the title, a single line of description, and action buttons together — no nested containers or stacked sections. Use this instead of `confirmation` when the decision is simple and context fits in one sentence.

```
+----------------------------------+
| [!] Delete 47 migration files?   |
| This cannot be undone.           |
| [Yes]  [No]  [Custom..]          |
+----------------------------------+
```

With only 2 options (no custom), buttons stay inline:

```
+----------------------------------+
| [~] Deploy to staging?           |
| Branch: feature/auth             |
| [Deploy]              [Cancel]   |
+----------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | `String` | Yes | The question or action required |
| `description` | `String?` | No | One-line context (kept short — truncated if > 60 chars) |
| `options` | `[String]` | Yes | Button labels (max 3; if > 2, renders as a compact vertical stack) |
| `allow_custom` | `Bool?` | No | Adds a "Custom.." button that opens a single-line text input |
| `urgency` | `String?` | No | `urgent` `warning` `info` — controls badge and sort order (default: `warning`) |

Response: the tapped option label as a plain string, or the custom text if `allow_custom` was used.

---

## Progress

Displays a progress bar with a label and optional step indicator. Used for long-running tasks where the script emits incremental updates.

```
+---------------------------------+
|  Uploading assets               |
|  [=========>         ] 47%      |
|  14 of 47 files                 |
+---------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `label` | `String` | Yes | Description of the current operation |
| `value` | `Float` | Yes | Progress from `0.0` (empty) to `1.0` (complete) |
| `detail` | `String?` | No | Secondary text (e.g. "14 of 47 files") |

`value` of `1.0` renders a full bar with no automatic done state — scripts send a different block (e.g. `status`) to signal completion.

---

## Log

Displays scrollable monospace terminal output. Designed for script stdout/stderr or structured command output.

```
+---------------------------------+
|  * running  Build output        |
|  ------------------------------ |
|  > npm run build                |
|  > Compiling...                 |
|  > 3 warnings, 0 errors        |
+---------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | `String?` | No | Optional header |
| `lines` | `[String]` | Yes | Lines of output, rendered in order |
| `status` | `String?` | No | `running` `done` `failed` `warning` -- colored dot next to title |

Status colors: `running` blue, `done` green, `failed` red, `warning` orange. View scrolls to the last line on initial display.

---

## Image

Displays an image with an optional caption.

```
+---------------------------------+
|  +-----------------------------+|
|  |                             ||
|  |       [image content]       ||
|  |                             ||
|  +-----------------------------+|
|  Screenshot from build step 3   |
+---------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `data` | `String` | Yes | Base64-encoded PNG or JPEG |
| `caption` | `String?` | No | Text below the image |
| `alt` | `String?` | No | Accessibility label (falls back to caption, then "Image") |

Tapping the image presents it full-screen.

---

## Multi-select

Like `list` but allows the user to select multiple items before submitting. Returns a JSON array of selected item IDs.

```
+---------------------------------+
|  Select files to stage          |
|  ------------------------------ |
|  [x]  src/auth.swift            |
|  [ ]  src/models.swift          |
|  [x]  tests/auth_tests.swift    |
|  ------------------------------ |
|         +-----------+           |
|         |  Submit   |           |
|         +-----------+           |
+---------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | `String?` | No | Optional header |
| `items` | `[Item]` | Yes | Selectable items |
| `items[].id` | `String` | Yes | Identifier returned in response |
| `items[].label` | `String` | Yes | Item display text |
| `items[].subtitle` | `String?` | No | Secondary text |
| `items[].selected` | `Bool?` | No | Pre-selected state (default: false) |
| `submit_label` | `String?` | No | Submit button label (default: "Submit") |
| `min` | `Int?` | No | Minimum selections required to enable submit |
| `max` | `Int?` | No | Maximum selections allowed |

Response: JSON array of selected IDs — `["id1", "id3"]`.

---

## Toggle

Presents a set of labeled on/off switches. Returns a JSON object of key -> boolean values.

```
+---------------------------------+
|  Build options                  |
|  ------------------------------ |
|  Run tests          [  ON  ]    |
|  Verbose output     [ OFF  ]    |
|  Clean build        [  ON  ]    |
|  ------------------------------ |
|         +-----------+           |
|         |  Submit   |           |
|         +-----------+           |
+---------------------------------+
```

**Payload:**

| Field | Type | Required | Description |
|---|---|:---:|---|
| `title` | `String?` | No | Optional header |
| `items` | `[Item]` | Yes | Toggle switches |
| `items[].key` | `String` | Yes | Identifier returned in response |
| `items[].label` | `String` | Yes | Display label |
| `items[].detail` | `String?` | No | Optional description below label |
| `items[].value` | `Bool?` | No | Initial state (default: false) |
| `submit_label` | `String?` | No | Submit button label (default: "Submit") |

Response: JSON object — `{"run_tests": true, "verbose": false}`.

---

## Changelog

| Version | Change |
|---|---|
| Added `quick_reply` | Compact inline response block for home screen queue; flat 2-3 line layout with optional free-text fallback |
| Added `urgency` field | Optional field on `confirmation`, `prompt`, `chat_prompt`, `quick_reply`, `alert` — controls queue sort order and badge style |
| Added `agent_session` | Interactive session card for Claude Code / Codex controllers |
| Added `start_session` | Repo picker to launch new sessions from iOS |
| Added `feed_item` | Feed tab entries |
| Added `session_id` to `confirmation` payload | Links permission prompts to their parent session |
| Removed emoji from ASCII art diagrams | Layout fix |
| `agent_session` iOS navigation | Now renders as a `SessionRowView` in the script detail session list; tapping opens a full-screen `SessionChatView` with local SwiftData history. `AgentSessionBlockView` retained for Mac Blocks builder preview. |
| `start_session` iOS rendering | "+" button in `ScriptDetailView` bottom bar; shown only when the block is active. |
