---
name: prepare-release-ios
description: Prepare an iOS release end-to-end — version bump, release notes, spec changelog, commit, auto-merge PR, tag, upload to TestFlight. One pause for release notes review.
---

Full end-to-end iOS release. One pause for release notes review — everything else runs automatically.

## Step 1 — Sync and verify repo state

```bash
git fetch origin main && git checkout main && git merge origin/main
```

Verify clean working tree (`git status`). If not clean, stop and tell the user.

## Step 2 — Find the last iOS release and list commits

```bash
git tag --sort=-version:refname | grep '^ios-v' | head -1
git log {LAST_TAG}..HEAD --oneline
```

Group commits by type prefix (feat, fix, perf, chore). Note which are iOS-relevant (iOS app, CloudKit, notifications, blocks UI) vs Mac-only or scripts-only.

## Step 3 — Propose a version bump

Read current iOS version:
```bash
grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj | head -1
```

Apply semantic versioning (patch / minor / major). State the proposed version and justification — do not ask for confirmation, just proceed.

## Step 4 — Write release notes and PAUSE for user review

Write release notes:

**Prose summary (2–4 sentences)** — what changed from the iOS user's perspective. Focus on what they'll notice in the app. Do not mention Mac-only changes unless they directly affect the iOS experience.

**Details:**
```
### What's New
### Bug Fixes
### Performance
### Other Changes
```
Each line: `- {commit subject} ({short hash})`

Example format:
```
iOS v2.1.0

This release improves push notification navigation so tapping a notification
while the app is closed now lands directly on the correct script block.

### Bug Fixes
- fix(notifications): cold-start navigation, block freshness (335aadc)
```

Present the draft. Say: "Review the release notes above — reply **yes** to proceed or give edits."

**Wait for explicit confirmation before continuing.**

## Step 5 — Bump iOS version (after user approves)

The iOS `MARKETING_VERSION` appears multiple times in `ask/ask.xcodeproj/project.pbxproj` (one per build configuration). Update all of them.

First check exact value and context:
```bash
grep -n 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj
```

Use Edit with `replace_all: true` to change every instance of:
`MARKETING_VERSION = {old_version};`
to:
`MARKETING_VERSION = {new_version};`

**Important:** Only update lines for the main Ask iOS target. Do not change entries for other targets (e.g. watch extensions with different version numbers).

Verify: `grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj`

## Step 6 — Update the spec changelog

Add a new row at the top of the Change Log table in `docs/spec.md`:
```
| {YYYY-MM-DD} | iOS v{version}: {one-line summary} |
```

## Step 7 — Branch, commit, PR, and auto-merge

```bash
git checkout -b release/ios-{version}
git add ask/ask.xcodeproj/project.pbxproj docs/spec.md
git commit -m "chore(ios): bump version to {version}"
git push -u origin release/ios-{version}
gh pr create --title "chore(ios): release v{version}" --base main --body "{one-line summary}"
gh pr merge --auto --merge
```

Then poll until the PR merges:
```bash
while true; do
  STATE=$(gh pr view --json state --jq '.state' 2>/dev/null)
  [[ "$STATE" == "MERGED" ]] && break
  echo "Waiting for PR CI to pass and merge... ($STATE)"
  sleep 15
done
git checkout main && git fetch origin main && git merge origin/main
```

## Step 8 — Create annotated tag

Write release notes to `/tmp/release-notes-ios.txt`, then:
```bash
git tag -a "ios-v{version}" -F /tmp/release-notes-ios.txt
git tag -l "ios-v{version}"
git push origin "ios-v{version}"
```

## Step 9 — Run the upload script

Load credentials from Keychain and run:
```bash
ASC_KEY_ID=$(security find-generic-password -a "$USER" -s ASC_KEY_ID -w) \
ASC_ISSUER_ID=$(security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w) \
/Users/kevin/Documents/code/ask/scripts/release-ios.sh {version} 2>&1
```

Stream the output — do not run in the background. The script archives, signs, and uploads to App Store Connect. It takes ~5 minutes.

**Common upload failure: error 90717 (alpha channel in app icon)**
If Apple rejects with "Invalid large app icon… can't be transparent or contain an alpha channel":
1. Strip alpha: `python3 -c "from PIL import Image; img = Image.open('ask/ask/Assets.xcassets/AppIcon.appiconset/Ask-iOS-icon.png').convert('RGB'); img.save('ask/ask/Assets.xcassets/AppIcon.appiconset/Ask-iOS-icon.png', 'PNG')"`
2. Open a PR, merge it, pull main, then re-run the upload script (no new tag needed — same version)

## Step 10 — Report

```
✅ iOS v{version} uploaded to TestFlight

Tag: ios-v{version}
Apple processes the build in ~10–30 min.
Monitor: https://appstoreconnect.apple.com

Note: Apple may send a compliance email to greatgatsby@gmail.com asking about
encryption. Answer "Yes, but only standard OS encryption (HTTPS/TLS)" — select
the exempt category. The build won't appear in TestFlight until this is answered.
```

## Prerequisites checklist (run silently before Step 9, report failures only)

```bash
security find-generic-password -a "$USER" -s ASC_KEY_ID -w &>/dev/null || echo "MISSING: ASC_KEY_ID"
security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w &>/dev/null || echo "MISSING: ASC_ISSUER_ID"
test -f ~/.appstoreconnect/private_keys/AuthKey_Q2A223X6SQ.p8 || echo "MISSING: AuthKey_Q2A223X6SQ.p8"
security find-identity -v -p codesigning | grep -q "Apple Distribution" || echo "MISSING: Apple Distribution cert"
```
