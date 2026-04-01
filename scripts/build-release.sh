#!/usr/bin/env bash
# build-release.sh — Build, sign, notarize, and package AskMac for release.
#
# Produces two artifacts in build/:
#   AskMac-{VERSION}-installer.dmg  — DMG containing PKG installer (first-time installs)
#   AskMac-{VERSION}.dmg            — DMG containing .app only (Sparkle auto-updates)
#
# Usage:
#   ./scripts/build-release.sh [version]
#
# Prerequisites:
#   brew install create-dmg
#   Developer ID Application + Developer ID Installer certificates in Keychain
#   Sparkle tools at ./sparkle/bin/sign_update
#   Environment variables: APPLE_ID, APPLE_ID_PASSWORD, APPLE_TEAM_ID
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASKMAC_DIR="$REPO_ROOT/AskMac"
SCRIPTS_SRC="$REPO_ROOT/ask/scripts"
INSTALLER_DIR="$REPO_ROOT/installer"
BUILD_DIR="$REPO_ROOT/build"
SPARKLE_SIGN="$REPO_ROOT/sparkle/bin/sign_update"

SIGN_APP="Developer ID Application"
SIGN_PKG="Developer ID Installer"

# ── Version ────────────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(grep 'MARKETING_VERSION' "$ASKMAC_DIR/project.yml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi
BUILD_NUMBER="$(date +%s)"

echo "==> Building AskMac ${VERSION} (build ${BUILD_NUMBER})"

# ── Validate prerequisites ─────────────────────────────────────────────────────
for var in APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: \$$var is not set."
        exit 1
    fi
done
if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg not found. Run: brew install create-dmg"; exit 1
fi
if [[ ! -f "$SPARKLE_SIGN" ]]; then
    echo "ERROR: $SPARKLE_SIGN not found. Download Sparkle release and place bin/ at $REPO_ROOT/sparkle/"
    exit 1
fi

# ── Clean ─────────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/pkgs"

# ── Archive + export app ──────────────────────────────────────────────────────
echo "==> Archiving…"
xcodebuild archive \
    -project "$ASKMAC_DIR/AskMac.xcodeproj" \
    -scheme AskMac \
    -configuration Release \
    -archivePath "$BUILD_DIR/AskMac.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION"

echo "==> Exporting app bundle…"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/AskMac.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$ASKMAC_DIR/ExportOptions.plist"

APP_PATH="$BUILD_DIR/export/AskMac.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH not found"; exit 1; }

# ── Bundle scripts into app ────────────────────────────────────────────────────
echo "==> Bundling scripts into app…"
BUNDLE_SCRIPTS="$APP_PATH/Contents/Resources/Scripts"
mkdir -p "$BUNDLE_SCRIPTS"
for script_dir in "$SCRIPTS_SRC"/*/; do
    script_name="$(basename "$script_dir")"
    cp -r "$script_dir" "$BUNDLE_SCRIPTS/$script_name"
done

echo "==> Re-signing app after adding resources…"
codesign --force --deep \
    --sign "$SIGN_APP" \
    --timestamp \
    --options runtime \
    --entitlements "$ASKMAC_DIR/Sources/AskMac/AskMac.entitlements" \
    "$APP_PATH"

codesign --verify --verbose=2 "$APP_PATH"

# ── Build component PKGs ───────────────────────────────────────────────────────
echo "==> Building component PKGs…"

# App component
pkgbuild \
    --component "$APP_PATH" \
    --install-location /Applications \
    --sign "$SIGN_PKG" \
    "$BUILD_DIR/pkgs/AskMac-app.pkg"

# Script components (payload-free — postinstall copies from app bundle)
declare -A SCRIPT_VERSIONS
for script_dir in "$SCRIPTS_SRC"/*/; do
    script_name="$(basename "$script_dir")"
    version=$(python3 -c "import json; d=json.load(open('$script_dir/manifest.json')); print(d.get('version','1.0'))")
    SCRIPT_VERSIONS["$script_name"]="$version"

    pkgbuild \
        --nopayload \
        --scripts "$INSTALLER_DIR/scripts/$script_name" \
        --identifier "com.kevinhill.askmac.script.$script_name" \
        --version "$version" \
        --sign "$SIGN_PKG" \
        "$BUILD_DIR/pkgs/script-${script_name}.pkg"
