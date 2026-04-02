#!/usr/bin/env python3
"""
Codex PreToolUse hook.
Sends the permission request to codex-controller/main.py via Unix socket
and blocks until the user responds on iPhone. Waits indefinitely.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-controller.sock'))

data = json.load(sys.stdin)
raw_tool = (data.get('tool') or data.get('tool_name') or '').strip()
session = data.get('session_id', '')
ti = data.get('tool_input', {})

# PreToolUse currently only fires for the Bash tool, but future Codex
# releases have shipped different casing / aliases (e.g. `tool_name`
# omitted entirely). Rather than guess, always surface the permission and
# fall back to a generic label if the tool name is blank. The iOS sheet still
# shows the command preview so the user knows what is being executed.
tool = raw_tool or 'Bash'

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

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(None)  # wait indefinitely
    sock.connect(SOCKET_PATH)

    request = json.dumps({
        'type': 'permission_request',
        'tool': tool,
        'preview': preview,
        'options': ['Allow', 'Deny'],
        'session_id': session,
    }).encode()
    sock.sendall(request)
    sock.shutdown(socket.SHUT_WR)

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
    print(f'[pre_tool_use] socket error: {e}', file=sys.stderr)
    # Daemon not running — allow by default so Codex isn't blocked
    sys.exit(0)

if value in ('Allow', 'Yes'):
    sys.exit(0)
else:
    print(f'Permission denied by user on iPhone.', file=sys.stderr)
    sys.exit(2)
