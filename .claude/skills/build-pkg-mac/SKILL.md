---
name: build-pkg-mac
description: Build the AskMac .pkg installer locally — sign, notarize, create DMGs, update appcast, publish GitHub Release, and trigger CI stapling. Run after /release-mac.
---

Build, sign, notarize, and publish the AskMac release artifacts by running `scripts/build-release.sh`. This is a local operation requiring Apple credentials and Developer ID certificates in Keychain.

## Step 1 — Verify prerequisites

Run these checks silently, report failures only:

```bash
# Tools
command -v create-dmg && echo "create-dmg: OK" || echo "MISSING: brew install create-dmg"
command -v xcodegen && echo "xcodegen: OK"   || echo "MISSING: brew install xcodegen"
command -v gh && echo "gh: OK"               || echo "MISSING: brew install gh"
gh auth status 2>&1 | head -2

# Sparkle signing tool
ls sparkle/bin/sign_update 2>/dev/null && echo "sign_update: OK" || echo "MISSING — see note below"

# Apple credentials
security find-generic-password -a "$USER" -s APPLE_ID -w &>/dev/null && echo "APPLE_ID: OK" || echo "MISSING"
security find-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w &>/dev/null && echo "APPLE_ID_PASSWORD: OK" || echo "MISSING"
security find-generic-password -a "$USER" -s APPLE_TEAM_ID -w &>/dev/null && echo "APPLE_TEAM_ID: OK" || echo "MISSING"

# Developer ID certs
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "MISSING: Developer ID Application cert"
security find-identity -v | grep "Developer ID Installer" || echo "MISSING: Developer ID Installer cert"
```

**If Sparkle tools are missing:** Download `Sparkle-{version}.tar.xz` from github.com/sparkle-project/Sparkle/releases and extract to `sparkle/` in the repo root. Then run `./sparkle/bin/generate_keys` once — it stores the private key in Keychain and prints the public key. Add the public key to `AskMac/Sources/AskMac/Info.plist` as `SUPublicEDKey`.

**If Developer ID certs are missing:** Open Xcode → Settings → Accounts → your Apple ID → Manage Certificates → `+` → Developer ID Application + Developer ID Installer.

**If Apple credentials are missing:** Store them in Keychain (use an app-specific password from appleid.apple.com):
```bash
security add-generic-password -a "$USER" -s APPLE_ID -w "your@apple.id"
security add-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w "xxxx-xxxx-xxxx-xxxx"
security add-generic-password -a "$USER" -s APPLE_TEAM_ID -w "B5J28L8ARB"
```

**Provisioning profile check** — The cert embedded in the profile must match the cert in Keychain. Run using Python (shell pipelines are unreliable here):

```bash
KEYCHAIN_FP=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | cut -d= -f2)
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
  appid=$(security cms -D -i "$f" 2>/dev/null | grep -A1 'com.apple.application-identifier' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
  [[ "$appid" != *"com.kevinhill.askmac"* ]] && continue
  uuid=$(basename "$f" .provisionprofile)
  PROFILE_FP=$(security cms -D -i "$f" 2>/dev/null | python3 -c "
import sys, plistlib, subprocess, tempfile, os
data = sys.stdin.buffer.read()
plist = plistlib.loads(data)
for cert in plist.get('DeveloperCertificates', []):
    with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as tmp:
        tmp.write(bytes(cert)); tmp_path = tmp.name
    r = subprocess.run(['openssl','x509','-inform','DER','-fingerprint','-sha256','-noout','-in',tmp_path], capture_output=True, text=True)
    os.unlink(tmp_path)
    print(r.stdout.strip().split('=',1)[1])
")
  MATCH=$([[ "$PROFILE_FP" == "$KEYCHAIN_FP" ]] && echo "✓ MATCH" || echo "✗ MISMATCH")
  echo "UUID: $uuid | $MATCH"
done
```

Profile must show `✓ MATCH`. If `✗ MISMATCH`, regenerate the profile in the Developer Portal.

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

## Step 3 — Run the build script

Run (stream output, do not background):
```bash
./scripts/build-release.sh 2>&1 | tee /tmp/build-mac-{version}.log | grep -E "^==>|✅|❌|SUCCEEDED|FAILED|error:"
```

On failure, read `tail -50 /tmp/build-mac-{version}.log` and report the error. Do not proceed to staple.

The build does:
1. Generate AskMac.xcodeproj from project.yml (xcodegen)
2. Archive + export AskMac.app via xcodebuild
3. Bundle scripts from ask/scripts/ (excluding .build/ dirs)
4. Sign any Mach-O binaries in bundled scripts with Developer ID
5. Re-sign the app with Developer ID Application
6. Build component PKGs (app + each script)
7. Build distribution PKG (AskMac-{version}.pkg)
8. Notarize + staple PKG
9. Create installer DMG (AskMac-{version}-installer.dmg)
10. Notarize + staple installer DMG
11. Create Sparkle update DMG (AskMac-{version}.dmg) — **not stapled locally** (see note)
12. Sign Sparkle DMG with EdDSA and update docs/appcast.xml
13. Commit and push appcast.xml to main
14. Create GitHub Release with all artifacts

**Note on Sparkle DMG stapling:** The Sparkle DMG is NOT stapled locally or by CI. Sparkle validates via EdDSA signature (in appcast.xml), not staple tickets. Stapling after signing would change the DMG hash and invalidate the EdDSA signature — since the Ed25519 private key lives only in the local Keychain, re-signing on CI is impossible. The DMG passes Gatekeeper at first launch via online notarization check.

**Known: stapling warning** — The build may print "Could not validate ticket / WARNING: stapler failed" and continue. This is a known macOS Tahoe (26) issue. The build script guards against hash changes with backup/restore.

**Other common failures:**
- **Notarization rejected (Invalid)** — fetch the detailed log: `xcrun notarytool log {submission-id} --apple-id ... --password ... --team-id ...`
- **`AskMac.xcodeproj does not exist`** — xcodegen not installed: `brew install xcodegen`
- **`sign_update: Signing key not found`** — run `./sparkle/bin/generate_keys`, add `SUPublicEDKey` to Info.plist
- **`No profiles for 'com.kevinhill.askmac' were found`** — provisioning profile not installed or UUID mismatch in project.yml; see provisioning profile check above
- **App installs but "can't be opened" on another Mac** — check crash log for `EXC_BREAKPOINT` + `_os_crash`: provisioning profile is missing the `iCloud.simple.ask` container — regenerate profile in Developer Portal and rebuild

## Step 4 — Trigger staple workflow

After the build succeeds and the GitHub Release is created:

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

The staple workflow runs on macOS 15 (Sequoia) and staples the PKG and installer DMG. It does NOT staple the Sparkle DMG (by design — see note above).

## Step 5 — Report

```
✅ AskMac v{version} released

Artifacts:
  build/AskMac-{version}-installer.dmg   (PKG installer)
  build/AskMac-{version}.dmg             (Sparkle auto-update)

GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v{version}
appcast.xml updated and pushed to main.
Sparkle auto-update is now live for all users.
```