done

# ── Build distribution PKG ────────────────────────────────────────────────────
echo "==> Building distribution PKG…"

# Substitute version placeholders in distribution.xml
DIST_XML="$BUILD_DIR/distribution.xml"
cp "$INSTALLER_DIR/distribution.xml" "$DIST_XML"
sed -i '' "s/ASKMAC_VERSION/$VERSION/g" "$DIST_XML"
sed -i '' "s/BREW_MONITOR_VERSION/${SCRIPT_VERSIONS[brew-monitor]:-1.0}/g" "$DIST_XML"
sed -i '' "s/CLAUDECODE_VERSION/${SCRIPT_VERSIONS[claudecode-controller]:-1.0}/g" "$DIST_XML"
sed -i '' "s/CODEX_VERSION/${SCRIPT_VERSIONS[codex-controller]:-1.0}/g" "$DIST_XML"
sed -i '' "s/GITHUB_VERSION/${SCRIPT_VERSIONS[github]:-1.0}/g" "$DIST_XML"
sed -i '' "s/OLLAMA_VERSION/${SCRIPT_VERSIONS[ollama]:-1.0}/g" "$DIST_XML"

PKG_PATH="$BUILD_DIR/AskMac-${VERSION}.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --package-path "$BUILD_DIR/pkgs" \
    --sign "$SIGN_PKG" \
    "$PKG_PATH"

# ── Notarize PKG ──────────────────────────────────────────────────────────────
echo "==> Notarizing PKG…"
xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

xcrun stapler staple "$PKG_PATH"

# ── Installer DMG (PKG inside) ────────────────────────────────────────────────
echo "==> Creating installer DMG…"
INSTALLER_DMG="$BUILD_DIR/AskMac-${VERSION}-installer.dmg"
mkdir -p "$BUILD_DIR/installer-contents"
cp "$PKG_PATH" "$BUILD_DIR/installer-contents/"
create-dmg \
    --volname "Install AskMac $VERSION" \
    --window-pos 200 120 \
    --window-size 500 300 \
    --icon-size 100 \
    --icon "AskMac-${VERSION}.pkg" 250 130 \
    "$INSTALLER_DMG" \
    "$BUILD_DIR/installer-contents/"
codesign --sign "$SIGN_APP" --timestamp "$INSTALLER_DMG"

# ── Sparkle update DMG (.app inside) ──────────────────────────────────────────
echo "==> Creating Sparkle update DMG…"
SPARKLE_DMG="$BUILD_DIR/AskMac-${VERSION}.dmg"
create-dmg \
    --volname "AskMac $VERSION" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "AskMac.app" 175 190 \
    --hide-extension "AskMac.app" \
    --app-drop-link 425 190 \
    "$SPARKLE_DMG" \
    "$BUILD_DIR/export/"
codesign --sign "$SIGN_APP" --timestamp "$SPARKLE_DMG"

# ── Notarize Sparkle DMG ──────────────────────────────────────────────────────
echo "==> Notarizing Sparkle DMG…"
xcrun notarytool submit "$SPARKLE_DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

xcrun stapler staple "$SPARKLE_DMG"

# ── Sparkle signature ─────────────────────────────────────────────────────────
echo "==> Generating Sparkle EdDSA signature…"
SIGNATURE=$("$SPARKLE_SIGN" "$SPARKLE_DMG")
FILE_SIZE=$(stat -f%z "$SPARKLE_DMG")

echo ""
echo "✅ Build complete"
echo "   Installer DMG : $INSTALLER_DMG"
echo "   Sparkle DMG   : $SPARKLE_DMG"
echo ""
echo "Add this entry to docs/appcast.xml:"
echo "────────────────────────────────────────────────────────────────"
cat <<APPCAST
<item>
  <title>Version ${VERSION}</title>
  <sparkle:version>${BUILD_NUMBER}</sparkle:version>
  <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
  <enclosure
    url="https://github.com/Gr8Gatsby/ask/releases/download/v${VERSION}/AskMac-${VERSION}.dmg"
    length="${FILE_SIZE}"
    type="application/octet-stream"
    sparkle:edSignature="${SIGNATURE}"
  />
</item>
APPCAST
echo "────────────────────────────────────────────────────────────────"
