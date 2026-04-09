#!/usr/bin/env python3
"""
Codex Stop hook.
Fired when Codex finishes processing a task (returns to idle prompt).
This is NOT session termination — the session is still alive and accepting input.
We send session_active with is_working=False to mark it idle and surface the
last assistant message. Actual session cleanup happens when the PID dies
(detected by codex-2's heartbeat).
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-2.sock'))

data = json.load(sys.stdin)

session_id = data.get('session_id', '')
cwd = data.get('cwd', '')

if not session_id:
    sys.exit(0)

last_text = data.get('last_assistant_message', '').strip()

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_active',
        'session_id': session_id,
        'cwd': cwd,
        'last_message': last_text,
        'is_working': False,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Codex if daemon is down

sys.exit(0)
