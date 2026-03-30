#!/usr/bin/env python3
"""
Claude Code Notification hook.

If Claude is waiting for user input, updates the persistent chat_prompt block
with that context (fire-and-forget — does not block Claude Code).

All other notifications emit a transient alert block.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

# Only intercept notifications whose title is exactly one of these.
WAITING_TITLES = {
    'claude is waiting for your input',
    'waiting for your input',
}

# Suppress these — they duplicate blocks already shown by the PermissionRequest hook.
SKIP_TITLE_FRAGMENTS = {
    'needs your permission',
    'requesting permission',
}


def _should_skip(title: str) -> bool:
    t = title.strip().lower()
    return any(fragment in t for fragment in SKIP_TITLE_FRAGMENTS)

data = json.load(sys.stdin)
title = data.get('title', data.get('message', 'Claude Code'))
body = data.get('message', data.get('body', ''))

is_waiting = title.strip().lower() in WAITING_TITLES

if _should_skip(title):
    sys.exit(0)


def send(payload, timeout=5):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload, ensure_ascii=False).encode())
        sock.shutdown(socket.SHUT_WR)
        # Drain any response
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        sock.close()
    except Exception as e:
        print(f'[notification] socket error: {e}', file=sys.stderr)


if is_waiting:
    # Update the persistent chat block with context — returns immediately
    send({
        'type': 'chat_prompt',
        'title': 'Reply to Claude',
        'context': body if body and body.strip().lower() != title.strip().lower() else '',
    })
else:
    send({
        'type': 'notification',
        'title': title,
        'body': body,
    })

sys.exit(0)
