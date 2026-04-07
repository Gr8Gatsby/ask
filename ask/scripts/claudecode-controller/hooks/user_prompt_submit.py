#!/usr/bin/env python3
"""
Claude Code UserPromptSubmit hook.
Notifies the daemon when the user submits a prompt.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
message    = data.get('prompt', '').strip()[:500]
cwd        = os.getcwd()

if not session_id or not message:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'user_prompt',
        'message': message,
        'session_id': session_id,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
