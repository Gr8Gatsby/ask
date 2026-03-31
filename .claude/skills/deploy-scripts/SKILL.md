---
name: deploy-scripts
description: Deploy Ask scripts from the repo (ask/scripts/) to the prod vault (~/.ask/scripts). Always run this after editing any script in the repo.
argument-hint: [script-id | all]
---

Copy updated scripts from the project repo to the prod vault, then reload AskMac.

## Source and destination

| | Path |
|---|---|
| **Source (edit here)** | `<repo-root>/ask/scripts/` |
| **Dest (prod vault)** | `~/.ask/scripts/` |

Scripts are never edited in `~/.ask/scripts/` directly. The repo is the single source of truth.

## Steps to execute

1. Determine which scripts to deploy from $ARGUMENTS:
   - If a specific script ID is given (e.g. `claudecode-controller`), deploy only that folder
   - Otherwise deploy **all** scripts (default)

2. Get the repo root:
```bash
git -C "$(pwd)" rev-parse --show-toplevel
```

3. For each script to deploy, rsync it:
```bash
rsync -av --delete "<repo-root>/ask/scripts/<script-id>/" ~/.ask/scripts/<script-id>/
```

4. **brew-monitor only** — it's a Swift script with a compiled binary. After copying, rebuild it:
```bash
cd ~/.ask/scripts/brew-monitor && ./build.sh
```
Skip this step for all other scripts (Python, no build needed).

5. Reload AskMac so it picks up the changes:
```bash
osascript -e 'tell application "AskMac" to activate'
```
Then tell the user to click the reload button (↺) in the AskMac Actions settings tab, or restart AskMac if scripts don't update:
```bash
pkill -x AskMac && open -a AskMac
```

## Notes

- `rsync --delete` removes files in dest that no longer exist in source — keeps the prod vault clean
- After deploying, confirm the version number in AskMac Settings matches the manifest version in the repo
- Hook scripts under `hooks/` are included automatically since rsync copies the full folder
