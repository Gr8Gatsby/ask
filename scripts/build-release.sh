#!/usr/bin/env bash
# build-release.sh — Build, sign, notarize, package, and publish AskMac.
#
# Produces two artifacts and creates a GitHub Release:
#   AskMac-{VERSION}-installer.dmg  — DMG containing PKG (first-time installs)
#   AskMac-{VERSION}.dmg            — DMG containing .app (Sparkle auto-updates)
#
# Usage:
#   ./scripts/build-release.sh [version]
#
# Prerequisites:
#   brew install create-dmg gh
#   Developer ID Application + Developer ID Installer certs in Keychain
#   Sparkle tools at ./sparkle/bin/sign_update
#   Environment variables: APPLE_ID, APPLE_ID_PASSWORD, APPLE_TEAM_ID
#   gh CLI authenticated: gh auth status
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASKMAC_DIR="$REPO_ROOT/AskMac"
SCRIPTS_SRC="$REPO_ROOT/ask/scripts"
INSTALLER_DIR="$REPO_ROOT/installer"
BUILD_DIR="$REPO_ROOT/build"
SPARKLE_SIGN="$REPO_ROOT/sparkle/bin/sign_update"

SIGN_APP="Developer ID Application"
SIGN_PKG="Developer ID Installer"

# Staple with backup/restore to prevent xcrun stapler from corrupting the file
# on failure (it modifies the file even when it fails, invalidating the hash).
# Retries up to 3 times with 15s delay for CDN propagation. Warns but continues
# on persistent failure — notarization alone is sufficient for Gatekeeper.
staple_with_retry() {
    local file="$1"
    local backup="${file}.pre-staple-backup"
    cp "$file" "$backup"
    for i in 1 2 3; do
        cp "$backup" "$file"
        xcrun stapler staple "$file" && rm -f "$backup" && return 0
        echo "    Staple attempt $i failed, retrying in 15s…"
        sleep 15
    done
    cp "$backup" "$file"
    rm -f "$backup"
    echo "WARNING: stapler failed for $(basename "$file") — file restored to pre-staple state."
    echo "         Notarization was accepted; Gatekeeper will verify online at first launch."
}

# ── Version ────────────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(grep 'MARKETING_VERSION' "$ASKMAC_DIR/project.yml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi
BUILD_NUMBER="$(date +%s)"

echo "==> Building AskMac ${VERSION} (build ${BUILD_NUMBER})"

# ── Load Apple credentials from Keychain if not already set ───────────────────
for var in APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!var:-}" ]]; then
        val=$(security find-generic-password -a "$USER" -s "$var" -w 2>/dev/null || true)
        if [[ -n "$val" ]]; then
            export "$var"="$val"
            echo "==> Loaded $var from Keychain"
        fi
    fi
done

# ── Validate prerequisites ─────────────────────────────────────────────────────
for var in APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: \$$var is not set and not found in Keychain."
        echo "  Store it with: security add-generic-password -a \"\$USER\" -s $var -w \"value\""
        exit 1
    fi
done
if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg not found. Run: brew install create-dmg"; exit 1
fi
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh not found. Run: brew install gh && gh auth login"; exit 1
fi
if [[ ! -f "$SPARKLE_SIGN" ]]; then
    echo "ERROR: $SPARKLE_SIGN not found."
    echo "  Download Sparkle from https://github.com/sparkle-project/Sparkle/releases"
    echo "  and place the bin/ directory at $REPO_ROOT/sparkle/"
    exit 1
fi

# ── Clean ─────────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/pkgs"

# ── Generate Xcode project ────────────────────────────────────────────────────
echo "==> Generating Xcode project from project.yml…"
if ! command -v xcodegen &>/dev/null; then
    echo "ERROR: xcodegen not found. Run: brew install xcodegen"; exit 1
fi
(cd "$ASKMAC_DIR" && xcodegen generate)

# Guard: xcodegen can overwrite entitlements with an empty file if run in certain states.
ENTITLEMENTS="$ASKMAC_DIR/Sources/AskMac/AskMac.entitlements"
if ! grep -q "icloud-container-identifiers" "$ENTITLEMENTS"; then
    echo "ERROR: xcodegen overwrote AskMac.entitlements — restoring CloudKit entitlements."
    cat > "$ENTITLEMENTS" << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.simple.ask</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudKit</string>
	</array>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
