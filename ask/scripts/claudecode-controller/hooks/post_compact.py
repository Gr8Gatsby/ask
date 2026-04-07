#!/usr/bin/env python3
"""
Claude Code PostCompact hook.
Sends the compaction summary to the daemon.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
trigger    = data.get('trigger', 'auto')
summary    = data.get('summary', '').strip()[:1000]
cwd        = os.getcwd()

if not session_id or not summary:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'post_compact',
        'trigger': trigger,
        'summary': summary,
        'session_id': session_id,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
