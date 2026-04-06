---
name: release
description: Full release of Ask — merges the feature branch, bumps both Mac and iOS versions, writes release notes, tags both platforms, builds the Mac PKG, and uploads to TestFlight. Supports alpha / beta / stable channels.
---

Release the Ask app (Mac + iOS) to the given version. Do all work yourself using tools. One confirmation is required from the user (after showing release notes). Everything else runs automatically.

Invocation: `/release {version} [channel]`

Examples:
- `/release 0.7.2 alpha`  — prerelease GitHub release, Sparkle alpha channel, TestFlight
- `/release 0.7.2 beta`   — prerelease GitHub release, Sparkle beta channel, TestFlight
- `/release 0.7.2`        — stable release (default), full GitHub release, Sparkle served to all users

**Channel rules:**
- `alpha` — GitHub release marked as prerelease. Sparkle appcast entry includes `<sparkle:channel>alpha</sparkle:channel>` so only alpha-enrolled users receive the auto-update.
- `beta` — Same as alpha but channel tag is `beta`.
- `stable` (default) — GitHub release not marked as prerelease. No channel tag in appcast — all users receive the update via standard Sparkle check.

If no version is provided, stop and ask the user for one. If no channel is provided, default to `alpha` and tell the user (since the project is currently in alpha).

---

## Phase 1 — Merge the feature branch to main

**1a. Check current branch**

Run: `git branch --show-current`

If already on `main`, skip to Phase 2.

If on a feature branch:

**1b. Ensure branch is pushed and up to date**

```bash
git push -u origin HEAD
```

**1c. Find or create a PR for this branch**

```bash
gh pr list --head $(git branch --show-current) --json number,url,title
```

If no PR exists, create one. Use the branch name to derive a title (strip the `feat/` prefix and replace `-` with spaces):
```bash
BRANCH=$(git branch --show-current)
TITLE=$(echo "$BRANCH" | sed 's|feat/||;s|-| |g')
gh pr create --title "$TITLE" \
  --body "Feature work included in v{version} release." \
  --base main
```

**1d. Merge the PR**

Use `--merge` (not squash) to preserve individual commit history:
```bash
gh pr merge --merge --delete-branch
```

If the branch is behind main, merge main in first:
```bash
git fetch origin main && git merge origin/main --no-edit && git push
```

Wait for it to complete, then:
```bash
git checkout main && git pull
```

---

## Phase 2 — Gather commits since the last release

**2a. Find the most recent tag (either platform)**

```bash
git tag --sort=-version:refname | grep -E '^v|^ios-v' | head -5
```

Use the most recent tag (by date, not name) as the starting point. If no tags exist, use the full history.

**2b. List commits since that tag**

```bash
git log {LAST_TAG}..HEAD --oneline
```

Group by prefix: `feat`, `fix`, `perf`, `chore`, `refactor`, `docs`. Note which commits are iOS-relevant (iOS app, blocks UI, feed, session chat) vs Mac-only (AskMac, menu bar, PKG) vs shared (scripts, CloudKit, notifications).

---

## Phase 3 — Write release notes and confirm with the user

Write unified release notes covering both platforms:

**Section 1 — Prose summary (2–4 sentences)**
Write as if describing the release to a user. Focus on what they'll experience. Don't just restate commit messages. Mention key new features and important fixes.

**Section 2 — Details**
```
### What's New
### Bug Fixes
### Performance
### Other Changes
```
Each line: `- {commit subject} ({short hash})`

Mark iOS-specific lines with `[iOS]` and Mac-specific with `[Mac]` where helpful.

**Present the draft to the user.** Ask: "Ready to release v{version} with these notes? (yes / edit)"

- If "yes" → continue
- If "edit" or feedback → incorporate it and re-confirm

**Do not proceed past this point without explicit confirmation.**

---

## Phase 4 — Bump versions and update spec

**4a. Bump the Mac version**

Edit `AskMac/project.yml` — update `MARKETING_VERSION` to `{version}`.

