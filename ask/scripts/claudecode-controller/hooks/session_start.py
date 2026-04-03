#!/usr/bin/env python3
"""
Claude Code SessionStart hook.
Registers the session early so the daemon knows about it before any tools fire.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd        = os.getcwd()
project    = os.path.basename(cwd)

if not session_id:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_start',
        'session_id': session_id,
        'cwd': cwd,
        'project': project,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
