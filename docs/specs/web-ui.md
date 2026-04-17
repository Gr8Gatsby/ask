# Ask Web UI — Functional Spec

A browser-based dev tool that renders Ask blocks with live reload. Mirrors the iOS app's screens and block types exactly so UI changes can be iterated without rebuilding the native app.

**Dev only. Not shipped to users.**

---

## Architecture

```
npm run dev
  ├── MockAskMac  (ask/web/mock/server.ts, port 4242)
  │     ├── GET  /blocks           — current block state as JSON
  │     ├── GET  /events           — SSE stream (block_added / block_updated / block_cleared)
  │     ├── POST /respond/:blockID — submit response; clears the block
  │     ├── GET  /machines         — machine list
  │     ├── GET  /tasks            — task list
  │     └── GET  /tasks/:id/messages
  └── Vite dev server  (port 5173)
        — proxies /api/* → localhost:4242
        — hot-reloads React components on save
```

The web app calls `/api/*`; Vite proxies to MockAskMac. When the real AskMac HTTP server is built, switch the proxy target and no app code changes.

---

## Screens

Mirrors iOS navigation hierarchy:

| Screen | Route | iOS equivalent |
|---|---|---|
| Home | `/home` | `HomeView` — script tile grid + alert chips |
| Script Detail | `/script/:scriptID` | `ScriptDetailView` — block list |
| Session Chat | `/script/:scriptID/session/:sessionID` | `SessionChatView` |
| Task Feed | `/tasks` | `TaskFeedView` |
| Task Thread | `/tasks/:taskID` | `TaskThreadView` |
| Component Catalog | `/catalog` | dev only — not in iOS |

Navigation: tab bar (Home / Feed / Catalog) with push stack within each tab implemented via React Router.

---

## Component System

```
ask/web/src/
  screens/                  # Top-level screen components
  components/
    blocks/                 # One file per block type + BlockRenderer dispatcher
    shared/                 # Markdown, UrgencyBadge, ScriptIcon
    layout/                 # AppShell, TabBar
  lib/
    types.ts                # Block payload types (mirrors RemoteKitModels.swift)
    api.ts                  # HTTP client + SSE subscription
    useBlocks.ts            # React hook for live block state
  catalog/
    fixtures.ts             # Fixture payloads for every block type
```

---

## Block Components

All implemented block types:

| Block | Interactive |
|---|---|
| `confirmation` | Buttons → POST /respond |
| `alert` | Display only |
| `status` | Display only |
| `prompt` | Text input + submit |
| `chat_prompt` | Markdown context + reply input |
| `claude_message` | Markdown display |
| `agent_session` | Reply input + working indicator |
| `start_session` | Repo picker sheet |
| `info_card` | Display only |
| `icon_card` | Display only |
| `tile` | Home screen tile only (not in block list) |
| `countdown` | Live countdown, updates every 30s |
| `picker` | Dropdown + submit |
| `list` | Item rows + action buttons |
| `detail` | Long-form text + action buttons |
| `feed_item` | Timeline entry |
| `quick_reply` | Compact buttons + optional free text |

Planned/unimplemented types render a labeled placeholder card.

---

## MockAskMac

Standalone Node.js TypeScript server (`mock/server.ts`). Serves fixture data for all block types. Simulates SSE events (e.g. clears a block when a response is submitted).

Run via `tsx watch mock/server.ts` — hot-reloads when fixture data changes.

---

## Component Catalog

Route `/catalog`. Renders every block type side-by-side using fixture payloads from `catalog/fixtures.ts`. Primary surface for developing a block component in isolation — no live script needed.

---

## UI Inspector Panel

A collapsible side panel rendered alongside the phone frame (toggle in control bar). Shows current screen context and all active blocks for that screen.

### Panel contents

- Screen name and pathname
- Route params (scriptID, sessionID, etc.)
- Blocks grouped by script, each row showing block type, short ID, and flags (RESPONSE, INBOX)
- Block count badge in header

### Block filtering per screen

Each route filters the full block list to match what that screen actually renders:

| Screen | Filter |
|---|---|
| Home | `scriptType === 'tile'` |
| Script Detail | `scriptID === routeParam` |
| Session Chat | `agent_session` blocks with matching `session_id` |
| Task Feed | all `agent_session` blocks |
| Task Thread / Settings | empty (no blocks drive these screens) |

### Hover highlights

Mousing over a block row in the inspector adds `inspector-highlighted` class to all matching `[data-block-id]` and `[data-script-id]` elements in the phone DOM. Hover out removes it. Styled as blue inset ring (`box-shadow: inset 0 0 0 2px rgba(0,122,255,0.85)`).

