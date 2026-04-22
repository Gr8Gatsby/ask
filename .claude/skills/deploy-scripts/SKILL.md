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
| **Dest (dev vault)** | `~/.ask/dev-vault/` — only scripts already present there |

Scripts are never edited in either vault directly. The repo is the single source of truth.

## Steps to execute

1. Determine which scripts to deploy from $ARGUMENTS:
   - If a specific script ID is given (e.g. `claudecode-controller`), deploy only that folder
   - Otherwise deploy **all** scripts (default)

2. Get the repo root:
```bash
git -C "$(pwd)" rev-parse --show-toplevel
```

3. Before deploying all scripts, check for any scripts that exist in the prod vault but no longer exist in the repo source. These are being deleted — run their uninstall script first so they can clean up system state (hooks, config, etc.):
```bash
for dir in ~/.ask/scripts/*/; do
  id=$(basename "$dir")
  if [ ! -d "<repo-root>/ask/scripts/$id" ]; then
    setup="$dir/setup.py"
    if [ -f "$setup" ]; then
      echo "Uninstalling $id before removal..."
      PYTHONPATH="$HOME/.ask/scripts:$dir" python3 "$setup" --uninstall
    fi
  fi
done
```
Skip this step when deploying a single named script.

4. For each script to deploy, rsync it to the prod vault:
```bash
rsync -av --delete "<repo-root>/ask/scripts/<script-id>/" ~/.ask/scripts/<script-id>/
```

   Also sync to the dev vault for any script already installed there (dev builds use `~/.ask/dev-vault/`):
```bash
if [ -d "$HOME/.ask/dev-vault/<script-id>" ]; then
  rsync -av --delete "<repo-root>/ask/scripts/<script-id>/" ~/.ask/dev-vault/<script-id>/
fi
```

5. **brew-monitor only** — it's a Swift script with a compiled binary. After copying, rebuild it:
```bash
cd ~/.ask/scripts/brew-monitor && ./build.sh
```
Skip this step for all other scripts (Python, no build needed).

6. Reload AskMac so it picks up the changes:
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
