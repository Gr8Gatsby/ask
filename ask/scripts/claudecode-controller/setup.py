#!/usr/bin/env python3
"""
claudecode-controller setup script.
Checks that the Claude Code CLI is installed and all hooks are registered
in ~/.claude/settings.json. Run with --install to fix any issues.
"""
import os
import sys
import json

# Make ask_sdk importable from the vault root (set by AskMac via PYTHONPATH)
import ask_sdk

SETTINGS_PATH = os.path.expanduser('~/.claude/settings.json')
HOOKS_DIR = os.path.dirname(os.path.abspath(__file__)) + '/hooks'

HOOK_MAP = {
    'PreToolUse':        'pre_tool_use.py',
    'PostToolUse':       'post_tool_use.py',
    'PermissionRequest': 'permission_request.py',
    'Notification':      'notification.py',
    'Stop':              'session_stop.py',
    'UserPromptSubmit':  'user_prompt_submit.py',
    'SessionStart':      'session_start.py',
    'PreCompact':        'pre_compact.py',
    'PostCompact':       'post_compact.py',
}


def _load_settings():
    if not os.path.exists(SETTINGS_PATH):
        return {}
    with open(SETTINGS_PATH) as f:
        return json.load(f)


def _hook_registered(settings, event, script_path):
    """Return True if script_path appears in any hook entry for the given event."""
    for block in settings.get('hooks', {}).get(event, []):
        for h in block.get('hooks', []):
            if script_path in h.get('command', ''):
                return True
    return False


def run_checks():
    ask_sdk.check_binary('claude-cli', 'Claude Code CLI', 'claude')

    settings = _load_settings()
    all_registered = True
    missing_events = []

    for event, filename in HOOK_MAP.items():
        script_path = os.path.join(HOOKS_DIR, filename)
        if not os.path.exists(script_path):
            continue  # hook not present in this version — skip
        if not _hook_registered(settings, event, script_path):
            all_registered = False
            missing_events.append(event)

    if all_registered:
        ask_sdk.check_ok('claude-hooks', 'Claude Code hooks', 'All hooks registered')
    else:
        ask_sdk.check_fail(
            'claude-hooks',
            'Claude Code hooks',
            f'Missing: {", ".join(missing_events)}',
            fixable=True,
            needs_terminal=False,
        )


def run_install():
    ask_sdk.step('Loading ~/.claude/settings.json…')
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)

    settings = _load_settings()
    settings.setdefault('hooks', {})

    registered = []
    skipped = []

    for event, filename in HOOK_MAP.items():
        script_path = os.path.join(HOOKS_DIR, filename)
        if not os.path.exists(script_path):
            skipped.append(event)
            continue

        if _hook_registered(settings, event, script_path):
            skipped.append(event)
            continue

        # Find or create the matcher='' block for this event
        existing = settings['hooks'].setdefault(event, [])
        target = next((b for b in existing if b.get('matcher') == ''), None)
        if target is None:
            target = {'matcher': '', 'hooks': []}
            existing.append(target)

        target.setdefault('hooks', [])
        # Remove any stale claudecode-controller entries
        target['hooks'] = [
            h for h in target['hooks']
            if 'claudecode-controller' not in h.get('command', '')
        ]
        target['hooks'].append({'type': 'command', 'command': script_path})
        registered.append(event)

    with open(SETTINGS_PATH, 'w') as f:
        json.dump(settings, f, indent=4)

    if registered:
        ask_sdk.step(f'Registered hooks: {", ".join(registered)}')
    if skipped:
        ask_sdk.step(f'Already registered or not present: {", ".join(skipped)}')

    ask_sdk.done('Claude Code hooks are configured')


def run_uninstall():
    ask_sdk.step('Removing claudecode-controller hooks from ~/.claude/settings.json…')
    if not os.path.exists(SETTINGS_PATH):
        ask_sdk.done('No settings file found — nothing to remove')
        return

    settings = _load_settings()
    removed = []

    for event in list(settings.get('hooks', {}).keys()):
        blocks = settings['hooks'][event]
        for block in blocks:
            before = len(block.get('hooks', []))
            block['hooks'] = [
                h for h in block.get('hooks', [])
                if 'claudecode-controller' not in h.get('command', '')
            ]
            if len(block['hooks']) < before:
                removed.append(event)
        # Drop empty matcher blocks
        settings['hooks'][event] = [b for b in blocks if b.get('hooks')]
        if not settings['hooks'][event]:
            del settings['hooks'][event]

    if not settings.get('hooks'):
        settings.pop('hooks', None)

    with open(SETTINGS_PATH, 'w') as f:
        json.dump(settings, f, indent=4)

    if removed:
        ask_sdk.step(f'Removed hooks: {", ".join(set(removed))}')
    ask_sdk.done('Claude Code hooks removed')


if __name__ == '__main__':
    ask_sdk.main(check_fn=run_checks, install_fn=run_install, uninstall_fn=run_uninstall)
