---
name: build-pkg-mac
description: Build the AskMac .pkg installer locally — sign, notarize, create DMGs, update appcast, and publish GitHub Release. Run after /release-mac.
---

Build, sign, notarize, and publish the AskMac release artifacts by running `scripts/build-release.sh`. This is a local operation requiring Apple credentials and Developer ID certificates in Keychain.

## Step 1 — Verify prerequisites

Run these checks:

```bash
# Tools
command -v create-dmg && echo "create-dmg: OK" || echo "MISSING: brew install create-dmg"
command -v xcodegen && echo "xcodegen: OK"   || echo "MISSING: brew install xcodegen"
command -v gh && echo "gh: OK"               || echo "MISSING: brew install gh"
gh auth status 2>&1 | head -2

# Sparkle signing tool
ls sparkle/bin/sign_update 2>/dev/null && echo "sign_update: OK" || echo "MISSING — see note below"

# Apple credentials (loaded automatically from Keychain by the build script)
security find-generic-password -a "$USER" -s APPLE_ID -w &>/dev/null && echo "APPLE_ID: OK" || echo "MISSING"
security find-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w &>/dev/null && echo "APPLE_ID_PASSWORD: OK" || echo "MISSING"
security find-generic-password -a "$USER" -s APPLE_TEAM_ID -w &>/dev/null && echo "APPLE_TEAM_ID: OK" || echo "MISSING"

# Developer ID certs
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "MISSING"
security find-identity -v | grep "Developer ID Installer" || echo "MISSING"
```

**If Sparkle tools are missing:** Download `Sparkle-{version}.tar.xz` from github.com/sparkle-project/Sparkle/releases and extract to `sparkle/` in the repo root. Then run `./sparkle/bin/generate_keys` once — it stores the private key in Keychain and prints the public key. Add the public key to `AskMac/Sources/AskMac/Info.plist` as `SUPublicEDKey`.

**If Developer ID certs are missing:** Open Xcode → Settings → Accounts → your Apple ID → Manage Certificates → `+` → Developer ID Application + Developer ID Installer.

**If Apple credentials are missing:** Store them in Keychain (use an app-specific password from appleid.apple.com, not your account password):
```bash
security add-generic-password -a "$USER" -s APPLE_ID -w "your@apple.id"
security add-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w "xxxx-xxxx-xxxx-xxxx"
security add-generic-password -a "$USER" -s APPLE_TEAM_ID -w "B5J28L8ARB"
```

**Provisioning profile check** — The build requires a Developer ID provisioning profile for `com.kevinhill.askmac` with the `iCloud.simple.ask` container. Verify it's installed:
```bash
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
  name=$(security cms -D -i "$f" 2>/dev/null | grep -A1 '<key>Name</key>' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
  uuid=$(basename "$f" .provisionprofile)
  appid=$(security cms -D -i "$f" 2>/dev/null | grep -A1 'com.apple.application-identifier' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
  echo "UUID: $uuid | Name: $name | AppID: $appid"
done
```
You should see a line with `AppID: B5J28L8ARB.com.kevinhill.askmac`. The UUID in that line must match `PROVISIONING_PROFILE_SPECIFIER` in `AskMac/project.yml`.

**If the provisioning profile is missing or has the wrong UUID:**
1. Go to developer.apple.com → Certificates, Identifiers & Profiles
2. **Identifiers** → `com.kevinhill.askmac` → iCloud capability → Edit → check `iCloud.simple.ask` → Save
3. **Profiles** → AskMac (Developer ID Application) → Edit → Save → Download
4. Double-click the downloaded `.provisionprofile` to install it
5. Get the new UUID: `basename ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/$(ls -t ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile | head -1) .provisionprofile`
6. Update `PROVISIONING_PROFILE_SPECIFIER` in `AskMac/project.yml` and the `provisioningProfiles` dict in `AskMac/ExportOptions.plist` to match
7. Commit via PR before rebuilding

**Why this matters:** The app uses CloudKit (`iCloud.simple.ask`). Without a provisioning profile that explicitly authorizes this container, macOS calls `_os_crash` at launch — the app appears signed and notarized but silently crashes on open.

## Step 2 — Read the current version

```bash
grep 'MARKETING_VERSION' AskMac/project.yml | head -1
```

Extract the version string (e.g. `0.7.0`).

## Step 3 — Confirm with the user

Show:
```
Ready to build AskMac v{version}

This will run scripts/build-release.sh which:
  1. Generate AskMac.xcodeproj from project.yml (xcodegen)
  2. Archive + export AskMac.app via xcodebuild
  3. Bundle scripts from ask/scripts/ (excluding .build/ dirs)
  4. Sign any Mach-O binaries in bundled scripts with Developer ID
  5. Re-sign the app with Developer ID Application
  6. Build component PKGs (app + each script)
  7. Build distribution PKG (AskMac-{version}.pkg)
  8. Notarize + staple PKG
  9. Create installer DMG (AskMac-{version}-installer.dmg)
  10. Create Sparkle update DMG (AskMac-{version}.dmg)
  11. Notarize + staple Sparkle DMG
  12. Update docs/appcast.xml and push to main
  13. Create GitHub Release with both DMGs attached

Apple credentials are loaded automatically from Keychain.
This takes 10–20 minutes. Proceed? (yes/no)
```

Wait for explicit confirmation before continuing.

## Step 4 — Run the build script

```bash
./scripts/build-release.sh
```

Do not run in the background — stream output so the user can see progress.

**Known: stapling warning** — The build may print "Could not validate ticket / WARNING: stapler failed" and continue. This is a known macOS Tahoe issue where `xcrun stapler` modifies the file on failure, changing its hash. The build script guards against this with backup/restore. The artifacts are fully notarized and pass Gatekeeper with internet access at first launch.

**Other common failures:**
- **Notarization rejected (Invalid)** — fetch the detailed log: `xcrun notarytool log {submission-id} --apple-id ... --password ... --team-id ...`
- **`AskMac.xcodeproj does not exist`** — xcodegen not installed: `brew install xcodegen`
- **`sign_update: Signing key not found`** — run `./sparkle/bin/generate_keys`, add `SUPublicEDKey` to Info.plist
- **`AskMacCore.framework: bundle format unrecognized`** — project.yml has `AskMacCore` as `library.static`, not `framework`; regenerate with xcodegen
- **`No profiles for 'com.kevinhill.askmac' were found`** — provisioning profile not installed or UUID mismatch in project.yml; see provisioning profile check above
- **App installs but "can't be opened" on another Mac** — check crash log: `cat ~/Library/Logs/DiagnosticReports/AskMac-*.ips | head -60`. If crash shows `EXC_BREAKPOINT` + `_os_crash`, the provisioning profile is missing the `iCloud.simple.ask` container — go back to the Developer Portal and follow the provisioning profile steps above, then rebuild

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
