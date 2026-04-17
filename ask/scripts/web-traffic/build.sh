#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v zig &>/dev/null; then
    echo "ERROR: Zig not found. Install with: brew install zig" >&2
    exit 1
fi

echo "Zig $(zig version)"
echo "Building web-traffic-parser…"

zig build -Doptimize=ReleaseSafe

BINARY="$SCRIPT_DIR/zig-out/bin/web-traffic-parser"
DEST="$SCRIPT_DIR/web-traffic-parser"

cp "$BINARY" "$DEST"
codesign --sign - --force "$DEST"
echo "✓ Built and signed: $DEST"
