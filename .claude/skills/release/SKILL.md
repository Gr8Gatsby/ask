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

Wait for it to complete, then:
```bash
git checkout main
git pull
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

Run the Mac build script, passing the version and channel (do NOT run in background — stream output):

```bash
./scripts/build-release.sh {version} {channel}
```

This takes 10–20 minutes and:
1. Generates `AskMac.xcodeproj` via xcodegen
2. Archives + exports the app
3. Signs scripts with Developer ID
4. Builds component + distribution PKGs
5. Notarizes + staples the PKG
6. Creates installer and Sparkle DMGs
7. Notarizes + staples Sparkle DMG
8. Signs the Sparkle DMG and injects the entry into `docs/appcast.xml`:
   - For `alpha`/`beta`: entry includes `<sparkle:channel>{channel}</sparkle:channel>` — only users enrolled in that channel receive the auto-update
   - For `stable`: no channel tag — served to all users
9. Commits and pushes `docs/appcast.xml` to main
10. Creates a GitHub Release:
    - `alpha`/`beta`: marked as **prerelease** with title "AskMac v{version} ({channel})"
    - `stable`: standard release with title "AskMac v{version}"
    - Both DMGs attached; release notes taken from the annotated tag (`--notes-from-tag`)

**Known warning:** "Could not validate ticket / WARNING: stapler failed" may appear — this is a known macOS Tahoe issue. The build script guards against it and the artifacts are fully notarized.

If the build fails, diagnose and stop — do not proceed to the iOS upload.

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
  Artifacts: AskMac-{version}-installer.dmg, AskMac-{version}.dmg

iOS
  Tag: ios-v{version} pushed
  TestFlight upload complete — Apple processing (~10–30 min)
  Monitor: https://appstoreconnect.apple.com
    → {Distribute to internal testers (alpha) | external testers (beta) | submit for review (stable)}

CI: https://github.com/Gr8Gatsby/ask/actions
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

If anything is missing, stop and show the user what needs to be fixed before proceeding.
