# Script Updates via GitHub Releases

## Overview

Scripts are hosted on GitHub as individually downloadable zips under a rolling `scripts-latest` release. The Mac app periodically checks a `catalog.json` index published alongside those zips. When a newer version of an installed script is available, an Update button appears on that script's card in Settings. Tapping it shows the version delta and release notes before the user confirms.

---

## GitHub Release Structure

A single GitHub Release tagged `scripts-latest` (a rolling/moving tag, re-created on each script change) contains:

- `catalog.json` — index of all available scripts with versions and download URLs
- One zip per script, e.g. `claudecode-controller.zip`, `brew-monitor.zip`

### `catalog.json` schema

```json
{
  "generated": "2026-04-07T12:00:00Z",
  "scripts": [
    {
      "id": "claudecode-controller",
      "name": "Claude Code",
      "version": "2.16.2",
      "description": "Claude Code session supervisor — routes permissions and notifications to iPhone",
      "icon": "sparkles",
      "changelog": "Fixed session handoff bug on reconnect.\nImproved block rendering for long tool outputs.",
      "download_url": "https://github.com/anthropics/ask/releases/download/scripts-latest/claudecode-controller.zip"
    }
  ]
}
```

**Fields:**

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Matches `manifest.json` `id` |
| `name` | yes | Display name |
| `version` | yes | Semver string |
| `description` | yes | One-line summary |
| `icon` | no | SF Symbol name fallback |
| `changelog` | no | Plain-text release notes for this version; shown in update sheet |
| `download_url` | yes | Direct URL to the script's zip asset |

---

## Update Check Behavior

- The app fetches `catalog.json` **once on launch** and **once every 24 hours** while running
- The fetch is silent; no UI change occurs unless updates are found
- A script has an available update when the catalog version is strictly newer than the installed version (using the existing semver comparison in `ScriptInstaller`)
- Scripts with no matching catalog entry are not considered (user-installed third-party scripts are ignored by the update system)
- Network errors are silently swallowed; the last successful catalog result is cached in memory for the session

---

## Script Card — Update State

When an update is available for an installed script, the script's sidebar row and detail card both change:

### Sidebar row
- A small badge dot (accent color) appears next to the script name, similar to the existing status dot
- The status line reads "Update available" instead of the running status

### Detail card
- A prominent **Update Available** banner appears at the top of the detail view, above the existing setup section
- The banner shows: current version → new version (e.g. `2.16.1 → 2.16.2`)
- An **"Update"** button is in the banner

---

## Update Sheet

Tapping the Update button presents a sheet showing:

1. **Script name and icon**
2. **Version change**: `Current: 2.16.1` / `New: 2.16.2`
3. **Changelog**: the `changelog` field from `catalog.json`, rendered as plain text. If the field is absent, the sheet shows "No release notes provided."
4. **"Install Update"** button (primary) — triggers download and install
5. **"Cancel"** button — dismisses the sheet

During download and install, the sheet transitions to a progress view ("Downloading…", "Installing…") and closes automatically when done. The existing `ScriptInstaller` pipeline handles extraction and setup.

If the download or install fails, an inline error is shown in the sheet with a "Try Again" button.

---

## What Is Not in Scope

- Automatic/silent installation without user confirmation
- Update notifications (banners, badges on the app icon, or notification center)
- Rollback to a previous version
- Third-party or user-sideloaded script update checks
- Per-script update schedules (all scripts share the same 24-hour check cadence)

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-07 | Initial spec |
