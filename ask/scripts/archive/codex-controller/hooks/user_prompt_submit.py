#!/usr/bin/env python3
"""
Codex UserPromptSubmit hook.
Fires before each user prompt is sent to the model. Notifies
codex-controller so the session block shows is_working=True immediately,
before the first tool use arrives.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-controller.sock'))

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd = data.get('cwd', '')
prompt = data.get('prompt', '')

if not session_id:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'user_prompt_submit',
        'session_id': session_id,
        'cwd': cwd,
        'prompt': prompt,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Codex if daemon is down

sys.exit(0)
