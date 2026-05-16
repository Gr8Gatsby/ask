# Sessions View — Dev Design

Implementation plan for `docs/specs/sessions-view.md`.

## Scope reconciliation: "top-level sidebar item"

AskMac's main `MacScriptsView` window today exposes top-level navigation as
a 3-segment `Picker` (scripts / feed / machine), not a `NavigationSplitView`
sidebar. The functional spec's "top-level sidebar item" is interpreted as
"new top-level tab in `MacScriptsView`" — same prominence, same code
pattern as feed/machine, smallest delta.

## New files

- `AskMac/Sources/AskMac/Models/UnifiedSession.swift` — value type, merge
  helpers, health classifier.
- `AskMac/Sources/AskMac/Services/SessionsService.swift` — `@Observable`
  service; loads local registry JSON, polls CloudKit, exposes
  `[UnifiedSession]`.
- `AskMac/Sources/AskMac/Views/SessionsView.swift` — list view + viewmodel.

## Modified files

- `AskMac/Sources/AskMac/Views/SettingsView.swift` — add `.sessions` to
  `MacTab` enum and a new branch in the `switch activeTab` body.
- `AskMac/Sources/AskMac/AskMacApp.swift` — construct `SessionsService`
  alongside other services, inject into `MacScriptsView` via `.environment`.
- `AskMac/AskMac.xcodeproj/project.pbxproj` — register the three new
  source files (the project already has a pending diff adding diagnostics
  files; new entries piggyback).

## Model

```swift
struct UnifiedSession: Identifiable, Hashable {
    enum Origin { case local, remote }
    enum Health { case healthy, warning, errored, stalled }

    let sessionID: String           // dedup key
    let origin: Origin
    let machineID: String
    let machineName: String         // "This Mac" for origin == .local
    let scriptID: String            // "claude-3", "codex-3", ...
    let scriptName: String
    let scriptVersion: String?      // resolved from ScriptManager when local
    let title: String?              // CloudKit AskTask.title or last_prompt
    let lastMessage: String?
    let currentPreview: String?
    let currentTool: String?
    let state: String?              // "idle", "running_tool", ...
    let startedAt: Date?            // best-effort; nil if unknown
    let lastActivityAt: Date
    let health: Health
}
```

## Identity & dedup

- Local registries store `session_id` and `task_id` (today they are equal
  for claude-3/codex-3). The merge service uses `session_id` as the dedup
  key. CloudKit `AskTaskRecord.taskID` maps to the same id when the
  daemon publishes; in practice this is what dedups local vs CloudKit
  versions of the same session.
- When both sources have the same `sessionID`, local wins for fields
  that exist in both (state, currentPreview, currentTool, lastMessage).
  CloudKit supplies `title` and any remote-only metadata.

## Active window

A session is active iff `now - lastActivityAt <= 10 minutes` AND `state`
is not one of the terminal states (`stopped`, `errored_terminal`). The
terminal-state set lives in `UnifiedSession.Health.classify`.

## Health classification

- `errored`  — `state == "errored"` or `pending_permission` is non-nil
  with explicit failure metadata (not just "awaiting input").
- `stalled`  — last activity older than 2 minutes but inside the 10-min
  active window.
- `warning`  — `pending_permission` non-nil (awaiting user) or
  `is_transient` true with `state == "idle"` (no real session attached).
- `healthy`  — otherwise.

## SessionsService

`@Observable` `@MainActor` class with three published collections:

```swift
private(set) var sessions: [UnifiedSession] = []
private(set) var remoteUnavailable: String? = nil
private(set) var localUnavailable: String? = nil
```

Lifecycle methods:

- `start()` — kicks off local reload and remote fetch.
- `stop()` — invalidates the timer.
- `refreshNow()` — manual refresh.
- `setVisible(_:Bool)` — view-visibility hook; pauses/resumes the
  remote poll timer.

Internals:

- Local reload: on `start()` and on a 5-second on-disk poll (cheap;
  the JSON files are tiny). Watching via `DispatchSource` is a future
  optimization.
- Remote poll: `Timer.scheduledTimer` at 30s while visible. Each tick
  calls `CloudKitService.fetchTasks(machineID: …)` for *every known
  remote machine*. Discovery of remote machines: query
  `CKSchema.RecordType.machine` records and cache.
- Merge: build a `[sessionID: UnifiedSession]` from local first, then
  fold remote in, applying the "local wins" rule.
- Sort: `lastActivityAt` desc.

## Machine discovery

`CloudKitService.fetchAllMachines()` does not currently exist. Either:

(a) Reuse `MachineRecord` query infra (a small new method in
`CloudKitService`), or

(b) Derive remote machine list from the union of `machineID` seen in
returned `AskTaskRecord`s.

Plan: (a). Add `fetchAllMachines() async throws -> [MachineRecord]` to
`CloudKitService` so machine name lookup works for the row header.
Fall back to the machineID string if name is missing.

## View

`SessionsView` follows the existing `MacFeedView` look:

- `List` of `UnifiedSession` grouped by machine, this Mac first.
- Each row: badge (origin chip "This Mac" or machine name), bold script
  name + dim version, dim relative time using `TimelineView(.periodic)`
  at 30-second cadence, single-line current activity preview, health
  dot (color-coded).
- Banner above the list when `remoteUnavailable != nil` or
  `localUnavailable != nil`.
- Manual refresh button in the inset toolbar.
- `.onAppear` calls `service.setVisible(true)`; `.onDisappear` →
  `setVisible(false)`. (For tab switches we use `.task(id: activeTab)`
  in `MacScriptsView` to drive visibility, since `.onDisappear` doesn't
  fire when the inner view is swapped via a `Group`+`switch`.)

## Testing

The existing test target (`AskMacTests`) depends only on `AskMacCore`,
not the `AskMac` executable target, so `UnifiedSession` and friends are
not directly reachable from unit tests in this iteration. Verification
relies on: a clean `swift build`, the existing 85-test suite still
passing, and manual smoke in the running app. Unit tests for
`merge` / `Health.classify` are a follow-up — they require either
moving these types into `AskMacCore` or restructuring the test target.

## Out of scope (deferred)

- CloudKit subscription-based push updates.
- Drill-in detail view.
- Stopped/history sessions.
- Script-health panel — covered by `docs/specs/script-health-panel.md`.

## Change Log

| Date | Change |
|---|---|
| 2026-05-16 | Initial design doc. |
