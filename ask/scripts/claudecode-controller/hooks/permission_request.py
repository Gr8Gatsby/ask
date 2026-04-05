#!/usr/bin/env python3
"""
Claude Code PermissionRequest hook.
Sends the permission request to claudecode-controller/main.py via Unix socket
and blocks until the user responds on iPhone (or 5-min timeout).
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')


def _get_tty():
    """Walk the process parent chain to find the TTY of the terminal."""
    try:
        import subprocess
        pid = os.getpid()
        for _ in range(8):
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty='],
                capture_output=True, text=True, timeout=2
            )
            parts = r.stdout.strip().split()
            if len(parts) < 2:
                break
            ppid_str, tty = parts[0], parts[1]
            if tty not in ('??', ''):
                return tty  # e.g. "s003"
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


data = json.load(sys.stdin)
tool = data.get('tool_name', 'Unknown')
session = data.get('session_id', '')
ti = data.get('tool_input', {})

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
preview = preview[:200]

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
        tool_name = rule.get('toolName', '')
        if rule_content and rule_content != tool_name:
            label = f'Always allow {tool_name}({rule_content})'
        else:
            label = f'Always allow {tool_name}'
    else:
        dest = s.get('destination', 'session')
        label = f'Always allow ({dest})'
    always_allow_labels.append(label)
    suggestions_map[label] = s

if always_allow_labels:
    options = ['Allow'] + always_allow_labels + ['Deny']
else:
    options = ['Yes', 'No']


def output_decision(decision):
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': decision
        }
    }))


# Send to daemon via socket
try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(None)  # wait indefinitely — user responds on iPhone when ready
    sock.connect(SOCKET_PATH)

    request = json.dumps({
        'type': 'permission_request',
        'tool': tool,
        'preview': preview,
        'options': options,
        'session_id': session,
        'suggestions': suggestions_map,
        'tty': _get_tty(),
    }).encode()
    sock.sendall(request)
    sock.shutdown(socket.SHUT_WR)

    # Read full response
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
    sock.close()

    response = json.loads(b''.join(chunks).decode())
    value = response.get('value', 'Deny')

except Exception as e:
    # Daemon not running — exit without a decision so Claude Code falls back
    # to its default console permission prompt.
    print(f'[permission_request] daemon not running, falling back to console: {e}', file=sys.stderr)
    sys.exit(0)

# Map value to Claude Code decision
if value in ('Allow', 'Yes'):
    output_decision({'behavior': 'allow'})
    sys.exit(0)
elif value in ('Deny', 'No'):
    output_decision({'behavior': 'deny', 'message': 'Permission denied by user on iPhone.'})
    sys.exit(2)
elif value in suggestions_map:
    output_decision({'behavior': 'allow', 'updatedPermissions': [suggestions_map[value]]})
    sys.exit(0)
else:
    # Unknown response — allow by default
    output_decision({'behavior': 'allow'})
    sys.exit(0)
