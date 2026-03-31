# Feed Scripts

## Overview

Feed scripts are a category of Ask scripts that run on a schedule, deliver results to a dedicated Feed tab in the iPhone app, and exit after completing their work. They contrast with tile scripts, which run as persistent daemons and maintain a home-screen tile.

## Script Categories

### Tile Scripts (existing)
- Run as persistent daemons
- Maintain a home-screen tile showing current status
- Accept ongoing user interaction
- Examples: GitHub, Ollama, Claude Code Controller

### Feed Scripts (new)
- Run on a cron schedule, perform work, and exit
- Results appear in a Feed tab, not on the home screen
- May emit action-required blocks; those surface temporarily on the home screen
- Examples: Homebrew monitor

## Manifest Fields

```json
{
  "id": "brew-monitor",
  "name": "Homebrew",
  "type": "feed",
  "schedule": "0 9 * * *",
  "description": "...",
  "entry": "brew-monitor-bin",
  "icon": "shippingbox",
  "icon_file": "icon.svg"
}
```

- **`type`**: `"tile"` (default) or `"feed"`. Tile is backward-compatible default.
- **`schedule`**: Cron expression (5-field). Only meaningful for feed scripts. AskMac schedules the script using this value, launching it at the appropriate time. The schedule can be overridden per-machine via iOS app settings.

## Feed Script Lifecycle

1. AskMac launches the script at the scheduled time
2. Script initializes MCP, performs its work, emits blocks
3. If the script emits action blocks, it waits for user response (with a timeout)
4. Script exits cleanly after completing its work
5. AskMac does not auto-restart a cleanly-exiting feed script; it waits for the next scheduled time
6. If a feed script crashes (non-zero exit), AskMac emits a short-lived alert block and schedules the next run normally

## iOS Feed Tab

- A dedicated tab showing blocks from feed scripts, grouped by script, newest first
- Feed scripts do not appear on the home screen tile list unless they emit action-required blocks
- Action-required blocks from feed scripts surface on the home screen (toast + notification) AND remain visible in the Feed tab

## Schedule Management

- Default schedule is declared in the script's manifest
- Users can override the schedule per-machine via iOS app Settings → Feed Schedules
- Schedule overrides are stored in CloudKit (`FeedSchedule` record type) and polled by the Mac every 5 minutes

## Block TTLs for Feed Scripts

Feed scripts should set TTLs appropriate for their content:
- Informational results (e.g., "up to date"): 24 hours
- Action blocks (e.g., "updates available"): 24 hours
- Status blocks shown during work (e.g., "checking…"): 60 seconds

---

## Changelog

| Date | Change |
|---|---|
| 2026-03-31 | Initial spec — feed scripts concept, manifest fields, lifecycle, iOS Feed tab, schedule management |
| 2026-03-31 | brew-monitor converted to feed script (one-shot, type: feed, schedule: 0 9 * * *) |
