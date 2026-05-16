#!/usr/bin/env python3
"""
Claude Code PermissionRequest hook for claude-3.
Sends the permission request to the daemon via Unix socket and exits immediately.
Claude Code shows its native terminal prompt; the daemon surfaces the card on
iPhone in parallel. Whichever path the user responds through first wins.
"""
import sys
import json
import os
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon


def _get_tty():
    try:
        pid = os.getpid()
        for _ in range(8):
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty='],
                capture_output=True, text=True, timeout=2,
            )
            parts = r.stdout.strip().split()
            if len(parts) < 2:
                break
            ppid_str, tty = parts[0], parts[1]
            if tty not in ('??', ''):
                return tty
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


data = json.load(sys.stdin)
tool    = data.get('tool_name', 'Unknown')
session = data.get('session_id', '')
ti      = data.get('tool_input', {})

# Build human-readable preview
if 'command' in ti:
    preview = ti['command']
elif 'file_path' in ti:
    preview = ti['file_path']
elif 'query' in ti:
    preview = ti['query']
elif 'description' in ti:
    preview = ti['description']
else:
    preview = json.dumps(ti)
preview = preview[:500]

# Build option list from permission_suggestions
suggestions_map = {}
always_allow_labels = []
for s in data.get('permission_suggestions', []):
    if s.get('behavior') != 'allow':
        continue
    rules = s.get('rules', [])
    if rules:
        rule = rules[0]
        rule_content = rule.get('ruleContent', '')
        tool_name    = rule.get('toolName', '')
        label = (f'Always allow {tool_name}({rule_content})'
                 if rule_content and rule_content != tool_name
                 else f'Always allow {tool_name}')
    else:
        dest  = s.get('destination', 'session')
        label = f'Always allow ({dest})'
    always_allow_labels.append(label)
    suggestions_map[label] = s

if always_allow_labels:
    options = ['Allow'] + always_allow_labels + ['Deny']
else:
    options = ['Yes', 'No']


# Single attempt with a short timeout — this hook is user-blocking: it
# fires synchronously before Claude Code shows the terminal prompt, so a
# multi-retry helper would make the prompt visibly hang under daemon load.
# If delivery fails, the native terminal prompt still works.
send_to_daemon(
    {
        'type': 'permission_request',
        'tool': tool,
        'preview': preview,
        'options': options,
        'session_id': session,
        'suggestions': suggestions_map,
        'tty': _get_tty(),
    },
    max_attempts=1,
    timeout=0.5,
)

# Exit with no decision output — Claude Code shows its native terminal prompt.
# If the user responds on iPhone, the daemon injects the response via tmux.
sys.exit(0)
