# AskMac Distribution & Auto-Update — Design Document

## Overview

AskMac uses two distribution paths:

1. **First-time install:** A DMG containing a macOS installer PKG. The PKG uses Installer.app's native "Customize" step to let users opt-in to individual script components. All scripts are unchecked by default.
2. **Auto-updates:** Sparkle 2.x silently delivers a DMG containing just the `.app`. Script updates are detected by the app at launch and surfaced in the menu bar popover.

---

## Repository Layout (New Files)

```
installer/
  distribution.xml                    # productbuild distribution spec
  scripts/
    brew-monitor/postinstall          # payload-free postinstall per script
    claudecode-controller/postinstall
    codex-controller/postinstall
    github/postinstall
    ollama/postinstall

AskMac/
  project.yml                         # XcodeGen project spec
  ExportOptions.plist                 # xcodebuild Developer ID export config
  Sources/AskMac/
    Info.plist                        # Sparkle keys (SUFeedURL, SUPublicEDKey)
    AppUpdater.swift                  # SPUStandardUpdaterController wrapper
    Services/ScriptUpdateService.swift

docs/
  appcast.xml                         # Sparkle update feed
  design-installer.md                 # This document

scripts/
  build-release.sh                    # Local release build script

.github/workflows/
  release.yml                         # GitHub Actions release pipeline
```

---

## Xcode Project

AskMac was previously SPM-only. A proper Xcode project is required for:
- Hardened runtime (required for notarization)
- Code signing entitlements
- `xcodebuild archive` and `xcodebuild -exportArchive`

The project is generated from `AskMac/project.yml` using **XcodeGen**. The generated `.xcodeproj` should be committed so CI does not require XcodeGen at runtime.

**Two targets:**

| Target | Type | Sources |
|---|---|---|
| `AskMacCore` | Dynamic Framework | `Sources/AskMacCore/` |
| `AskMac` | Application | `Sources/AskMac/` |

`AskMac` embeds `AskMacCore.framework` and `Sparkle.framework`.

The SPM `Package.swift` remains valid for `swift build` / `swift test`.

---

## Script Bundling

Scripts are **not** added to the Xcode project as resources (to avoid maintaining two source locations). Instead, the build script copies them into the app bundle after `xcodebuild -exportArchive`:

```
AskMac.app/Contents/Resources/Scripts/
  brew-monitor/
    manifest.json  main.py  ...
  claudecode-controller/
    manifest.json  main.py  ...
  codex-controller/ ...
  github/ ...
  ollama/ ...
```

After copying, the app is **re-signed** (`codesign --force --deep`) because adding files to a signed bundle invalidates the original signature.

---

## PKG Installer Structure

```
AskMac-{version}.pkg  (productbuild distribution)
  AskMac-app.pkg             required — installs AskMac.app to /Applications
  script-brew-monitor.pkg    optional, unchecked — postinstall copies to vault
  script-claudecode-controller.pkg
  script-codex-controller.pkg
  script-github.pkg
  script-ollama.pkg
```

### Script component PKGs

Each script PKG is **payload-free** (`pkgbuild --nopayload`). Its postinstall script:
1. Finds the logged-in user via `stat -f "%Su" /dev/console`
2. Copies from `$2/Applications/AskMac.app/Contents/Resources/Scripts/{id}/` to `~/.ask/scripts/{id}/`
3. Sets ownership to the logged-in user

