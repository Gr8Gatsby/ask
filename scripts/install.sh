#!/usr/bin/env bash
# Ask Scripts Installer
# Copies all scripts to ~/.ask/scripts/ and registers Claude Code hooks.
# Usage: ./install.sh [--dry-run]
#
# Run this on any machine where you want Ask scripts and Claude Code hooks
# installed — no AskMac PKG required.

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT="$HOME/.ask/scripts"
SDK="$SCRIPT_DIR/ask_sdk.py"

echo "==> Installing Ask scripts to $VAULT"
$DRY_RUN && echo "    (dry run — no changes will be made)"

# ── Deploy scripts ────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
    mkdir -p "$VAULT"
fi

# ask_sdk.py
if [[ -f "$SDK" ]]; then
    if ! $DRY_RUN; then cp "$SDK" "$VAULT/ask_sdk.py"; fi
    echo "  ✓ ask_sdk.py"
fi

# Each script directory
deployed=()
for script_dir in "$SCRIPT_DIR"/*/; do
    script_id="$(basename "$script_dir")"
    [[ -f "$script_dir/manifest.json" ]] || continue
    dest="$VAULT/$script_id"
    if ! $DRY_RUN; then
        rsync -a --delete "$script_dir" "$dest/"
    fi
    echo "  ✓ $script_id"
    deployed+=("$script_id")
done

# ── Register hooks ────────────────────────────────────────────────────────────
echo ""
echo "==> Registering hooks..."

any_setup=false
for script_dir in "$VAULT"/*/; do
    setup_py="$script_dir/setup.py"
    [[ -f "$setup_py" ]] || continue
    script_id="$(basename "$script_dir")"
    if ! $DRY_RUN; then
        PYTHONPATH="$VAULT" python3 "$setup_py" --install 2>&1 \
            | grep -v "^$" \
            | sed "s/^/  [$script_id] /"
    else
        echo "  [dry-run] would run: $setup_py --install"
    fi
    any_setup=true
done

if ! $any_setup; then
    echo "  (no scripts with setup.py found)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
    echo "Dry run complete. Re-run without --dry-run to apply."
else
    echo "✅ Done."
    echo ""
    echo "Next steps:"
    echo "  • If AskMac is running: Settings → Actions → ↺ (reload) next to each script"
    echo "  • If AskMac is not running: open it — scripts will load automatically"
    echo "  • Start a new Claude Code session to verify hooks fire"
fi
