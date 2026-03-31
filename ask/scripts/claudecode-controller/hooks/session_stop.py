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

if not session_id:
    sys.exit(0)

# Extract the last assistant message text from the transcript
last_text = ''
transcript = data.get('transcript', [])
for msg in reversed(transcript):
    if msg.get('role') != 'assistant':
        continue
    content = msg.get('content', '')
    if isinstance(content, str):
        last_text = content.strip()
    elif isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                t = block.get('text', '').strip()
                if t:
                    parts.append(t)
        last_text = '\n\n'.join(parts).strip()
    if last_text:
        break

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