Verify: `grep MARKETING_VERSION AskMac/project.yml`

**4b. Bump the iOS version**

The iOS `MARKETING_VERSION` appears multiple times in `ask/ask.xcodeproj/project.pbxproj`. Update all occurrences.

First check: `grep -n 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj`

Use Edit with `replace_all: true` to change every instance of:
`MARKETING_VERSION = {old_version};`
to:
`MARKETING_VERSION = {version};`

Verify: `grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj | head -3`

**4c. Update the spec changelog**

Open `docs/spec.md`. Add a new row at the top of the Change Log table:

```
| {today's date} | v{version}: {one-line summary of this release} |
```

**4d. Commit and push directly to main**

```bash
git add AskMac/project.yml ask/ask.xcodeproj/project.pbxproj docs/spec.md
git commit -m "chore: bump versions to {version}"
git push
```

---

## Phase 5 — Create annotated tags

Write the Mac tag annotation to a temp file and tag:

```bash
cat > /tmp/release-notes-{version}.txt << 'NOTES'
Ask v{version}

{prose summary}

### What's New
{feat commits}

### Bug Fixes
{fix commits}

### Other Changes
{other commits}
NOTES

git tag -a "v{version}" -F /tmp/release-notes-{version}.txt
git tag -a "ios-v{version}" -F /tmp/release-notes-{version}.txt
```

Verify: `git tag -l "v{version}" "ios-v{version}"`

Push both tags:

```bash
git push origin "v{version}" "ios-v{version}"
```

---

## Phase 6 — Build and publish Mac release

Run the Mac build script, passing the version and channel (do NOT run in background). Pipe through `tee` so the full log is preserved and progress is visible without flooding context:

```bash
./scripts/build-release.sh {version} {channel} 2>&1 | tee /tmp/build-{version}.log | grep -E "^==>|^ERROR|error:|✅|❌|SUCCEEDED|FAILED|WARNING"
```

If the grep filter misses a failure, read the full log: `tail -50 /tmp/build-{version}.log`

This takes 10–20 minutes and does the following:
1. Runs installer consistency check (distribution.xml vs ask/scripts/ vs installer/scripts/)
2. Generates `AskMac.xcodeproj` via xcodegen
3. Archives + exports the app
4. Signs scripts with Developer ID
5. Builds component + distribution PKGs
6. Notarizes PKG
7. Creates installer DMG → signs → **notarizes** installer DMG
8. Creates Sparkle update DMG → signs → notarizes Sparkle DMG
9. **Verifies all four artifacts** (signed + notarized) before publishing — exits if any fail
10. Signs Sparkle DMG with EdDSA and injects entry into `docs/appcast.xml`
11. Commits and pushes `docs/appcast.xml` to main
12. Creates GitHub Release with **four artifacts**: `AskMac-{version}.pkg`, `AskMac-{version}-installer.dmg`, `AskMac-{version}.dmg`, `AskMac-{version}.app.zip`

**Note on stapling:** `xcrun stapler` may fail with Error 65 locally. This is NOT always a macOS version regression — it can be caused by an SSL certificate mismatch on Apple's `oscdn.apple.com` CDN at the user's network edge (Akamai routing issue). Before assuming a build problem, verify:
```bash
curl -v --max-time 5 https://oscdn.apple.com/ 2>&1 | grep -E "subjectAltName|SSL|error"
```
If you see "subjectAltName does not match", the CDN has an SSL issue and stapling will fail locally regardless of your build. The `staple-release` GitHub Actions workflow runs on `macos-15` (Sequoia) after publish and staples all four artifacts (PKG, installer DMG, Sparkle DMG, app zip). Monitor CI to confirm stapling succeeded.

**Note on local Gatekeeper testing after a CDN SSL issue:** If `oscdn.apple.com` has the SSL mismatch on your machine, `spctl --assess` will always return "Unnotarized Developer ID" for freshly-downloaded files even when properly notarized and CI-stapled. This does NOT mean the app is broken for users — it means the local validation check cannot reach Apple's CDN. Users on other networks will see normal Gatekeeper approval. To test locally, bypass with right-click > Open or System Settings > Privacy & Security > Open Anyway (this caches the approval and won't recur).

