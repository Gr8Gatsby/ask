---
name: release-mac
description: Cut the Mac (AskMac) release — create annotated tag and trigger the build. Standalone use only — /prepare-release-mac now does this automatically end-to-end.
---

Cut the AskMac release by creating and pushing a version tag. Use this only when running the tag step in isolation (e.g. the PR was merged manually and /prepare-release-mac didn't complete the full flow).

## Step 1 — Verify repo state

Run:
- `git status` — must be clean
- `git branch --show-current` — must be `main`
- `git log origin/main..HEAD --oneline` — must be empty (no unpushed commits)

If there are unpushed commits, stop and tell the user to open a PR and merge first.

## Step 2 — Read the current Mac version

Run: `grep 'MARKETING_VERSION' AskMac/project.yml | head -1`

Extract the version string (e.g. `0.9.0`). The tag will be `v{version}`.

## Step 3 — Get the release notes

Use the release notes from the current conversation if `/prepare-release-mac` was run. Otherwise read `docs/spec.md` and find the most recent Mac changelog entry.

Format the tag annotation as:
```
AskMac v{version}

{prose release notes}

{grouped commit list}
```

## Step 4 — Create the annotated tag

Write the annotation body to a temp file, then create the tag:

```bash
git tag -a "v{version}" -F /tmp/release-notes-mac.txt
git tag -l "v{version}"
```

## Step 5 — Push the tag

```bash
git push origin "v{version}"
```

## Step 6 — Run the build

Run the build script (stream output, do not background):
```bash
./scripts/build-release.sh 2>&1 | tee /tmp/build-mac-{version}.log | grep -E "^==>|✅|❌|SUCCEEDED|FAILED|error:"
```

On failure, read `tail -50 /tmp/build-mac-{version}.log` and report the error.

## Step 7 — Trigger staple workflow

```bash
gh workflow run staple-release.yml --field tag=v{version}
```

Then poll until complete:
```bash
sleep 10
RUN_ID=$(gh run list --workflow=staple-release.yml --limit=1 --json databaseId --jq '.[0].databaseId')
while true; do
  STATUS=$(gh run view $RUN_ID --json status,conclusion --jq '[.status,.conclusion] | join("/")')
  echo "Staple workflow: $STATUS"
  [[ "$STATUS" == "completed/success" ]] && break
  [[ "$STATUS" == "completed/failure" ]] && echo "❌ Staple workflow failed — check https://github.com/Gr8Gatsby/ask/actions" && break
  sleep 20
done
```

## Step 8 — Report

```
✅ AskMac v{version} released

GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v{version}
appcast.xml updated — Sparkle auto-update live for all users.

Artifacts:
  AskMac-{version}.pkg            (PKG installer)
  AskMac-{version}-installer.dmg  (installer DMG)
  AskMac-{version}.dmg            (Sparkle update DMG)
```

**macOS 26 install workaround:** Users may see "Apple could not verify..." on macOS 26. Fix:
```bash
sudo installer -pkg "/Volumes/Install AskMac {version}/AskMac-{version}.pkg" -target /
# or: xattr -d com.apple.quarantine ~/Downloads/AskMac-{version}.pkg
```
