---
name: release-mac
description: Cut the Mac (AskMac) release — create annotated tag and push to trigger the GitHub Actions release pipeline. Run after /prepare-release-mac.
---

Cut the AskMac release by creating and pushing a version tag. This triggers the `release.yml` GitHub Actions pipeline which validates the build.

## Step 1 — Verify repo state

Run:
- `git status` — must be clean
- `git branch --show-current` — must be `main`
- `git log origin/main..HEAD --oneline` — must be empty (no unpushed commits)

If there are unpushed commits, stop and tell the user to open a PR and merge first.

## Step 2 — Read the current Mac version

Run: `grep 'MARKETING_VERSION' AskMac/project.yml | head -1`

Extract the version string (e.g. `0.7.0`). The tag will be `v{version}`.

## Step 3 — Confirm with the user

Show:
```
Ready to release AskMac v{version}

This will:
  1. Create annotated tag v{version}
  2. Push the tag to origin
  3. Trigger the GitHub Actions release pipeline (release.yml)

Proceed? (yes/no)
```

Wait for explicit confirmation before continuing.

## Step 4 — Get the release notes

Use the release notes from the current conversation if `/prepare-release-mac` was run. Otherwise read `docs/spec.md` and find the most recent Mac changelog entry.

Format the tag annotation as:
```
AskMac v{version}

{prose release notes}

{grouped commit list}
```

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

Next: run /build-pkg-mac to sign, notarize, and publish the release artifacts.
```