If the build fails, diagnose and stop — do not proceed to the iOS upload.

---

## Phase 6b — Confirm CI stapling

After the GitHub release is created, the `staple-release` workflow triggers automatically. Check it completed successfully:

```bash
gh run list --repo Gr8Gatsby/ask --workflow staple-release.yml --limit 3
```

If it failed or didn't trigger, run manually:
```bash
gh workflow run staple-release.yml --repo Gr8Gatsby/ask --field tag=v{version}
```

Wait for completion, then verify all four artifacts are stapled on Sequoia (the CI log will show "The staple and validate action worked!" for PKG, installer DMG, Sparkle DMG, and the `.app` inside the app zip).

---

## Phase 7 — Upload iOS to TestFlight

Load credentials from Keychain and run the iOS upload script:

```bash
ASC_KEY_ID=$(security find-generic-password -a "$USER" -s ASC_KEY_ID -w) \
ASC_ISSUER_ID=$(security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w) \
/Users/kevin/Documents/code/ask/scripts/release-ios.sh {version}
```

This archives the iOS app, signs it, and uploads to App Store Connect.
Upload takes ~5 min. Apple processes the build after upload (~10–30 min).

**After upload:** Apple sends a compliance email to the Apple ID on the account asking "Does your app use encryption?" — the build will **not appear in TestFlight** until this is answered. Check the inbox for `no_reply@email.apple.com` and answer the export compliance question. The answer for this app is "Yes, but it uses only standard OS encryption (HTTPS/TLS)" — select the exempt category.

---

## Phase 8 — Report

Show the user:

```
✅ Ask v{version} [{channel}] released

Mac
  GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v{version}
    → {prerelease (alpha/beta) | standard release (stable)}
  Sparkle: appcast.xml updated
    → {channel="alpha"/"beta" (only enrolled users) | all users (stable)}
  Artifacts: AskMac-{version}.pkg, AskMac-{version}-installer.dmg, AskMac-{version}.dmg
  Stapling: CI workflow stapling on macOS Sequoia — check https://github.com/Gr8Gatsby/ask/actions

iOS
  Tag: ios-v{version} pushed
  TestFlight upload complete — Apple processing (~10–30 min)
  Monitor: https://appstoreconnect.apple.com
    → {Distribute to internal testers (alpha) | external testers (beta) | submit for review (stable)}
```

