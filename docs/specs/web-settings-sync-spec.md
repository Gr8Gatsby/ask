# Functional Spec: Web Settings Sync

**Status:** Approved
**Date:** April 27, 2026

---

## Overview

The web app's settings screen is out of sync with the iOS app. Two user-facing settings present on iOS are missing from the web: per-machine hide/show and a developer toggle to show debug info on blocks. Additionally, the machine filter (`selectedMachineID`) is stored in settings but never applied to the home screen block list.

---

## Goals

- Web settings match iOS settings for all user-visible toggles.
- Machine filtering (both hide/show per-machine and single-machine filter) is applied to the home screen block list.
- Debug info overlay on block cards is controllable via the Developer settings toggle.

---

## Requirements

### 1. Show Debug Info on Cards

- The Developer section of Settings includes a toggle "Show Debug Info on Cards".
- When enabled, each block card displays a debug bar showing: block ID (truncated), block type, creation timestamp, and machine ID (truncated).
- The setting persists across sessions.
- Default is off.

### 2. Hide/Show Machines

- Each machine row in the Machines settings section has a hide/show action.
- Hidden machines are excluded from the home screen block list.
- A hidden machine shows a visual indicator (e.g., eye-slash icon) on its settings row.
- The set of hidden machine IDs persists across sessions.
- Hiding is non-destructive — the machine still appears in Settings.

### 3. Machine Filter Applied to Home Screen

- The existing single-machine filter (`selectedMachineID`) is applied to the home screen block list.
- If both a machine filter and hidden machines are set, both are respected.

---

## Out of Scope

- Task history management (requires persistent task storage layer).
- Queued actions review (requires offline queue implementation).
- Dynamic CloudKit/iCloud status fields (not applicable to web).

---

## Changelog

| Date | Change |
|------|--------|
| 2026-04-27 | Initial spec, approved |
| 2026-04-27 | Implemented: showBlockDebugInfo toggle, hiddenMachineIDs, selectedMachineID home screen filter |
