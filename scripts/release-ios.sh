#!/usr/bin/env bash
# release-ios.sh — Archive, export, and upload the iOS app to TestFlight.
#
# Usage:
#   ./scripts/release-ios.sh [version]
#
# Prerequisites:
#   Xcode with iOS Distribution certificate in Keychain
#   App Store provisioning profile installed in Xcode
#   App Store Connect API key at:
#     ~/.appstoreconnect/private_keys/AuthKey_{ASC_KEY_ID}.p8
#   Environment variables: ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/ios"

# ── Version ────────────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(grep 'MARKETING_VERSION' \
        "$REPO_ROOT/ask/ask.xcodeproj/project.pbxproj" | head -1 \
        | sed 's/.*= \(.*\);/\1/' | tr -d ' ')
fi
BUILD_NUMBER="$(date +%s)"

echo "==> Uploading iOS ${VERSION} (build ${BUILD_NUMBER}) to TestFlight"

# ── Validate prerequisites ─────────────────────────────────────────────────────
for var in ASC_KEY_ID ASC_ISSUER_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: \$$var is not set."
        exit 1
    fi
done

ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "ERROR: ASC API key not found at $ASC_KEY_PATH"
    echo "  Download it from App Store Connect > Users & Access > Keys"
    exit 1
fi

# ── Clean ─────────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ───────────────────────────────────────────────────────────────────
echo "==> Archiving…"
xcodebuild archive \
    -project "$REPO_ROOT/ask/ask.xcodeproj" \
    -scheme ask \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD_DIR/ask.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION"

# ── Export IPA ────────────────────────────────────────────────────────────────
echo "==> Exporting IPA…"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/ask.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$REPO_ROOT/ask/ExportOptions.plist"

IPA_PATH=$(find "$BUILD_DIR/export" -name "*.ipa" | head -1)
[[ -n "$IPA_PATH" ]] || { echo "ERROR: No IPA found in $BUILD_DIR/export"; exit 1; }

echo "==> IPA: $IPA_PATH"

# ── Upload to TestFlight ───────────────────────────────────────────────────────
echo "==> Uploading to TestFlight…"
xcrun altool --upload-app \
    --type ios \
    --file "$IPA_PATH" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    --private-key "@file:$ASC_KEY_PATH" \
    --verbose

echo ""
echo "✅ Upload complete — iOS v${VERSION} (build ${BUILD_NUMBER})"
echo "   Apple processes the build after upload (~10–30 min)."
echo "   Monitor: https://appstoreconnect.apple.com"
