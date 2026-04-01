---
name: release-ios
description: Cut the iOS release — create annotated tag and push to trigger the TestFlight upload pipeline. Run after /prepare-release-ios.
---

Cut the iOS release by creating and pushing a version tag. This triggers the `ios-release.yml` GitHub Actions pipeline which archives the iOS app and uploads it to TestFlight.

## Step 1 — Verify repo state

Run:
- `git status` — must be clean
- `git branch --show-current` — must be `main`
- `git log origin/main..HEAD --oneline` — verify the version bump commit from `/prepare-release-ios` is present

If anything is wrong, stop and tell the user.

## Step 2 — Read the current iOS version

Run: `grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj | head -1`

Extract the version string (e.g. `2.1.0`). The tag will be `ios-v{version}`.

## Step 3 — Confirm with the user

Show:
```
Ready to release iOS v{version} to TestFlight

This will:
  1. Create annotated tag ios-v{version}
  2. Push the tag to origin
  3. Trigger the GitHub Actions iOS pipeline (ios-release.yml)

The pipeline will archive, sign, and upload the build to App Store Connect.
The build will be available in TestFlight once Apple's processing completes (~10–30 min).

Proceed? (yes/no)
```

Wait for explicit confirmation before continuing.

## Step 4 — Get the release notes

Read `docs/spec.md` and find the most recent iOS changelog entry (the row added by `/prepare-release-ios`).

Format the tag annotation as:
```
iOS v{version}

{the prose release notes written during /prepare-release-ios}

{the grouped commit list from /prepare-release-ios}
```

If the release notes from the current `/prepare-release-ios` session are available in the conversation, use those — they are more complete than the spec.md summary.

## Step 5 — Create the annotated tag

Write the annotation body to a temp file, then create the tag:

```bash
git tag -a "ios-v{version}" -F /tmp/release-notes-ios.txt
```

Verify: `git tag -l "ios-v{version}"`

## Step 6 — Push the tag

```bash
git push origin "ios-v{version}"
```

## Step 7 — Report

Show the user:
```
✅ Tag ios-v{version} pushed.

CI validation running at: https://github.com/Gr8Gatsby/ask/actions

Next step — run the local release script to archive, sign, and upload to TestFlight:

  export ASC_KEY_ID="your-key-id"
  export ASC_ISSUER_ID="your-issuer-id"
  ./scripts/release-ios.sh {version}

The ASC API key must be at:
  ~/.appstoreconnect/private_keys/AuthKey_{ASC_KEY_ID}.p8

Upload takes ~5 min. Apple processes the build after upload (~10–30 min).
Monitor: https://appstoreconnect.apple.com
```
