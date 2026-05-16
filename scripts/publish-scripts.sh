#!/bin/bash
# publish-scripts.sh — regenerate scripts-latest catalog.json + per-script zips
# and replace the assets on the scripts-latest GitHub release. Also force-moves
# the scripts-latest tag to HEAD so AskMac's catalog fetch sees the new state.
#
# Usage:
#   ./scripts/publish-scripts.sh "Release blurb shown in each catalog entry"
#
# The catalog blurb is optional but recommended — AskMac shows it as the
# update changelog for every script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/ask/scripts"
BUILD_DIR="$REPO_ROOT/build/scripts-publish"
TAG="scripts-latest"
RELEASE_NAME="Scripts (latest)"

CHANGELOG="${1:-}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build per-script zips and assemble catalog entries
echo "==> Building zips + catalog"
catalog_entries=()
for script_dir in "$SCRIPTS_DIR"/*/; do
    manifest="$script_dir/manifest.json"
    [[ -f "$manifest" ]] || continue
    id=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$manifest")
    version=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$manifest")
    echo "  $id $version"

    # Zip script dir (exclude .build, __pycache__)
    zip_path="$BUILD_DIR/$id.zip"
    (cd "$script_dir" && zip -qr "$zip_path" . -x "*.pyc" "__pycache__/*" ".build/*" "*.xcodeproj/*")

    # Generate catalog entry
    entry_json=$(python3 - "$manifest" "$id" "$CHANGELOG" <<'PY'
import json, os, sys
manifest_path, sid, changelog = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(manifest_path))
script_dir = os.path.dirname(manifest_path)

# Inline the icon SVG so catalog entries are fully self-contained
svg = ''
icon_file = m.get('icon_file', '')
if icon_file:
    svg_path = os.path.join(script_dir, icon_file)
    if os.path.isfile(svg_path):
        svg = open(svg_path).read()

entry = {
    'id': m['id'],
    'name': m.get('name', m['id']),
    'version': m['version'],
    'description': m.get('description', ''),
    'icon': m.get('icon', ''),
    'type': m.get('type', 'tile'),
    'download_url': f"https://github.com/Gr8Gatsby/ask/releases/download/scripts-latest/{sid}.zip",
}
if changelog:
    entry['changelog'] = changelog
if svg:
    entry['svg'] = svg
if m.get('permissions'):
    entry['permissions'] = m['permissions']
if m.get('requires'):
    entry['requires'] = m['requires']

print(json.dumps(entry))
PY
)
    catalog_entries+=("$entry_json")
done

# Assemble final catalog.json
echo "==> Assembling catalog.json"
python3 - "$BUILD_DIR" "${catalog_entries[@]}" <<'PY'
import json, sys, datetime
build_dir = sys.argv[1]
entries = [json.loads(e) for e in sys.argv[2:]]
catalog = {
    'generated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'scripts': entries,
}
with open(f'{build_dir}/catalog.json', 'w') as f:
    json.dump(catalog, f, indent=2)
print(f'  {len(entries)} entries')
PY

# Force-move scripts-latest tag to HEAD
echo "==> Moving scripts-latest tag to HEAD"
git tag -f scripts-latest
git push origin scripts-latest --force

# Replace the release. gh doesn't have an atomic "replace all assets" so we
# delete the release (keeping the tag we just moved) and recreate it.
echo "==> Replacing GitHub release"
gh release delete scripts-latest --yes --cleanup-tag=false 2>/dev/null || true
gh release create scripts-latest \
    --title "$RELEASE_NAME" \
    --notes "${CHANGELOG:-Latest scripts published from $(git rev-parse --short HEAD).}" \
    "$BUILD_DIR"/*.zip "$BUILD_DIR/catalog.json"

echo "==> Published. Catalog URL:"
echo "    https://github.com/Gr8Gatsby/ask/releases/download/scripts-latest/catalog.json"