The `$2` argument to postinstall is the target volume root (normally `/`). The app PKG installs first (it's required and listed first in `choices-outline`), so the app bundle is present when script postinstall scripts run.

### Installer.app "Customize" step

The `distribution.xml` marks all script choices `start_selected="false"`. Users see the app pre-selected (disabled — cannot deselect) and all scripts unchecked.

---

## Release Artifacts

Each GitHub Release attaches two DMGs:

| Artifact | Contents | Purpose |
|---|---|---|
| `AskMac-{version}-installer.dmg` | `AskMac-{version}.pkg` | First-time installs via Installer.app |
| `AskMac-{version}.dmg` | `AskMac.app` | Sparkle auto-updates (drag-to-replace) |

Both are signed, notarized, and stapled.

---

## Sparkle Integration

### Version

Sparkle 2.x (≥ 2.6.0). Added as SPM dependency in both `Package.swift` and `project.yml`.

### Appcast

`docs/appcast.xml` is served via raw GitHub URL:
```
https://raw.githubusercontent.com/Gr8Gatsby/ask/main/docs/appcast.xml
```

Embedded in `Info.plist` as `SUFeedURL`. This URL is **permanent** — changing it breaks updates for existing installs.

The Sparkle appcast references `AskMac-{version}.dmg` (the .app-only DMG), not the installer DMG. Sparkle auto-updates replace only the app binary; scripts in the vault are not touched.

### EdDSA Signing (one-time setup)

```bash
# Download Sparkle release, then:
./bin/generate_keys
# → Prints public key → paste into Info.plist SUPublicEDKey
# → Stores private key in macOS Keychain under "ed25519"
```

For CI, the private key is stored as `SPARKLE_PRIVATE_KEY` (base64-encoded) and written to a temp file during the workflow, then deleted.

---

## Script Update Detection

`ScriptUpdateService` runs at each app launch:

1. Enumerates `Bundle.main.resourceURL/Scripts/` for bundled scripts
2. For each bundled script: reads `manifest.json` version
3. Checks `~/.ask/scripts/{id}/manifest.json` for the installed version
4. If bundled > installed (dot-separated numeric comparison): adds to `pendingUpdates`
5. If `pendingUpdates` is non-empty: sets `showUpdatePrompt = true`

The menu bar popover reads `ScriptUpdateService` from the environment and shows a banner with the update count and list. "Update All" calls `applyUpdates()`, which copies from the bundle to the vault and clears the pending list.

Scripts not present in the vault (user never installed them) are **not** shown as updates.

---

## Code Signing

### Certificates Required

| Certificate | Use |
|---|---|
| Developer ID Application | Signs `.app`, DMGs |
| Developer ID Installer | Signs component PKGs, distribution PKG |

Both must be present in the Keychain (local builds) or imported from the `DEVELOPER_ID_CERT_P12` secret (CI). The same P12 export should include both certificates.

### Hardened Runtime

`ENABLE_HARDENED_RUNTIME = YES` in `project.yml`. Required for notarization.

No App Sandbox — unnecessary for a tool app that runs user scripts.

### Entitlements

| Entitlement | Reason |
|---|---|
| `com.apple.developer.icloud-container-identifiers` | CloudKit container |
| `com.apple.developer.icloud-services` | CloudKit |
| `com.apple.security.network.client` | Outbound network (CloudKit) under hardened runtime |

---

## Release Pipeline

### Trigger

`git tag v1.0.0 && git push origin v1.0.0`

### Steps

1. Import Developer ID certificates from `DEVELOPER_ID_CERT_P12` secret
2. Install XcodeGen → `xcodegen generate`
3. `xcodebuild archive` + `xcodebuild -exportArchive` (Developer ID)
4. Copy scripts into app bundle → re-sign app
5. `pkgbuild` per component → `productbuild` distribution PKG
6. Notarize + staple PKG
7. Wrap PKG in installer DMG → sign DMG
8. Create Sparkle update DMG → sign → notarize → staple
9. Download Sparkle tools → sign update DMG → capture EdDSA signature
10. Update `docs/appcast.xml` with new entry → commit + push to main
11. `gh release create` with both DMGs attached

### GitHub Secrets Required

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded P12 (both Developer ID certs) |
| `CERT_P12_PASSWORD` | P12 export password |
| `APPLE_ID` | Apple ID email |
| `APPLE_ID_PASSWORD` | App-specific password (appleid.apple.com) |
| `APPLE_TEAM_ID` | `B5J28L8ARB` |
| `SPARKLE_PRIVATE_KEY` | Base64-encoded EdDSA private key from `generate_keys` |

---

## One-Time Local Setup

```bash
# Install tools
brew install xcodegen create-dmg

# Generate XcodeGen project (commit the result)
cd AskMac && xcodegen generate

# Generate Sparkle keys (once — store private key safely)
./sparkle/bin/generate_keys
# → Copy public key into AskMac/Sources/AskMac/Info.plist (SUPublicEDKey)

# Export P12 from Keychain Access:
#   Both "Developer ID Application: Kevin Hill (B5J28L8ARB)"
#   and  "Developer ID Installer: Kevin Hill (B5J28L8ARB)"
#   → Export as single .p12 → base64 encode → paste into DEVELOPER_ID_CERT_P12 secret
```
