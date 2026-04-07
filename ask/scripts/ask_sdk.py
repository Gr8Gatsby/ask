"""
ask_sdk.py — Helper module for Ask script setup scripts.

Usage in setup.py:
    import ask_sdk

    def run_checks():
        token = ask_sdk.get_config("github_token")
        if token:
            ask_sdk.check_ok("GitHub token", "Token is configured")
        else:
            ask_sdk.check_fail("GitHub token", "Not configured",
                               fixable=True, needs_terminal=False)

    def run_install():
        ask_sdk.step("Installing dependencies...")
        # ... do work ...
        ask_sdk.done("Setup complete")

AskMac calls:
    python3 setup.py --check    → prints JSON to stdout, exit 0
    python3 setup.py --install  → prints progress lines, exit 0 or non-zero
"""

from __future__ import annotations

import os
import sys
import json
import subprocess
from typing import Optional

# ── Config access ─────────────────────────────────────────────────────────────

def get_config(key: str) -> Optional[str]:
    """
    Return the stored value for a config key, or None if not set.
    AskMac injects config values as ASK_CONFIG_<KEY_UPPERCASED> env vars.
    """
    env_key = f"ASK_CONFIG_{key.upper()}"
    return os.environ.get(env_key)


def require_config(key: str) -> str:
    """Return the stored value for a config key, raising if not set."""
    value = get_config(key)
    if value is None:
        raise RuntimeError(f"Required config '{key}' is not set")
    return value

# ── Check result accumulator ──────────────────────────────────────────────────

_checks: list[dict] = []

def check_ok(id: str, label: str, message: str = "OK"):
    """Record a passing check."""
    _checks.append({
        "id": id,
        "label": label,
        "ok": True,
        "message": message,
    })


def check_fail(id: str, label: str, message: str,
               fixable: bool = True, needs_terminal: bool = False):
    """Record a failing check."""
    _checks.append({
        "id": id,
        "label": label,
        "ok": False,
        "message": message,
        "fixable": fixable,
        "needs_terminal": needs_terminal,
    })


def emit_checks():
    """
    Print the collected checks as JSON and exit.
    Called automatically at the end of --check mode if you use run_checks().
    """
    print(json.dumps({"checks": _checks}))
    sys.exit(0)

# ── Install-mode helpers ───────────────────────────────────────────────────────

def step(message: str):
    """Print a progress line during --install. AskMac streams these to the UI."""
    print(f"→ {message}", flush=True)


def done(message: str = "Setup complete"):
    """Print a completion message and exit 0."""
    print(f"✓ {message}", flush=True)
    sys.exit(0)


def fail(message: str):
    """Print a failure message and exit non-zero."""
    print(f"✗ {message}", flush=True, file=sys.stderr)
    sys.exit(1)

# ── Shell helpers ──────────────────────────────────────────────────────────────

def run(cmd: str, capture: bool = False) -> subprocess.CompletedProcess:
    """Run a shell command. Raises on non-zero exit."""
    return subprocess.run(
        cmd, shell=True, check=True,
        capture_output=capture, text=True,
        env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", "")},
    )


def which(binary: str) -> Optional[str]:
    """Return full path to binary, or None if not found.
    Searches common user install locations that GUI apps miss because they
    don't source ~/.zshrc / ~/.bashrc.
    """
    home = os.path.expanduser('~')
    extra = ':'.join([
        f'{home}/.local/bin',
        f'{home}/bin',
        f'{home}/.opencode/bin',
        f'{home}/.npm-global/bin',
        '/opt/homebrew/bin',
        '/opt/homebrew/sbin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
    ])
    augmented_path = extra + ':' + os.environ.get('PATH', '')
    try:
        result = subprocess.run(
            ['which', binary], capture_output=True, text=True,
            env={**os.environ, 'PATH': augmented_path},
        )
        path = result.stdout.strip()
        return path if path else None
    except Exception:
        return None


def check_binary(id: str, label: str, binary: str) -> bool:
    """Convenience: record ok/fail for a binary being present in PATH."""
    path = which(binary)
    if path:
        check_ok(id, label, f"Found at {path}")
        return True
    else:
        check_fail(id, label, f"'{binary}' not found in PATH", fixable=True, needs_terminal=False)
        return False


def check_json_key(id: str, label: str, path: str, *keys) -> bool:
    """
    Check that a JSON file exists and contains a nested key path.
    keys is a sequence of dict keys to traverse, e.g. ("hooks", "PreToolUse").
    Returns True if the value at that path is truthy.
    """
    expanded = os.path.expanduser(path)
    if not os.path.exists(expanded):
        check_fail(id, label, f"File not found: {path}", fixable=True, needs_terminal=False)
        return False
    try:
        with open(expanded) as f:
            data = json.load(f)
        val = data
        for k in keys:
            if not isinstance(val, dict) or k not in val:
                check_fail(id, label, f"Missing key '{k}' in {path}", fixable=True, needs_terminal=False)
                return False
            val = val[k]
        if val:
            check_ok(id, label)
            return True
        else:
            check_fail(id, label, f"Key is empty in {path}", fixable=True, needs_terminal=False)
            return False
    except Exception as e:
        check_fail(id, label, f"Error reading {path}: {e}", fixable=True, needs_terminal=False)
        return False

# ── Entry point helper ─────────────────────────────────────────────────────────

def main(check_fn, install_fn, uninstall_fn=None):
    """
    Wire up --check / --install / --uninstall dispatch. Call at the bottom of setup.py:

        if __name__ == "__main__":
            ask_sdk.main(check_fn=run_checks, install_fn=run_install, uninstall_fn=run_uninstall)
    """
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode == "--check":
        check_fn()
        emit_checks()
    elif mode == "--install":
        install_fn()
    elif mode == "--uninstall":
        if uninstall_fn is not None:
            uninstall_fn()
        # If no uninstall_fn provided, exit cleanly — nothing to undo
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)
