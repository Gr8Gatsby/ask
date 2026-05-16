---
title: Sessions View — Unified Local + Remote Session List
status: draft
---

## Goal

Give the user a single place inside AskMac to see every active Ask session,
whether it is running on this Mac or on another Mac signed in to the same
iCloud account. Today, session state is split between local on-disk
registries and remote CloudKit task records, and there is no UI that
presents either as a coherent list.

## Definitions

- **Session** — a logical agent run (Claude, Codex, or any future script
  that registers one). Identified by a stable session id supplied by the
  originating daemon.
- **Active session** — a session whose most recent activity timestamp is
  within the active-window threshold (see Requirement 4) AND whose
  daemon-reported state indicates it is still alive (not stopped, not
  errored-terminal).
- **Local session** — a session whose originating machine is the Mac
  AskMac is running on.
- **Remote session** — a session originating on a different Mac visible
  through the shared iCloud account.

## Requirements

### 1. Sessions surface

There must be a dedicated Sessions surface in AskMac, reachable as a
top-level sidebar item alongside the existing top-level views. It is
distinct from the Diagnostics view and the existing block / message
surfaces.

### 2. Active-only listing

The view lists active sessions only. Stopped, terminated, or stale
sessions are excluded from the default list. A future iteration may add
history; it is out of scope here.

### 3. Unified local + remote merge

The list merges:

- sessions discovered from local Ask daemon registries on this machine,
  and
- sessions published to CloudKit by Ask daemons on other machines.

When the same logical session appears in both sources (e.g. this Mac's
own sessions are also published to CloudKit), the view must show it
exactly once. The local source is authoritative for fields that exist in
both; remote-only fields come from CloudKit.

### 4. Active-window threshold

A session is considered active when its last-activity timestamp is no
older than ten minutes. Sessions whose last-activity falls outside this
window are excluded from the list. A session that crosses back inside
the window because of new activity must re-appear without manual
refresh. The threshold is not user-configurable in this first iteration.

### 5. Per-row fields

Each row in the list displays, at minimum:

1. **Machine** — a human-readable name for the originating Mac, plus a
   visual indicator distinguishing "this Mac" from other machines.
2. **Script identity** — script id, script display name, and the script
   manifest version that produced the session.
3. **Timestamps** — when the session started and when it was last
   active. Last-active is shown as a relative time ("2 min ago") and
   updates as time passes without requiring a manual refresh.
4. **Current activity** — the latest message or current block preview
   from the session, truncated to fit one row.
5. **Health badge** — one of: healthy, warning, errored, stalled.
   "Stalled" applies when last-activity is older than a warn threshold
   but still inside the active window.

### 6. Sorting and grouping

The list is sorted by last-activity descending by default. Sessions are
visually grouped by machine, with this Mac's sessions appearing first.

### 7. Empty and error states

- If there are no active sessions, the view shows an empty state
  explaining what "active" means and how a session enters the list.
- If the remote (CloudKit) source is unavailable (no account, no
  network, permission denied), the view still renders local sessions
  and shows a non-blocking banner explaining that remote sessions are
  unavailable.
- If the local source is unavailable or unreadable, the view still
  renders remote sessions and shows the corresponding banner.

### 8. Freshness

The view refreshes automatically:

- Local sessions reflect on-disk registry changes without requiring the
  user to leave and re-enter the view.
- Remote sessions are re-queried every thirty seconds while the view is
  visible, and polling is paused when the view is not visible. A
  manual refresh control must also be available and must take effect
  immediately regardless of where the next scheduled poll would fall.

### 9. Drill-in (deferred but reserved)

Tapping a row is reserved for a future "Session detail" surface. In this
iteration, the row may be non-interactive or may scroll to the
corresponding existing block / task surface if the session originates on
this Mac. No new drill-in screen is required here.

### 10. Privacy

Remote-session current-activity previews must obey the same redaction /
truncation rules the rest of the app already applies to cross-machine
content. No raw secrets or path-only content beyond what is already
visible in existing surfaces.

## Out of Scope

- Historical sessions (stopped, terminated, archived).
- Cross-machine control actions (stopping a remote session, sending it a
  message). Read-only in this iteration.
- A dedicated session-detail view.
- User-configurable active-window threshold.
- Search and filter beyond the default sort and grouping.
- Reworking the Diagnostics "Sessions" subsection — diagnostics
  warnings stay where they are.

## Open Questions

- Stalled warn threshold — proposed 2 minutes inside the active window.
- Identifying "this Mac" vs others — naming convention for the visual
  indicator (chip text, color, "This Mac" label).

## Change Log

| Date | Change |
|---|---|
| 2026-05-16 | Initial draft. |
| 2026-05-16 | Locked active window at 10 min, surface as top-level sidebar item, remote poll every 30s while visible. |
| 2026-05-16 | Initial implementation landed. Surface materialized as a new `Sessions` tab in `MacScriptsView` (the existing top-level segmented nav); see `docs/design-sessions-view.md` for scope reconciliation. |