ENTEOF
fi

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
    dest="$BUNDLE_SCRIPTS/$(basename "$script_dir")"
    rsync -a --exclude='.build' --exclude='*.xcodeproj' "$script_dir" "$dest/"
done

echo "==> Signing bundled binaries…"
find "$BUNDLE_SCRIPTS" -type f | while read -r bin; do
    if file "$bin" | grep -q "Mach-O"; then
        echo "    Signing $bin"
        codesign --force \
            --sign "$SIGN_APP" \
            --timestamp \
            --options runtime \
            "$bin"
    fi
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

pkgbuild \
    --component "$APP_PATH" \
    --install-location /Applications \
    --sign "$SIGN_PKG" \
    "$BUILD_DIR/pkgs/AskMac-app.pkg"

for script_dir in "$SCRIPTS_SRC"/*/; do
    script_name="$(basename "$script_dir")"
    version=$(python3 -c \
        "import json; d=json.load(open('$script_dir/manifest.json')); print(d.get('version','1.0'))")
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
DIST_XML="$BUILD_DIR/distribution.xml"
cp "$INSTALLER_DIR/distribution.xml" "$DIST_XML"

get_ver() {
    python3 -c "import json; d=json.load(open('$SCRIPTS_SRC/$1/manifest.json')); print(d.get('version','1.0'))"
}
sed -i '' "s/ASKMAC_VERSION/$VERSION/g"                       "$DIST_XML"
sed -i '' "s/BREW_MONITOR_VERSION/$(get_ver brew-monitor)/g"  "$DIST_XML"
sed -i '' "s/CLAUDECODE_VERSION/$(get_ver claudecode-controller)/g" "$DIST_XML"
sed -i '' "s/CODEX_VERSION/$(get_ver codex-controller)/g"     "$DIST_XML"
sed -i '' "s/GITHUB_VERSION/$(get_ver github)/g"              "$DIST_XML"
sed -i '' "s/OLLAMA_VERSION/$(get_ver ollama)/g"              "$DIST_XML"

PKG_PATH="$BUILD_DIR/AskMac-${VERSION}.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --package-path "$BUILD_DIR/pkgs" \
    --sign "$SIGN_PKG" \
    "$PKG_PATH"

# ── Notarize + staple PKG ─────────────────────────────────────────────────────
echo "==> Notarizing PKG…"
xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
staple_with_retry "$PKG_PATH"

# ── Installer DMG ─────────────────────────────────────────────────────────────
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

# ── Sparkle update DMG ────────────────────────────────────────────────────────
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

echo "==> Notarizing Sparkle DMG…"
xcrun notarytool submit "$SPARKLE_DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
staple_with_retry "$SPARKLE_DMG"

# ── Sparkle signature ─────────────────────────────────────────────────────────
echo "==> Generating Sparkle EdDSA signature…"
# sign_update outputs: sparkle:edSignature="BASE64" length="SIZE"
# Extract just the base64 signature value for embedding in appcast XML.
SIGN_OUTPUT=$("$SPARKLE_SIGN" "$SPARKLE_DMG")
SIGNATURE=$(echo "$SIGN_OUTPUT" | sed 's/.*edSignature="\([^"]*\)".*/\1/')
FILE_SIZE=$(stat -f%z "$SPARKLE_DMG")

# ── Update appcast ────────────────────────────────────────────────────────────
echo "==> Updating appcast.xml…"
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')
DMG_NAME="AskMac-${VERSION}.dmg"

python3 - <<PYEOF
with open('docs/appcast.xml', 'r') as f:
    content = f.read()
new_item = """    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="https://github.com/Gr8Gatsby/ask/releases/download/v${VERSION}/${DMG_NAME}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
      />
    </item>"""
marker = '    <!-- Release entries are prepended here by the release pipeline -->'
content = content.replace(marker, marker + '\n' + new_item)
with open('docs/appcast.xml', 'w') as f:
    f.write(content)
PYEOF

git add docs/appcast.xml
git commit -m "chore(release): update appcast for v${VERSION}"
git push origin main

# ── Publish GitHub Release ────────────────────────────────────────────────────
echo "==> Creating GitHub Release v${VERSION}…"
gh release create "v${VERSION}" \
    --title "AskMac v${VERSION}" \
    --notes-from-tag \
    "$INSTALLER_DMG" \
    "$SPARKLE_DMG"

echo ""
echo "✅ Release complete"
echo "   Installer DMG : $INSTALLER_DMG"
echo "   Sparkle DMG   : $SPARKLE_DMG"
echo "   GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v${VERSION}"
