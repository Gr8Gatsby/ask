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