### Block detection requirements

Every rendered element in the phone frame that corresponds to a block must carry:

- `data-block-id="{blockID}"` — block identity
- `data-block-type="{blockType}"` — for color-coding
- OR `data-script-id="{scriptID}"` — for script-level groupings (tiles, action queue cards)

Screens that don't render individual block elements (e.g. Session Chat, which renders the session as the whole screen) attach `data-block-id` to the outermost screen container.

---

## Redlines Overlay

An SVG-based design inspection overlay rendered outside the phone frame so annotations are never clipped. Activated by the "Redlines" toggle in the control bar (alongside the Inspector toggle).

### Modes

**All-blocks mode** (Redlines on, no block selected):

Queries both `[data-block-id]` and `[data-script-id]` elements inside the phone frame. For each, draws:
- Outline rectangle: 1.5px stroke, block type color (from the same color map as the inspector panel)
- Type label pill positioned 4px inside the top-left corner of the bounding box:
  - Text: `data-block-type` value, 10px, weight 600, `ui-monospace, monospace`, block type color
  - Background: block type color at 15% opacity
  - Border: 1px solid block type color at 60% opacity
  - Border radius: 4px, padding: 1px 4px

Clicking an outline rectangle focuses that block (sets `focusedBlockID` in context).

**Selected-block mode** (Redlines on, a block is focused via the inspector panel or by clicking an outline):

Non-focused block outlines drop to `stroke-opacity: 0.15`. Focused block draws:

1. **Bounding box**: 2px stroke, block type color.

2. **Padding fills** — one `<rect>` per non-zero padding edge, fill `rgba(255,149,0,0.25)`, no stroke. Padding values come from `getComputedStyle(el)` (logical px); multiply by `scale` to get drawing px.
   - Top: `{ x: svgX, y: svgY, w: svgW, h: paddingTop × scale }`
   - Bottom: `{ x: svgX, y: svgY + svgH − paddingBottom × scale, w: svgW, h: paddingBottom × scale }`
   - Left: `{ x: svgX, y: svgY + paddingTop × scale, w: paddingLeft × scale, h: svgH − (paddingTop + paddingBottom) × scale }`
   - Right: `{ x: svgX + svgW − paddingRight × scale, y: svgY + paddingTop × scale, w: paddingRight × scale, h: svgH − (paddingTop + paddingBottom) × scale }`

3. **Gap fill** — drawn between the focused element and its next element sibling, fill `rgba(0,122,255,0.20)`, no stroke. Only drawn when all of the following are true:
   - `getComputedStyle(parentEl).display` is `flex` or `grid`
   - Parent has a non-zero row gap: `rowGap = parseFloat(getComputedStyle(parentEl).gap.split(' ')[0])`
   - `el.nextElementSibling` exists
   - Rect: `{ x: svgX, y: svgY + svgH, w: svgW, h: rowGap × scale }`

4. **Width dimension line** — always drawn above the element:
   - Horizontal line from `(svgX − 8, svgY − 20)` to `(svgX + svgW + 8, svgY − 20)`
   - Tick marks: 8px vertical lines at each endpoint
   - Center label: `{Math.round(svgW / scale)}px`

5. **Height dimension line** — drawn on the annotation side (see Annotation Placement):
   - Annotation left: vertical line at `x = svgX − 20` from `(svgX − 20, svgY − 8)` to `(svgX − 20, svgY + svgH + 8)`
   - Annotation right: vertical line at `x = svgX + svgW + 20` from `(svgX + svgW + 20, svgY − 8)` to `(svgX + svgW + 20, svgY + svgH + 8)`
   - Tick marks: 8px horizontal lines at each endpoint
   - Side label: `{Math.round(svgH / scale)}px`

6. **Measurement labels** — stacked on the annotation side, starting 8px beyond the height dimension line, 4px vertical gap between each. One dark pill per item, in order:
   - Non-zero padding edges: `padding-top: Xpx`, `padding-right: Xpx`, `padding-bottom: Xpx`, `padding-left: Xpx`
   - Gap (if present): `gap: Xpx`

   Label pill style: background `rgba(25,25,25,0.88)`, text white 10px weight 500 `ui-monospace`, border-radius 4px, padding 2px 5px.

### Annotation placement

Controlled by `inspectorOpen` from `RedlinesContext`:
- Inspector open → annotation side = **left** (dimension line at `svgX − 20`, labels stack leftward from there)
- Inspector closed → annotation side = **right** (dimension line at `svgX + svgW + 20`, labels stack rightward)

