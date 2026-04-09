#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building brew-monitor (Swift)…"
swift build -c release 2>&1

BINARY=".build/release/brew-monitor"
DEST="$SCRIPT_DIR/brew-monitor-bin"

cp "$BINARY" "$DEST"
codesign --sign - --force "$DEST"
echo "Built and signed $DEST"
