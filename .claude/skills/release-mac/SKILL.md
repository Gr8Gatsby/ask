---
name: release-mac
description: Cut the Mac (AskMac) release — create annotated tag and push to trigger the GitHub Actions release pipeline. Run after /prepare-release-mac.
---

Cut the AskMac release by creating and pushing a version tag. This triggers the `release.yml` GitHub Actions pipeline which builds, signs, notarizes, and publishes the release to GitHub.

## Step 1 — Verify repo state

Run:
- `git status` — must be clean
- `git branch --show-current` — must be `main`
- `git log origin/main..HEAD --oneline` — verify the version bump commit from `/prepare-release-mac` is present

If anything is wrong, stop and tell the user what needs to be fixed.

## Step 2 — Read the current Mac version

Run: `grep 'MARKETING_VERSION' AskMac/project.yml | head -1`

Extract the version string (e.g. `1.2.0`). The tag will be `v{version}`.

## Step 3 — Confirm with the user

Show:
```
Ready to release AskMac v{version}

This will:
  1. Create annotated tag v{version}
  2. Push the tag to origin
  3. Trigger the GitHub Actions release pipeline (release.yml)

The pipeline will build, sign, notarize, and publish:
  - AskMac-{version}-installer.dmg  (PKG installer for first-time installs)
  - AskMac-{version}.dmg            (Sparkle auto-update artifact)

The appcast at docs/appcast.xml will be updated automatically.

Proceed? (yes/no)
```

Wait for explicit confirmation before continuing.

## Step 4 — Get the release notes

Read `docs/spec.md` and find the most recent Mac changelog entry (the row added by `/prepare-release-mac`). Use the full content of that row as the basis for the tag annotation body.

Format the tag annotation as:
```
AskMac v{version}

{the prose release notes written during /prepare-release-mac}

{the grouped commit list from /prepare-release-mac}
```

If the user has the release notes available in the current conversation from running `/prepare-release-mac`, use those directly — they are more complete than the spec.md summary.

## Step 5 — Create the annotated tag

Write the annotation body to a temp file, then create the tag:

```bash
git tag -a "v{version}" -F /tmp/release-notes-mac.txt
```

Verify the tag was created: `git tag -l "v{version}"`

## Step 6 — Push the tag

```bash
git push origin "v{version}"
```

## Step 7 — Report

Show the user:
```
✅ Tag v{version} pushed.

CI validation running at: https://github.com/Gr8Gatsby/ask/actions

Next step — run the local build script to sign, notarize, and publish:

  export APPLE_ID="your@apple.id"
  export APPLE_ID_PASSWORD="app-specific-password"
  export APPLE_TEAM_ID="B5J28L8ARB"
  ./scripts/build-release.sh {version}

This will produce the installer DMG, Sparkle update DMG, update appcast.xml,
and create the GitHub Release automatically via gh.
```
