#!/usr/bin/env python3
"""
Claude Code UserPromptSubmit hook for claude-3.
Notifies the daemon when the user submits a prompt so it can record it in
the session's task feed.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claude-3.sock'))

data    = json.load(sys.stdin)
session = data.get('session_id', '')
message = data.get('prompt', '').strip()[:500]
cwd     = os.getcwd()

if not session or not message:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'user_prompt',
        'message': message,
        'session_id': session,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
