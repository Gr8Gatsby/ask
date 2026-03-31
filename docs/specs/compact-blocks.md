# Functional Spec: Compact Block Layout

## Overview

Reduce the visual density of iOS block views — less padding, tighter spacing, smaller font sizes, and smaller buttons — so more content fits on screen without scrolling.

---

## Design Tokens

A shared set of constants replaces the ad-hoc values currently scattered across block views.

| Token | Current | Compact |
|---|---|---|
| Block vertical padding | 4 pt | 2 pt |
| VStack inner spacing | 8–10 pt | 4–6 pt |
| Button vertical padding | 8 pt | 4 pt |
| Button min height | 36 pt | 28 pt |
| List row vertical padding | 11 pt | 6 pt |
| List row horizontal padding | 12 pt | 10 pt |
| Corner radius (buttons) | 8 pt | 6 pt |
| Corner radius (lists) | 10 pt | 8 pt |

---

## Typography

| Usage | Current | Compact |
|---|---|---|
| Block title / label | `.subheadline` semibold | `.footnote` semibold |
| Block body / detail | `.caption` | `.caption2` |
| Button label | `.body` semibold | `.subheadline` semibold |
| List item label | `.body` | `.subheadline` |
| List item subtitle | `.caption` | `.caption2` |
| Monospaced body | caption1 size | caption2 size |

---

## Per-Block Changes

### Confirmation
- Title: `.footnote` semibold (was `.subheadline` semibold)
- Body: `.caption2` monospaced (was `caption1` monospaced)
- Inline buttons: min height 28 pt, vertical padding 4 pt
- Option list rows: vertical padding 6 pt (was 11 pt), horizontal 10 pt (was 12 pt)
- Radio circle: 16 pt diameter (was 20 pt), filled circle 9 pt (was 11 pt)

### Alert
- Icon: `.callout` (was `.title3`)
- Title: `.footnote` medium (was `.subheadline` medium)
- Body: `.caption2` (was `.caption`)
- HStack spacing: 8 pt (was 12 pt)

### Status
- Label: `.footnote` (was `.subheadline`)
- Detail: `.caption2` (was `.caption`)
- Dot: 6 pt (was 8 pt)
- HStack spacing: 8 pt (was 10 pt)

### Prompt
- Title: `.footnote` semibold
- Input field: `.subheadline`
- Submit button: min height 28 pt, vertical padding 4 pt

### Chat Prompt
- Context bubble: `.caption` (was `.body`)
- Input field: `.subheadline`
- Submit button: min height 28 pt, vertical padding 4 pt

### Info Card
- Title: `.footnote` semibold
- Key/value text: `.caption` (was `.subheadline` / `.body`)

### Icon Card
- Title: `.subheadline` semibold (was `.title3` or similar)
- Subtitle: `.caption` (was `.subheadline`)
- Icon size: 32 pt (was 48 pt)

### Countdown
- Label: `.footnote`
- Time remaining: `.subheadline` semibold

### Picker
- Title: `.footnote` semibold
- Picker control: `.subheadline`
- Submit button: min height 28 pt, vertical padding 4 pt

### List
- Title: `.footnote` semibold
- Item label: `.subheadline` (was `.body`)
- Item subtitle: `.caption2` (was `.caption`)
- Row vertical padding: 6 pt (was 11 pt)
- Action buttons: min height 28 pt, vertical padding 4 pt

### Detail
- Title: `.footnote` semibold
- Body: `.caption` (was `.body`)
- Action buttons: min height 28 pt, vertical padding 4 pt

---

## Implementation Approach

Define a private `BlockStyle` enum or constant namespace in `BlockViews.swift` with all token values. Each block view reads from this namespace rather than using inline literals. This makes future adjustments a single-location change.

---

## Out of Scope

- Mac app (`BlockPreviewViews.swift`) — Mac has different density needs; no changes.
- Home screen tile (`HomeView.swift`) — tile has its own layout; no changes.
- Debug info overlay — unchanged.

---

## Changelog

| Date | Change |
|---|---|
| 2026-03-31 | Initial spec |
| 2026-03-31 | Implemented: BlockStyle tokens + all block views updated |
