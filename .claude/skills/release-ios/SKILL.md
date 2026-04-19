---
name: release-ios
description: Cut the iOS release — create annotated tag, push, and upload to TestFlight. Run after /prepare-release-ios (standalone use only — /prepare-release-ios now does this automatically).
---

Cut the iOS release by creating and pushing a version tag, then uploading to TestFlight. Use this only when running the tag/upload step in isolation (e.g. the PR was merged manually and /prepare-release-ios didn't complete the full flow).

## Step 1 — Verify repo state

Run:
- `git status` — must be clean
- `git branch --show-current` — must be `main`
- `git log origin/main..HEAD --oneline` — must be empty (version bump PR already merged)

If there are unpushed commits, stop and tell the user to merge the PR first.

## Step 2 — Read the current iOS version

Run: `grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj | head -1`

Extract the version string (e.g. `2.1.0`). The tag will be `ios-v{version}`.

## Step 3 — Get the release notes

Read `docs/spec.md` and find the most recent iOS changelog entry. If release notes from the current session are available in conversation, use those — they are more complete than the spec.md summary.

Format the tag annotation as:
```
iOS v{version}

{prose release notes}

{grouped commit list}
```

## Step 4 — Create the annotated tag

Write the annotation body to a temp file, then create the tag:

```bash
git tag -a "ios-v{version}" -F /tmp/release-notes-ios.txt
git tag -l "ios-v{version}"
```

## Step 5 — Push the tag

```bash
git push origin "ios-v{version}"
```

## Step 6 — Run the upload script

Load credentials from Keychain and run:

```bash
ASC_KEY_ID=$(security find-generic-password -a "$USER" -s ASC_KEY_ID -w) \
ASC_ISSUER_ID=$(security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w) \
/Users/kevin/Documents/code/ask/scripts/release-ios.sh {version} 2>&1
```

Stream the output — do not run in the background. Takes ~5 minutes.

**Common upload failure: error 90717 (alpha channel in app icon)**
If Apple rejects with "Invalid large app icon… can't be transparent or contain an alpha channel":
1. Strip alpha: `python3 -c "from PIL import Image; img = Image.open('ask/ask/Assets.xcassets/AppIcon.appiconset/Ask-iOS-icon.png').convert('RGB'); img.save('ask/ask/Assets.xcassets/AppIcon.appiconset/Ask-iOS-icon.png', 'PNG')"`
2. Open a PR, merge it, pull main, then re-run the upload script (no new tag needed — same version)

## Step 7 — Report

```
✅ iOS v{version} uploaded to TestFlight

Tag: ios-v{version} pushed
Apple processes the build in ~10–30 min.
Monitor: https://appstoreconnect.apple.com

Note: Apple may send a compliance email to greatgatsby@gmail.com asking about
encryption. Answer "Yes, but only standard OS encryption (HTTPS/TLS)" — select
the exempt category. The build won't appear in TestFlight until this is answered.
```

## Prerequisites checklist

```bash
security find-generic-password -a "$USER" -s ASC_KEY_ID -w &>/dev/null || echo "MISSING: ASC_KEY_ID"
security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w &>/dev/null || echo "MISSING: ASC_ISSUER_ID"
test -f ~/.appstoreconnect/private_keys/AuthKey_Q2A223X6SQ.p8 || echo "MISSING: AuthKey_Q2A223X6SQ.p8"
security find-identity -v -p codesigning | grep -q "Apple Distribution" || echo "MISSING: Apple Distribution cert"
```
