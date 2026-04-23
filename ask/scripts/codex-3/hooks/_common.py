#!/usr/bin/env python3
import json
import os
import socket
import subprocess
from typing import Optional


SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-3.sock'))


def get_tmux_target() -> str:
    tmux_pane = os.environ.get('TMUX_PANE', '')
    if not tmux_pane:
        return ''
    try:
        result = subprocess.run(
            ['tmux', 'display-message', '-p', '-t', tmux_pane, '#{session_name}:#{window_name}.#{pane_index}'],
            capture_output=True, text=True, timeout=2,
        )
        return result.stdout.strip() if result.returncode == 0 else ''
    except Exception:
        return ''


def get_tty() -> Optional[str]:
    try:
        pid = os.getpid()
        for _ in range(8):
            result = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty='],
                capture_output=True, text=True, timeout=2,
            )
            parts = result.stdout.strip().split()
            if len(parts) < 2:
                break
            ppid_str, tty = parts[0], parts[1]
            if tty not in ('??', ''):
                return tty
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


def send_event(payload: dict, wait_response: bool = False) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(None if wait_response else 5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps(payload).encode())
    sock.shutdown(socket.SHUT_WR)
    if not wait_response:
        sock.close()
        return {}
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
    sock.close()
    return json.loads(b''.join(chunks).decode() or '{}')
