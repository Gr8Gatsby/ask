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

## Changelog

| Date | Change |
|---|---|
| 2026-04-12 | Initial spec — full parity iOS web dev UI with MockAskMac, Vite+React+TS+Tailwind |
