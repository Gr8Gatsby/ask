---
title: Script Health Panel — Per-Script Diagnostics Row
status: draft
---

## Goal

Make it obvious, at a glance, whether each Ask script on this Mac is in
a healthy state — and when it is not, give the user enough information
in one place to start debugging without grepping logs. The recurring
pain point is stale or mis-deployed vault contents (e.g. the v1.3.2
upgrade incident); a per-script health row collapses the relevant
signals into one diagnostic view.

## Definitions

- **Script** — a directory inside the vault that contains a
  `manifest.json` and one or more executables that an Ask daemon
  invokes. Identified by its script id.
- **Vault** — the on-disk location AskMac reads scripts from. There is
  a development vault and a production vault; only one is active per
  AskMac launch.
- **Bundled script** — the script copy shipped inside the AskMac app
  bundle, used as the reference version for installation and upgrade.
- **Deployed script** — the copy of a script currently present in the
  active vault.
- **Healthy** — the script can be discovered, has a valid manifest,
  matches expected version vs. its bundled counterpart, and has run
  recently without a terminal-state error.

## Requirements

### 1. Location

The Script Health Panel is a section inside the existing Diagnostics
view. It replaces or supersedes the current per-script row content;
the panel does not introduce a new top-level surface.

### 2. One row per script

For every script known to AskMac (intersection of bundled scripts and
deployed scripts in the active vault), the panel renders exactly one
row. Scripts present in the vault but not bundled, and scripts bundled
but not deployed, must both appear — flagged accordingly (see
Requirement 5).

### 3. Per-row fields

Each row displays, at minimum:

1. **Script identity** — script id and human-readable title.
2. **Vault path** — the absolute path to the deployed script directory
   (or an indication that it is missing from the vault).
3. **Manifest version** — the version string from the deployed
   `manifest.json`, alongside the bundled version when they differ.
4. **File modification time** — when the deployed script directory
   (or its manifest) was last modified on disk.
5. **Last run** — when the script was last invoked by its owning
   daemon, expressed both absolutely and as a relative time.
6. **Last error** — a one-line summary of the most recent error
   produced by the script, with an absolute timestamp. Empty if no
   error has been recorded.
7. **Enabled / disabled state** — whether the script is currently
   enabled in AskMac.
8. **Health badge** — one of: healthy, warning, errored, missing,
   version-mismatch. See Requirement 5.

### 4. Source of truth

The panel must surface, for each field, information drawn from
authoritative on-disk sources without requiring CloudKit or network
access. Specifically:

- Vault path, file mtime, and deployed manifest version come from the
  active vault directory.
- Bundled manifest version comes from the app bundle's bundled scripts.
- Last-run, last-error, and enabled state come from the daemon-owned
  registries / log artifacts already present on disk.

CloudKit-published script health is out of scope here (see Out of
Scope).

### 5. Health badge semantics

- **healthy** — deployed, manifest valid, deployed version matches
  bundled version, last run within the recent-run window, no recorded
  errors since last successful run.
- **warning** — deployed and otherwise healthy, but at least one of:
  last run is older than the recent-run window, or a non-terminal
  warning was logged.
- **errored** — last recorded outcome for the script is an error, or
  manifest cannot be parsed.
- **missing** — bundled but not deployed, or deployed but missing
  required executables.
- **version-mismatch** — deployed manifest version differs from
  bundled manifest version. Takes precedence over "healthy" but not
  over "errored".

### 6. Quick actions per row

Each row exposes the following actions, scoped to a single script:

1. **Reveal in Finder** — open the deployed script directory.
2. **Copy diagnostic snippet** — copy a single text block containing
   the row's fields, suitable for pasting into an issue or chat.
3. **View last error** — if a last error is present, expand or open a
   full view of the captured error text.

A "redeploy this script from the bundle" action is *not* required in
this iteration (see Out of Scope) but may be added later.

### 7. Empty and error states

- If no scripts are bundled and none are deployed (highly unusual),
  the panel shows a clear empty state explaining what a script is and
  where to look.
- If the vault path itself cannot be read (permissions, missing
  directory), the panel shows a single error row identifying the vault
  and the underlying reason, and does not falsely show every script as
  missing.

### 8. Freshness

The panel re-reads its underlying sources whenever the Diagnostics
view is opened or when the user triggers an explicit refresh.
Continuous live updating is not required.

### 9. Privacy

The "Copy diagnostic snippet" action must not include user message
content, prompts, or block payloads. Only structural fields (paths,
versions, timestamps, error summary) are included.

## Out of Scope

- Cross-machine script health (CloudKit-published `AskScript` records
  from other Macs). Local-only in this iteration.
- A "redeploy from bundle" or "force reinstall" action.
- Editing scripts in place from this panel.
- Surface for warnings about scripts that exist outside the active
  vault (e.g. orphaned dev-vault copies when prod vault is active);
  may be revisited.
- Reworking the unrelated Diagnostics sections (Sessions warnings,
  hooks, CLIs, sparkle, etc.).

## Open Questions

- Recent-run window — proposed 24 hours; anything older flips the
  badge from healthy to warning.
- Last-error capture — confirm where the daemon writes the
  most-recent-error record today (registry JSON vs. log tail) so the
  field can be populated without parsing free-form logs.
- Whether to show the dev vault and prod vault side-by-side when both
  exist on the machine, or only the active vault.

## Change Log

| Date | Change |
|---|---|
| 2026-05-16 | Initial draft. |
