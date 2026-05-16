---
title: Sessions Diagnostics — On-machine evidence for session-discovery and CloudKit issues
status: draft
---

## Goal

Make the AskMac Diagnostics report self-sufficient for debugging two
classes of issue that have already surfaced:

1. The Sessions view shows fewer sessions than the user knows are
   actually running (daemon-registry undercount).
2. The Sessions view shows a CloudKit error banner with no actionable
   detail (today: `CloudKit fetch failed: Did not find record type:
   AskTask`).

After this spec ships, a copy-paste markdown report from the
Diagnostics window must be enough to identify the root cause without
needing terminal access, `log show`, or screenshots.

## Definitions

- **Registered session** — an entry in a daemon's session-registry
  JSON file (`~/.ask/<daemon>-sessions.json`).
- **Live process** — a process owned by the current user whose command
  line matches a known daemon executable (`claude`, `codex`).
- **Live tmux pane** — a tmux pane whose `pane_current_command` matches
  one of the daemon executables.
- **Routed session** — a registered session with non-empty
  `tty` or `tmux_target`.

## Requirements

### 1. Session Health section

The existing Diagnostics "Sessions" subsection is expanded into a
top-level Diagnostics section. For each daemon registry the section
must include:

1. **Registry count and path** — how many sessions are in the registry
   JSON and the absolute path to the file.
2. **Per-session detail rows** — one row per registered session
   showing, at minimum: session id, state, cwd (or `—`), tty (or `—`),
   tmux_target (or `—`), seconds since last-seen, routed-or-not flag.
3. **Live process count** — number of processes belonging to the
   current user whose command name matches the daemon executable.
4. **Live tmux pane count** — number of tmux panes whose current
   command matches the daemon executable. Reported as `n/a` if tmux is
   not available or no panes are running daemons.
5. **Delta line** — a single line summarizing
   `registered=N · live_processes=M · tmux_panes=K · missing=max(0, max(M,K)-N)`.
   When `missing > 0`, the section emits a non-info status (warning).

### 2. CloudKit record-type probe

The existing Diagnostics "CloudKit" section gains a per-record-type
probe table. For every record type AskMac queries, the probe reports
exactly one of:

- `present (N records)` — schema accepts the type, this many records
  returned by a `TRUEPREDICATE` count query.
- `present (empty)` — schema accepts the type, zero records.
- `not deployed` — the query returned a CloudKit error that maps to
  "record type not present in this account's schema".
- `error: <localized description>` — anything else.

The list of record types to probe is exactly the set AskMac itself
queries elsewhere in the codebase; the probe must be a single source
of truth so the report cannot drift from the app's actual usage.

Result count for each type is capped at a small limit (e.g. 10) so the
probe is cheap; the probe is purely a schema-presence check, not a
data dump.

### 3. Sessions tab readout

The Diagnostics report includes a short "Sessions tab" summary that
mirrors what the Sessions tab is currently rendering:

- Banner state (each banner: present or absent, with its current
  message text).
- Number of session rows rendered, broken down by origin (local /
  remote) and by machine.

This requirement may be satisfied by reusing the same in-memory state
the Sessions tab consumes, so the two cannot disagree.

### 4. CloudKit banner suppression for missing record type

Independent of the Diagnostics work: when the Sessions tab's remote
fetch encounters a "record type not deployed" error for `AskTask`, the
remote source is treated as empty rather than as a failure. The
"Remote sessions unavailable" banner does not show in that case. Other
CloudKit errors continue to surface the banner as before.

Rationale: an account that has never written an `AskTask` record will
never have the type in its Production schema, and that is the expected
state for a brand-new install — not an error condition the user
should see.

### 5. Privacy

- Session ids, cwd, tty, and tmux_target may be included in the
  report. Block payloads, message contents, and last-message previews
  must not be included in the diagnostic section (these already appear
  in the Sessions tab UI but are not appropriate for paste-sharing).
- The CloudKit probe must not return record-data contents — only type
  presence and counts.

## Out of Scope

- Any change to claude-3 / codex-3 daemons (under-discovery
  investigation is a separate spec).
- Cross-machine remote diagnostics (probing another Mac via CloudKit).
- A scheduled / always-on diagnostic that auto-alerts. Diagnostics
  remain on-demand.
- UI surface beyond the existing Diagnostics window.

## Change Log

| Date | Change |
|---|---|
| 2026-05-16 | Initial draft. |
