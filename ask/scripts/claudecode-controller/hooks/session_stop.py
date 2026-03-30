#!/usr/bin/env python3
"""
Claude Code Stop hook.
Notifies claudecode-controller/main.py that a session has ended.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')

if not session_id:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_stop',
        'session_id': session_id
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Claude if daemon is down

sys.exit(0)
