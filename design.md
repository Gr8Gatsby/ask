# Ask — Block Design Reference

Scripts communicate with the iPhone by emitting **blocks** via the MCP `emit_block` tool. Each block has a `blockType` that determines how it is rendered on iOS.

---

## Block Types

### `confirmation`
An interactive card with a title, optional body text, and a set of labeled buttons. The user taps one option; that value is delivered back to the script as a `user_response`.

**Payload**
```json
{
  "title": "string",
  "body": "string",
  "options": ["string", "…"]
}
```

- `title` — Bold heading shown above the body.
- `body` — Multi-line supporting text (monospaced). May be empty.
- `options` — 1–N response labels. 1–2 options render as horizontal buttons; 3+ render as a vertical radio list.

**Responds:** yes — delivers the tapped option string.

---

### `alert`
A passive notification card. No interaction. Filtered from the main block list (displayed inline when active but not persisted through polling).

**Payload**
```json
{
  "title": "string",
  "body": "string",
  "icon": "string?"
}
```

- `icon` — SF Symbol name (e.g. `"exclamationmark.triangle"`). Defaults to `"bell.fill"`.

**Responds:** no.

---

### `status`
A compact single-line status indicator with a colored dot.

**Payload**
```json
{
  "label": "string",
  "detail": "string?",
  "icon": "string?",
  "color": "green" | "blue" | "orange" | "red" | "yellow"
}
```

- `label` — Primary status text.
- `detail` — Secondary line shown below the label.
- `icon` — SF Symbol shown on the trailing edge.
- `color` — Drives the dot color and icon tint.

**Responds:** no.

---

### `prompt`
A text-input card. The user types a response and submits it.

**Payload**
```json
{
  "title": "string",
  "placeholder": "string?",
  "multiline": "bool?"
}
```

- `multiline` — When `true`, the field expands to 4 lines. Default: `false`.

**Responds:** yes — delivers the submitted text.

---

### `chat_prompt`
A conversational back-and-forth input. Shows Claude's last message as context above the text field. Updates live as the script re-emits the block with new `context`.

**Payload**
```json
{
  "title": "string",
  "context": "string?",
  "placeholder": "string?"
}
```

- `context` — The most recent message from Claude shown as a bubble above the input.
- When the script re-emits this block with new `context`, the iOS view auto-updates.

**Responds:** yes — delivers the submitted text.

---

### `info_card`
A read-only key-value table.

**Payload**
```json
{
  "title": "string",
  "pairs": [
    { "key": "string", "value": "string" }
  ]
}
```

**Responds:** no.

---

### `icon_card`
An identity card that displays the script's own icon alongside a title and optional subtitle. Use this for persistent state announcements — e.g., emitting one at startup to show the script is running and idle.

The icon is sourced from the script's `icon_file` in its manifest (rendered as SVG on iOS). The `icon` SF Symbol in the payload is the fallback if no SVG data is available.

**Payload**
```json
{
  "title": "string",
  "subtitle": "string?"
}
```

- `title` — Script name or current state label.
- `subtitle` — Brief detail line (e.g., `"Idle"`, `"Last checked 2 min ago"`).

**Responds:** no.

---

## Script Identity

Each block carries metadata about the script that emitted it:

| Field | Source | Purpose |
|---|---|---|
| `scriptID` | `manifest.json` → `id` | Unique identifier; groups blocks into sections |
| `scriptName` | `manifest.json` → `name` | Human-readable section header label |
| `scriptIcon` | `manifest.json` → `icon` | SF Symbol name; fallback icon |
| `scriptIconSVG` | `manifest.json` → `icon_file` (SVG content) | Full SVG markup rendered on iOS |

iOS displays one section per script, with the script's icon and name as the section header. The section header renders the SVG icon if available, then the SF Symbol, then `terminal.fill`.

---

## Block Lifecycle

1. Script calls `emit_block` with a `blockId`, `blockType`, `payload`, and optional `ttl`.
2. AskMac writes the record to CloudKit immediately; the iOS app polls every 5 seconds.
3. To dismiss a block, the script calls `clear_block` with the same `blockId`.
4. If `ttl` is set, AskMac stores an `expiresAt` timestamp; iOS filters expired blocks.
5. When the user responds (confirmation, prompt, chat_prompt), iOS writes an `RKResponse` record to CloudKit; AskMac polls for responses and delivers them to the script as a `notifications/message` with `data.type == "user_response"`.

---

## Block ID Conventions

- Use a stable UUID or a meaningful string per block purpose (e.g., `"brew-monitor-updates"`).
- Re-emitting a block with the same `blockId` overwrites it (CloudKit `savePolicy: .allKeys`).
- Clearing then re-emitting resets the block's `createdAt` and TTL.

---

## Payload Authoring Notes

- All text fields support emoji. Emoji are transmitted as raw Unicode (surrogate pairs are decoded server-side).
- `body` in `confirmation` is rendered in monospaced type — good for structured output like package lists or diff summaries.
- `context` in `chat_prompt` should be the complete last message, not a delta.
- `icon_card` blocks are best emitted once at startup with TTL = a long duration (e.g., 24 h), then cleared when the script terminates.
