#!/usr/bin/env python3
"""
Claude Code PreCompact hook.
Notifies the daemon that context compaction is about to start.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
trigger    = data.get('trigger', 'auto')
cwd        = os.getcwd()

if not session_id:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'pre_compact',
        'trigger': trigger,
        'session_id': session_id,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
