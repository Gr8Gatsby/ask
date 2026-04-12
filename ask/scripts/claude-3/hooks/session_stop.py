#!/usr/bin/env python3
"""
Claude Code Stop hook for claude-3.
Sends the final assistant message to the daemon so it can close the task feed.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claude-3.sock'))

data       = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd        = data.get('cwd', '') or os.getcwd()
last_text  = data.get('last_assistant_message', '').strip()

if not session_id:
    sys.exit(0)

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
    pass

sys.exit(0)
