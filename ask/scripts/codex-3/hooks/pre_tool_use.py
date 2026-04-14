#!/usr/bin/env python3
import fnmatch
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from _common import get_tmux_target, get_tty, send_event

ALLOWLIST_PATH = os.environ.get('ASK_CODEX3_ALLOWLIST_PATH', os.path.expanduser('~/.ask/codex3-allowlist.json'))
PERMISSION_MODE_PATH = os.environ.get('ASK_CODEX3_PERMISSION_MODE_PATH', os.path.expanduser('~/.ask/codex3-permission-mode.json'))


def check_allowlist(preview: str) -> bool:
    try:
        with open(ALLOWLIST_PATH) as handle:
            data = json.load(handle)
        for pattern in data.get('patterns', []):
            if '*' in pattern or '?' in pattern:
                if fnmatch.fnmatch(preview, pattern) or fnmatch.fnmatch(preview.split('\n')[0], pattern):
                    return True
            elif preview == pattern or preview.startswith(pattern + ' ') or preview.startswith(pattern + '\n'):
                return True
    except Exception:
        pass
    return False


data = json.load(sys.stdin)

try:
    with open(PERMISSION_MODE_PATH) as handle:
        if json.load(handle).get('mode', 'supervised') == 'full-auto':
            sys.exit(0)
except Exception:
    pass

permission_mode = data.get('permission_mode', '')
if permission_mode in ('auto-approve-everything', 'full-auto'):
    sys.exit(0)

tool = (data.get('tool') or data.get('tool_name') or 'Bash').strip() or 'Bash'
tool_input = data.get('tool_input', {})
if 'command' in tool_input:
    preview = tool_input['command']
elif 'file_path' in tool_input:
    preview = tool_input['file_path']
elif 'query' in tool_input:
    preview = tool_input['query']
else:
    preview = json.dumps(tool_input)
preview = preview[:500]

if check_allowlist(preview):
    sys.exit(0)

try:
    response = send_event({
        'type': 'permission_request',
        'session_id': data.get('session_id', ''),
        'cwd': data.get('cwd', '') or os.getcwd(),
        'tty': get_tty(),
        'tmux_target': get_tmux_target(),
        'tool': tool,
        'preview': preview,
        'options': ['Allow', 'Always Allow', 'Deny'],
    }, wait_response=True)
    value = response.get('value', 'Deny')
except Exception:
    sys.exit(0)

sys.exit(0 if value in ('Allow', 'Always Allow', 'Yes') else 2)
