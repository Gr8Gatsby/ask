#!/usr/bin/env python3
"""
Claude Code Stop hook.
Emits the last Claude response as a claude_message block via the daemon.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

data = json.load(sys.stdin)
session_id = data.get('session_id', '')

# Debug log — records the raw payload keys and transcript length
LOG_PATH = os.path.expanduser('~/.ask/logs/session_stop_debug.log')
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
with open(LOG_PATH, 'a') as f:
    transcript_raw = data.get('transcript', [])
    f.write(f"session_id={session_id} keys={list(data.keys())} transcript_len={len(transcript_raw)}\n")
    if transcript_raw:
        last = transcript_raw[-1]
        f.write(f"  last_msg role={last.get('role')} content_type={type(last.get('content')).__name__}\n")

if not session_id:
    sys.exit(0)

# Claude Code provides the last assistant message directly in the payload
last_text = data.get('last_assistant_message', '').strip()

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_stop',
        'session_id': session_id,
        'last_message': last_text,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Claude if daemon is down

sys.exit(0)
