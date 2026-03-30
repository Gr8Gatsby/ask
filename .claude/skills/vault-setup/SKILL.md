---
name: vault-setup
description: Configure the AskMac script vault path for dev or prod. Dev points to the project's ask/scripts directory; prod points to ~/.ask/scripts.
argument-hint: [dev|prod]
---

Configure the AskMac script vault using the mode specified in $ARGUMENTS (dev or prod).

The vault path is stored in UserDefaults under the domain `simple.askmac`, key `vaultPath`. AskMac auto-discovers scripts from whatever directory this is set to.

## Prod mode

Prod uses the standard install location where all persistent scripts live:

```
~/.ask/scripts
```

Set it with:

```bash
defaults write simple.askmac vaultPath "$HOME/.ask/scripts"
```

## Dev mode

Dev points to the `ask/scripts` directory inside this repo. This lets you iterate on scripts without polluting the production vault.

First resolve the absolute path of the repo:

```bash
git -C "$(pwd)" rev-parse --show-toplevel
```

Then set:

```bash
defaults write simple.askmac vaultPath "$(git rev-parse --show-toplevel)/ask/scripts"
```

## After switching

AskMac hot-reloads the vault on changes, but if scripts don't appear, restart the app:

```bash
pkill -x AskMac && open -a AskMac
```

## Steps to execute

1. Determine mode from $ARGUMENTS (default to **prod** if not specified)
2. Run the appropriate `defaults write` command above using the Bash tool
3. Print the path that was set so the user can confirm it
4. Remind the user to restart AskMac if needed

## Installing example scripts

Example scripts live in `ask/scripts/` in this repo. To install them, copy the desired script folder into the vault:

```bash
cp -r ask/scripts/github ~/.ask/scripts/
cp -r ask/scripts/ollama ~/.ask/scripts/
cp -r ask/scripts/claudecode-controller ~/.ask/scripts/
cp -r ask/scripts/brew-monitor ~/.ask/scripts/
```

### Swift scripts require a rebuild

`brew-monitor` is the only Swift script. Its compiled binary (`brew-monitor-bin`) was signed on the original developer's machine — macOS will block it on any other Mac. After copying, rebuild and re-sign it:

```bash
cd ~/.ask/scripts/brew-monitor
./build.sh
```

This requires Swift (comes with Xcode or `xcode-select --install`). The build script compiles a release binary and ad-hoc signs it with `codesign --sign -` — no Apple Developer account needed.

All other scripts (`github`, `ollama`, `claudecode-controller`) are Python and run as-is.

## Notes

- Scripts in the vault must have a `manifest.json` to be auto-discovered
- The prod vault (`~/.ask/scripts`) persists across repo checkouts; the dev vault is repo-relative
