#!/usr/bin/env python3
"""
Codex Stop hook.
Notifies codex-controller that the session ended, with the last agent message.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-controller.sock'))

data = json.load(sys.stdin)

# Debug: dump raw hook data so we can identify the correct field names
import tempfile, time
try:
    with open(os.path.expanduser('~/.ask/codex_stop_debug.json'), 'w') as f:
        json.dump(data, f, indent=2, default=str)
except Exception:
    pass

session_id = data.get('session_id', '')
cwd = data.get('cwd', '')

if not session_id:
    sys.exit(0)

# Codex may provide the last agent message under various field names
last_text = (
    data.get('last_agent_message') or
    data.get('last_assistant_message') or
    data.get('last_message') or
    ''
).strip()

# Try nested response object formats
if not last_text:
    response_obj = data.get('response') or data.get('output') or {}
    if isinstance(response_obj, dict):
        last_text = (response_obj.get('text') or response_obj.get('message') or '').strip()
    elif isinstance(response_obj, str):
        last_text = response_obj.strip()

# Try items/output array (common in OpenAI-style APIs)
if not last_text:
    for key in ('items', 'output', 'messages'):
        items = data.get(key, [])
        if isinstance(items, list):
            for item in reversed(items):
                if isinstance(item, dict) and item.get('role') in ('assistant', 'agent'):
                    content = item.get('content') or item.get('text') or ''
                    if isinstance(content, list):
                        content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
                    if content:
                        last_text = content.strip()
                        break
            if last_text:
                break

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_stop',
        'session_id': session_id,
        'cwd': cwd,
        'last_message': last_text,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Codex if daemon is down

sys.exit(0)
