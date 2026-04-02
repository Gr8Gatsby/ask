---
name: build-pkg-mac
description: Build the AskMac .pkg installer locally — sign, notarize, create DMGs, update appcast, and publish GitHub Release. Run after /release-mac.
---

Build, sign, notarize, and publish the AskMac release artifacts by running `scripts/build-release.sh`. This is a local operation — it requires Apple credentials and Developer ID certificates in your Keychain.

## Step 1 — Verify prerequisites

Check that all required tools and credentials are in place:

```bash
# Check required env vars
for var in APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
    echo "$var=${!var:-<NOT SET>}"
done

# Check required tools
command -v create-dmg && echo "create-dmg: OK" || echo "create-dmg: MISSING (brew install create-dmg)"
command -v gh && echo "gh: OK" || echo "gh: MISSING (brew install gh)"
gh auth status 2>&1 | head -3

# Check Sparkle signing tool
ls sparkle/bin/sign_update 2>/dev/null && echo "sign_update: OK" || echo "sign_update: MISSING"

# Check Developer ID certs
security find-identity -v -p codesigning | grep -E "Developer ID (Application|Installer)" || echo "No Developer ID certs found"
```

If any prerequisite is missing, stop and tell the user what to fix. Do not proceed until all are satisfied.

## Step 2 — Read the current version

```bash
grep 'MARKETING_VERSION' AskMac/project.yml | head -1
```

Extract the version string (e.g. `1.3.0`).

## Step 3 — Confirm with the user

Show:
```
Ready to build AskMac v{version}

This will run scripts/build-release.sh which:
  1. Archive + export AskMac.app via xcodebuild
  2. Bundle scripts from ask/scripts/
  3. Re-sign the app
  4. Build component PKGs (app + each script)
  5. Build distribution PKG (AskMac-{version}.pkg)
  6. Notarize + staple PKG
  7. Create installer DMG (AskMac-{version}-installer.dmg)
  8. Create Sparkle update DMG (AskMac-{version}.dmg)
  9. Notarize + staple Sparkle DMG
  10. Update docs/appcast.xml and push to main
  11. Create GitHub Release with both DMGs attached

This takes 10–20 minutes. Proceed? (yes/no)
```

Wait for explicit confirmation before continuing.

## Step 4 — Run the build script

```bash
./scripts/build-release.sh
```

Stream output to the user. Do not run it in the background — the user needs to see progress.

If it fails, show the error and stop. Common failures:
- **Code signing error** — cert not in Keychain or expired
- **Notarization timeout** — Apple servers slow; can retry
- **`APP_PATH not found`** — xcodebuild archive failed; check scheme name in AskMac/project.yml
- **`sign_update` not found** — Sparkle bin missing; download from GitHub releases

## Step 5 — Report

On success, show:
```
✅ AskMac v{version} released

Artifacts:
  build/AskMac-{version}-installer.dmg   (PKG installer)
  build/AskMac-{version}.dmg             (Sparkle auto-update)

GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v{version}
appcast.xml updated and pushed to main.
```
