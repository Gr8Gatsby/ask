# Script Uninstall & Startup Resilience — Functional Specification

## Overview

Two related improvements to script lifecycle management:

1. **Script Uninstall** — users can fully remove an installed script from the vault.
2. **Startup Crash Resilience** — a script that crashes immediately on launch does not crash the app; the error is surfaced gracefully in the UI.

---

## 1. Script Uninstall

### What uninstall does

When the user uninstalls a script:

- The running connection (tile, feed, or system) is stopped immediately.
- All CloudKit blocks emitted by that script are deleted.
- The feed scheduler entry for the script is cancelled (if any).
- The script's entry is removed from the disabled-scripts list in settings (if present).
- The crash/restart state for the script is cleared.
- The script folder is moved to the system Trash (not permanently deleted).
- The script is removed from the sidebar.

### What uninstall does NOT do

- Does not touch scripts in the app bundle (bundled scripts cannot be uninstalled, only disabled).
- Does not affect other scripts.

### Trigger

- A **"Move to Trash"** button in the script's detail view in Settings, grouped near the existing enable/disable toggle.
- Destructive action — requires a confirmation alert before proceeding.

### States

| State | Behavior |
|---|---|
| Running | Stop first, then remove. |
| Crashed / stopped | Remove directly. |
| Bundled script | Button not shown. |

### Confirmation

Single confirmation sheet:
- Title: "Remove [Script Name]?"
- Body: "This will stop the script, clear its blocks from your iPhone, and move its files to the Trash."
- Buttons: "Remove" (destructive) / "Cancel"

---

## 2. Startup Crash Resilience

### Problem

A script that exits immediately on launch (e.g., missing dependency, broken entry point) can trigger rapid crash/restart cycles before the circuit breaker engages. Under high concurrency at startup this can exhaust thread or stack resources and crash the app.

### Requirements

- A script that crashes within 2 seconds of launch is considered an **immediate crash**.
- On an immediate crash the restart delay starts at 5 seconds (not 1 second) and doubles with each subsequent immediate crash.
- If a script has crashed immediately 3 or more consecutive times without a successful run, it is placed in a **degraded** state: it is not restarted again until the user explicitly retries.
- In degraded state the sidebar shows status "Needs attention" and the script detail explains what happened.
- The circuit breaker threshold and window remain unchanged (5 crashes / 5 minutes) for non-immediate crashes.
- No app crash. All process launch failures are caught with do/try/catch; errors are logged and reflected in the script's status.

---

## Changelog

- 2026-04-07 — Initial draft
- 2026-04-07 — Implemented Script Uninstall: `uninstallScript(id:)` in ScriptManager, `isBundled` property on ManagedScript, and "Move to Trash" button with confirmation alert in ScriptDetailView (card front, bottom-leading overlay, hidden for bundled scripts)