**macOS 26 install workaround:** Due to a known Apple regression (`spctl --type install` broken for PKG installers on macOS 26, issue #32), users on macOS 26 may see "Apple could not verify..." even after CI stapling. Workaround:
```bash
# Option 1 — install via Terminal (bypasses Gatekeeper UI):
sudo installer -pkg "/Volumes/Install AskMac {version}/AskMac-{version}.pkg" -target /

# Option 2 — remove quarantine then open normally:
xattr -d com.apple.quarantine ~/Downloads/AskMac-{version}.pkg
open ~/Downloads/AskMac-{version}.pkg
```

For `stable` releases, remind the user to:
- Promote the TestFlight build to external testers or submit for App Store review in App Store Connect
- Verify the Sparkle update reaches users by checking appcast.xml is live

---

## Prerequisite checks

Before Phase 6, verify these silently (only report failures):

```bash
# Mac build tools
command -v xcodegen || echo "MISSING: brew install xcodegen"
command -v create-dmg || echo "MISSING: brew install create-dmg"
ls sparkle/bin/sign_update 2>/dev/null || echo "MISSING: Sparkle tools (see /build-pkg-mac)"

# Apple credentials
security find-generic-password -a "$USER" -s APPLE_ID -w &>/dev/null || echo "MISSING: APPLE_ID in Keychain"
security find-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w &>/dev/null || echo "MISSING: APPLE_ID_PASSWORD in Keychain"
security find-generic-password -a "$USER" -s APPLE_TEAM_ID -w &>/dev/null || echo "MISSING: APPLE_TEAM_ID in Keychain"
security find-identity -v -p codesigning | grep -q "Developer ID Application" || echo "MISSING: Developer ID Application cert"
security find-generic-password -a "$USER" -s ASC_KEY_ID -w &>/dev/null || echo "MISSING: ASC_KEY_ID in Keychain"
security find-generic-password -a "$USER" -s ASC_ISSUER_ID -w &>/dev/null || echo "MISSING: ASC_ISSUER_ID in Keychain"
test -f ~/.appstoreconnect/private_keys/AuthKey_Q2A223X6SQ.p8 || echo "MISSING: AuthKey_Q2A223X6SQ.p8"
```

**Installer consistency check** — the build script verifies every script in `installer/distribution.xml` has both a source directory in `ask/scripts/` and an installer scripts dir in `installer/scripts/`. If it fails:
- A script was archived → remove it from `distribution.xml` and `installer/scripts/`
- A script was renamed → update both locations to match the new ID
- A new script was added to the installer → create its `installer/scripts/{id}/postinstall`

**Note:** System scripts (`"type": "system"` in `manifest.json`) are bundled into the app but never user-installable — excluded from PKG automatically. Do not add them to `distribution.xml`.

**Provisioning profile check** — verify the installed profile has production CloudKit enabled:

```bash
security cms -D -i ~/Library/MobileDevice/Provisioning\ Profiles/$(
  grep -r "036fee16" ~/Library/MobileDevice/Provisioning\ Profiles/ -l 2>/dev/null | head -1
) 2>/dev/null | python3 -c "
import sys, plistlib
p = plistlib.loads(sys.stdin.buffer.read())
env = p.get('Entitlements', {}).get('com.apple.developer.icloud-container-environment', 'MISSING')
print('icloud-container-environment:', env)
" 2>/dev/null || echo "Profile not found in system — check ~/Downloads for .provisionprofile files"
```

Must show `icloud-container-environment: Production`. If it shows `MISSING` or `Development`, the provisioning profile does not have production CloudKit enabled. The profile in `~/Downloads/AskMac (2).provisionprofile` (UUID `036fee16`) is known good — install it by double-clicking before building.

**Entitlements check** — before building, verify `AskMac/Sources/AskMac/AskMac.entitlements` contains ALL five required entitlements. Missing entitlements cause silent runtime failures even when the build succeeds and notarization is accepted. Required entitlements for this app:

```bash
grep -E "application-identifier|icloud-container-environment|icloud-container-identifiers|icloud-services|network.client" \
  AskMac/Sources/AskMac/AskMac.entitlements
```

Must show all five keys. The `entitlements.properties` block in `AskMac/project.yml` is the source of truth — xcodegen regenerates the `.entitlements` file on every run, so edits to the file directly are lost. Always edit `project.yml`.

Critical entitlements and what breaks without them:
- `com.apple.application-identifier` (`B5J28L8ARB.com.kevinhill.askmac`) — **required for CloudKit init**. Missing causes "Trying to initialize a container without an application ID" crash at runtime. Our re-signing step in `build-release.sh` uses this file directly — if absent, it gets stripped.
- `com.apple.developer.icloud-container-environment: Production` — **routes to production CloudKit**. Without this the app silently writes to the development database — data will not be visible to iOS or other production clients. `CLOUDKIT_ENVIRONMENT: PRODUCTION` in `project.yml` build settings is NOT sufficient on its own; this entitlement must be present in the entitlements file AND allowed by the provisioning profile.
- `com.apple.developer.icloud-container-identifiers` — identifies the CloudKit container (`iCloud.simple.ask`)
- `com.apple.developer.icloud-services` — enables CloudKit access
- `com.apple.security.network.client` — allows outbound network connections

If anything is missing, stop and show the user what needs to be fixed before proceeding.
