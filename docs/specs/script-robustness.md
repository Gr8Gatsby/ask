# Script Management Robustness

Improvements to script lifecycle management, developer experience, and error visibility.

## Requirements

### 1. Vault File Watcher

The Mac app watches the configured vault directory for file system changes. When any file inside the vault changes, the script manager reloads automatically — no manual action needed.

- Watching is active only when the vault path is set and accessible
- A reload triggered by file changes behaves identically to a manual reload
- Scripts that have not changed are not restarted
- Rapid successive changes (e.g., multiple files saved at once) coalesce into a single reload

### 2. Script Log Viewer

Each script's detail view (in Settings) exposes the stderr output captured from the most recent run.

- Shows the last 50 lines of stderr output
- Updates live while the script is running
- Shows a "no output yet" empty state if the script has not emitted any stderr
- Includes the exit code and whether the process exited by signal, when crashed
- The log section is visible for all script types (tile, feed, system)

### 3. Setup Execution Timeouts

The `setup.py --check` and `setup.py --install` phases have enforced time limits:

- `--check` times out after 30 seconds
- `--install` times out after 5 minutes
- On timeout, the phase is treated as a failure with a clear "timed out" message shown in the UI
- The subprocess is terminated (not left orphaned) when the timeout fires

### 4. Setup Re-run on Config Change

When the user saves a config value for a script (secret, string, or boolean), setup checks are re-evaluated automatically.

- Re-evaluation runs asynchronously; the UI does not block
- The setup check results in the UI update when the re-evaluation completes
- If all required checks now pass, the script status transitions out of `needsSetup`
- This applies to all config types (secret, string, boolean)

### 5. Feed Script Execution Timeout

Feed scripts that run longer than a configurable limit are terminated.

- Default timeout is 5 minutes
- Scripts can declare a custom timeout in the manifest: `"timeout_seconds": N`
- When a feed script times out, it is treated as a crash: exit status is recorded, an error block is emitted to iPhone, and the next scheduled run proceeds normally
- Tile and system scripts are not affected

### 6. Circuit Breaker

A script that crashes repeatedly within a short window is automatically disabled.

- Threshold: 5 crashes within 5 minutes triggers the circuit breaker
- When tripped, the script is marked disabled; it does not restart automatically
- An informational block is emitted to iPhone when the circuit breaker trips, describing which script was disabled and why
- The user can re-enable the script from Settings; the crash counter resets on manual re-enable
- The 5/5 thresholds are not user-configurable (hardcoded)

### 7. Malformed JSON Warning Block

When a script emits a line that is not valid JSON-RPC, the error is surfaced rather than silently dropped.

- A warning block is emitted to iPhone with: the script name, the offending output line (truncated to 500 chars), and a prompt to check logs
- Repeated malformed lines within the same script run do not emit repeated blocks — only the first offense per run triggers the warning
- Lines that are empty or whitespace-only are ignored silently (not treated as malformed)

### 8. Install Lock

Only one installation can proceed at a time; concurrent installs are prevented.

- While an install is in progress, the install UI prevents starting another (button disabled, indicator shown)
- A reload triggered by the file watcher during an active install is deferred until the install completes
- The lock is released even if the install fails or is cancelled

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-07 | Initial spec |
| 2026-04-07 | Implemented all 8 features |
