#!/usr/bin/env python3
"""
Codex PostToolUse hook.
Notifies codex-controller that a tool ran so it can clear any pending
permission block that was waiting for a terminal response.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-controller.sock'))

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
tool_name = data.get('tool', data.get('tool_name', ''))
cwd = data.get('cwd', '')

if not session_id or not tool_name:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'tool_executed',
        'session_id': session_id,
        'tool_name': tool_name,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Codex if daemon is down

sys.exit(0)
