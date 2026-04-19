# AskMac Simplification

## Goal
Remove debug infrastructure from release builds, split monolithic files into focused modules, standardize logging, and delete dead code — producing a cleaner, more maintainable shipped app.

---

## Requirements

### 1. Debug-only builds
- `LocalHTTPServer` compiles and runs only in debug builds (`#if DEBUG`). It must not be included in release/distribution builds.
- `MacUITestingSupport` compiles and runs only in debug builds. It must not be included in release/distribution builds.

### 2. SettingsView decomposition
- Settings UI is split into focused, navigable files. Each major section lives in its own file:
  - Machine configuration
  - Script list (enable/disable/install/delete)
  - Script detail (manifest, tools, dependencies, config, icon)
  - Block builder (testing blocks)
- History view remains in `HistoryView.swift` (already exists); settings embeds it by reference only.
- SVG and color helpers move to a shared helpers file.

### 3. BlockPreviewViews decomposition
- Each block type preview is in its own file (e.g. `ConfirmationBlockView.swift`, `AlertBlockView.swift`).
- Shared helpers (hex color parsing, markdown rendering, status color mapping) move to `BlockPreviewHelpers.swift`.
- A single dispatch file routes block type to the correct preview view.

### 4. Structured logging
- All `print()` calls in services are replaced with `OSLog` loggers (`Logger(subsystem:category:)`).
- Debug-only log messages use `logger.debug()`; errors use `logger.error()`.
- No `print()` calls remain in production service code.

### 5. ScriptManager decomposition
- Block state management (tracking `activeBlocks` per script, syncing to CloudKit, seeding HTTP server) is extracted into a dedicated `BlockStateManager`.
- `ScriptManager` delegates block state reads/writes to `BlockStateManager`.

### 6. Remove deprecated CloudKit cleanup
- `purgeOldRecords()` and all constants for `AskEvent`, `AskSession`, `AskResponse` record types are deleted from `CloudKitService` and `CloudKitSchema`.
- This requires confirming old records have been purged in production before deletion.

---

## Out of scope
- Changes to CloudKit data model or record types in active use.
- Changes to script protocol or MCP tool dispatch.
- UI design changes.

---

## Changelog
| Date | Change |
|------|--------|
| 2026-04-18 | Initial spec |
| 2026-04-18 | Implemented all 6 items |