Width dimension lines always draw above the element regardless of annotation side.

### Click-to-copy

Every measurement label has `pointer-events: auto`. On click, copies to clipboard formatted as a CSS property string:
- `padding-top: 12px`
- `width: 320px`
- `gap: 8px`

On copy, the label background flashes to `rgba(52,199,89,0.85)` (green) for 400ms then returns to normal. No animation library needed — toggle a local boolean in component state and clear it with `setTimeout`.

The inspector panel shows a "Copy all" button when `focusedBlockID` is set. It copies a JSON object of all measurements: `{ width, height, paddingTop, paddingRight, paddingBottom, paddingLeft, gap }`.

### Architecture

**`RedlinesContext`** (`src/lib/RedlinesContext.tsx`):
- `showRedlines: boolean` + `setShowRedlines`
- `focusedBlockID: string | null` + `setFocusedBlockID`
- `inspectorOpen: boolean` + `setInspectorOpen`
- Replaces `showRedlines` prop threading from AppShell and local `focusedBlockID` + `showRedlines` state in UIInspectorPanel. AppShell sets `inspectorOpen` when toggling the inspector panel.

**`RedlinesOverlay`** (`src/components/layout/RedlinesOverlay.tsx`):
- The phone frame div gains a `position: relative` wrapper. The SVG is `position: absolute, top: 0, left: 0`, sized to the phone frame's current viewport dimensions (`phoneEl.getBoundingClientRect().width/height`). The SVG has `overflow: visible` so annotations extend outside.
- `pointer-events: none` on SVG root; `pointer-events: auto` on outline rectangles and measurement labels.
- On each measure pass, reads `phoneEl.getBoundingClientRect()` once and uses it as the origin for all element offset calculations.
- Re-measurement triggers (all call `cancelAnimationFrame(pending); pending = requestAnimationFrame(measure)`):
  - Route change via `useLocation`
  - `ResizeObserver` on the phone frame element
  - `MutationObserver({ childList: true, subtree: true })` on the phone frame element
  - Scroll: `phoneEl.addEventListener('scroll', handler, { capture: true, passive: true })` — capture mode catches scroll from any inner scroll container

**Coordinate system** — all SVG drawing is in viewport pixels:
- `phoneRect = phoneEl.getBoundingClientRect()`
- `scale = phoneRect.width / phoneEl.offsetWidth`
- Per element: `svgX = elRect.left − phoneRect.left`, `svgY = elRect.top − phoneRect.top`, `svgW = elRect.width`, `svgH = elRect.height`
- Displayed numeric labels divide by scale: `Math.round(svgW / scale)` → logical px
- Padding/gap from `getComputedStyle()` are already logical px; multiply by `scale` for SVG drawing coordinates, use as-is in label text

**Element collection** — runs on every measure pass:
1. `phoneEl.querySelectorAll('[data-block-id], [data-script-id]')`
2. Deduplicate: for each unique blockID (or scriptID), keep only the outermost element — skip any element whose DOM ancestor already has the same attribute value
3. Skip elements where `elRect.width === 0 || elRect.height === 0`
4. Skip elements entirely outside `phoneRect` (`elRect.bottom < phoneRect.top || elRect.top > phoneRect.bottom || elRect.right < phoneRect.left || elRect.left > phoneRect.right`)
5. Clip partially visible elements: clamp `svgX/svgY/svgW/svgH` to stay within `[0, phoneRect.width] × [0, phoneRect.height]`

**Dimension and tick line style**: stroke `rgba(255,45,85,0.85)` (design red), stroke-width 1px, no fill.

### CSS cleanup

When the SVG overlay lands, remove the following from `index.css` (keeping `inspector-highlighted`):
- `.redlines-mode` and all descendant rules
- `.redlines-focused` rules
- `.redlines-target` rules
- `redlines-mode` and `redlines-focused` class additions in AppShell and UIInspectorPanel

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-12 | Initial spec — full parity iOS web dev UI with MockAskMac, Vite+React+TS+Tailwind |
| 2026-04-16 | Add UI Inspector Panel section (block filtering, hover highlights, block detection requirements) |
| 2026-04-16 | Add Redlines Overlay section (SVG overlay, RedlinesContext, coordinate system, click-to-copy) |
| 2026-04-16 | Redlines spec: fill in precise geometry for all SVG elements, coordinate math, label styles, gap detection, copy flash, scroll capture mode |
