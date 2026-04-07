---
name: release-scripts
description: Publish Ask scripts to GitHub Releases. Generates catalog.json, zips each script directory, and creates or updates the scripts-latest rolling release on GitHub. Run whenever any script in ask/scripts/ changes.
argument-hint: [changelog message]
---

Publish all Ask scripts to the `scripts-latest` GitHub Release so the Mac app can browse and install them.

## Overview

The release consists of:
- `catalog.json` — index of all scripts with versions, descriptions, and download URLs
- One zip per script, e.g. `claudecode-controller.zip`

The release uses a rolling tag `scripts-latest` that is deleted and re-created on each publish so the Mac app always fetches from a stable URL.

## Step 1 — Verify repo state

```bash
git status --short
```

Warn (but do not stop) if there are uncommitted changes to files in `ask/scripts/`. The publish uses the files on disk, not HEAD.

## Step 2 — Determine changelog text

If `$ARGUMENTS` is non-empty, use it as the changelog for all scripts being published (e.g. "Fixed session reconnect bug").

Otherwise, check recent git log for changes to ask/scripts/ since the last scripts-latest tag:
```bash
git log --oneline scripts-latest..HEAD -- ask/scripts/ 2>/dev/null | head -20
```
If that fails (first publish), use all recent commits touching ask/scripts/:
```bash
git log --oneline -10 -- ask/scripts/
```
Summarize those commits into a brief changelog string.

## Step 3 — Read all script manifests

For each directory in `ask/scripts/` that contains a `manifest.json`:

```bash
ls ask/scripts/
```

Read each `ask/scripts/<id>/manifest.json` and extract: `id`, `name`, `version`, `description`, `icon`, `icon_file`, `type`.

Skip any directory without a `manifest.json`.

## Step 4 — Build catalog.json

Construct `catalog.json` with this structure:

```json
{
  "generated": "<ISO 8601 timestamp>",
  "scripts": [
    {
      "id": "<id>",
      "name": "<name>",
      "version": "<version>",
      "description": "<description>",
      "icon": "<icon or null>",
      "type": "<type: tile|feed|system>",
      "changelog": "<changelog text from Step 2>",
      "download_url": "https://github.com/Gr8Gatsby/ask/releases/download/scripts-latest/<id>.zip"
    }
  ]
}
```

Write to a temp location: `/tmp/ask-scripts-release/catalog.json`

## Step 5 — Zip each script

For each script, create a zip containing only the script's files (exclude `.build/` directories and `__pycache__`):

```bash
mkdir -p /tmp/ask-scripts-release
cd ask/scripts
zip -r /tmp/ask-scripts-release/<id>.zip <id>/ \
  --exclude "<id>/.build/*" \
  --exclude "<id>/__pycache__/*" \
  --exclude "<id>/*.pyc"
```

Confirm each zip was created successfully.

## Step 6 — Delete and re-create the rolling release

First, delete the existing tag and release (ignore errors if they don't exist yet):

```bash
gh release delete scripts-latest --yes 2>/dev/null || true
git push origin --delete scripts-latest 2>/dev/null || true
```

Create a new release with the `scripts-latest` tag:

```bash
gh release create scripts-latest \
  --title "Scripts (latest)" \
  --notes "$(cat <<'EOF'
Latest Ask scripts. This release is updated automatically whenever scripts change.

**Updated:** <timestamp>
**Scripts:** <count> scripts included
EOF
)" \
  --latest=false \
  /tmp/ask-scripts-release/catalog.json \
  /tmp/ask-scripts-release/*.zip
```

## Step 7 — Verify the release

```bash
gh release view scripts-latest --json assets --jq '.assets[].name'
```

Confirm `catalog.json` and all expected `.zip` files are listed.

## Step 8 — Clean up temp files

```bash
rm -rf /tmp/ask-scripts-release
```

## Step 9 — Report

Show the user:
```
✅ Scripts published to scripts-latest

Assets:
  - catalog.json
  - <id>.zip  (v<version>)  ← one line per script

Release: https://github.com/Gr8Gatsby/ask/releases/tag/scripts-latest
```

## Notes

- brew-monitor zips include source + `build.sh` but not the compiled `.build/` output
- The `scripts-latest` tag is a rolling pointer — there is no version history in the release assets (git history serves that purpose)
- `--latest=false` keeps this from showing as the "latest" release on the repo's releases page (so it doesn't displace Mac app releases)
