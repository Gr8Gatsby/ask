#!/usr/bin/env bash
# build-dev.sh — Fast dev build of AskMac.app for testing on another Mac.
#
# Produces: build/AskMac-dev.zip
#
# The app is signed with Developer ID but NOT notarized.
# To open on another Mac: right-click → Open, or run:
#   xattr -cr AskMac.app && open AskMac.app
#
# Usage:
#   ./scripts/build-dev.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASKMAC_DIR="$REPO_ROOT/AskMac"
BUILD_DIR="$REPO_ROOT/build/dev"

echo "==> Generating Xcode project…"
if ! command -v xcodegen &>/dev/null; then
    echo "ERROR: xcodegen not found — brew install xcodegen"; exit 1
fi
(cd "$ASKMAC_DIR" && xcodegen generate)

# Guard: xcodegen can blank out the entitlements file
ENTITLEMENTS="$ASKMAC_DIR/Sources/AskMac/AskMac.entitlements"
if ! grep -q "icloud-container-identifiers" "$ENTITLEMENTS"; then
    echo "==> Restoring CloudKit entitlements (xcodegen blanked them)…"
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

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/archive" "$BUILD_DIR/export"

echo "==> Archiving…"
xcodebuild archive \
    -project "$ASKMAC_DIR/AskMac.xcodeproj" \
    -scheme AskMac \
    -configuration Release \
    -archivePath "$BUILD_DIR/archive/AskMac.xcarchive" \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=Developer ID Application: Kevin Hill (B5J28L8ARB)" \
    CODE_SIGN_ENTITLEMENTS="$ASKMAC_DIR/Sources/AskMac/AskMac.entitlements" \
    | grep -E '^(Build|Archive|error:)'

echo "==> Exporting .app…"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/archive/AskMac.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$ASKMAC_DIR/ExportOptions.plist" \
    | grep -E '^(Export|error:)'

APP="$BUILD_DIR/export/AskMac.app"
if [[ ! -d "$APP" ]]; then
    echo "ERROR: AskMac.app not found after export"; exit 1
fi

echo "==> Zipping…"
cd "$BUILD_DIR/export"
zip -qr "$REPO_ROOT/build/AskMac-dev.zip" AskMac.app

echo ""
echo "✅ Done: build/AskMac-dev.zip"
echo ""
echo "Transfer to the other Mac, then:"
echo "  unzip AskMac-dev.zip"
echo "  xattr -cr AskMac.app"
echo "  open AskMac.app"
echo ""
echo "Or just right-click → Open to bypass Gatekeeper."
