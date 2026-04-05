#!/usr/bin/env python3
"""
codex-controller setup script.
Checks that the Codex CLI is installed and hooks are configured in ~/.codex/config.toml.
Run with --install to fix any issues.
"""
from __future__ import annotations

import os
import sys
import json

import ask_sdk
from typing import Optional

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__)) + '/hooks'
CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')

# Hooks codex-controller needs registered in ~/.codex/config.toml
HOOK_MAP = {
    'pre_tool_call':  'pre_tool_use.py',
    'post_tool_call': 'post_tool_use.py',
}

# Extended PATH that covers nvm, homebrew, npm global installs


def _latest_nvm_node() -> str:
    nvm_dir = os.path.expanduser('~/.nvm/versions/node')
    if not os.path.isdir(nvm_dir):
        return ''
    versions = sorted(os.listdir(nvm_dir))
    return versions[-1] if versions else ''


def _codex_path() -> Optional[str]:
    """Find codex binary across common install locations."""
    node_ver = _latest_nvm_node()
    search_paths = [
        os.path.expanduser(f'~/.nvm/versions/node/{node_ver}/bin') if node_ver else '',
        os.path.expanduser('~/.local/bin'),
        os.path.expanduser('~/.npm-global/bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
    ]
    for directory in search_paths:
        if not directory:
            continue
        candidate = os.path.join(directory, 'codex')
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ask_sdk.which('codex')


def _hook_registered(event: str, script_path: str) -> bool:
    """Check if a hook is present in ~/.codex/config.toml."""
    if not os.path.exists(CODEX_CONFIG_PATH):
        return False
    try:
        # Simple line-based search — avoids toml parser dependency
        target = f'"{script_path}"'
        with open(CODEX_CONFIG_PATH) as f:
            content = f.read()
        return target in content or script_path in content
    except Exception:
        return False


def _register_hook_in_toml(event: str, script_path: str):
    """Append a hook entry to ~/.codex/config.toml."""
    os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
    entry = f'\n[[{event}]]\ncmd = ["{sys.executable}", "{script_path}"]\n'
    with open(CODEX_CONFIG_PATH, 'a') as f:
        f.write(entry)


def run_checks():
    codex = _codex_path()
    if codex:
        ask_sdk.check_ok('codex-cli', 'Codex CLI', f'Found at {codex}')
    else:
        ask_sdk.check_fail(
            'codex-cli',
            'Codex CLI',
            'Not installed — run: npm install -g @openai/codex',
            fixable=True,
            needs_terminal=False,
        )

    all_ok = True
    missing = []
    for event, filename in HOOK_MAP.items():
        script_path = os.path.join(HOOKS_DIR, filename)
        if not os.path.exists(script_path):
            continue
        if not _hook_registered(event, script_path):
            all_ok = False
            missing.append(event)

    if all_ok:
        ask_sdk.check_ok('codex-hooks', 'Codex hooks', 'All hooks registered')
    else:
        ask_sdk.check_fail(
            'codex-hooks',
            'Codex hooks',
            f'Missing: {", ".join(missing)}',
            fixable=True,
            needs_terminal=False,
        )


def run_install():
    # Install Codex if missing
    codex = _codex_path()
    if not codex:
        ask_sdk.step('Installing Codex CLI via npm…')
        try:
            ask_sdk.run('npm install -g @openai/codex')
            ask_sdk.step('Codex installed')
        except Exception as e:
            ask_sdk.fail(f'Failed to install Codex: {e}')

    # Register hooks in ~/.codex/config.toml
    ask_sdk.step('Registering Codex hooks…')
    registered = []
    for event, filename in HOOK_MAP.items():
        script_path = os.path.join(HOOKS_DIR, filename)
        if not os.path.exists(script_path):
            continue
        if _hook_registered(event, script_path):
            continue
        _register_hook_in_toml(event, script_path)
        registered.append(event)

    if registered:
        ask_sdk.step(f'Registered: {", ".join(registered)}')
    else:
        ask_sdk.step('Hooks already registered')

    ask_sdk.done('Codex controller is configured')


if __name__ == '__main__':
    ask_sdk.main(check_fn=run_checks, install_fn=run_install)
