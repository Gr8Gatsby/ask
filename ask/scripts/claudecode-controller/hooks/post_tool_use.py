#!/usr/bin/env python3
"""
Claude Code PostToolUse hook.
Notifies claudecode-controller that a tool ran so it can clear any pending
permission block that was waiting for a terminal response.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')


def _get_tty():
    """Walk the process parent chain to find the TTY of the terminal."""
    try:
        import subprocess
        pid = os.getpid()
        for _ in range(8):
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty='],
                capture_output=True, text=True, timeout=2
            )
            parts = r.stdout.strip().split()
            if len(parts) < 2:
                break
            ppid_str, tty = parts[0], parts[1]
            if tty not in ('??', ''):
                return tty  # e.g. "s003"
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


data = json.load(sys.stdin)
session_id = data.get('session_id', '')
tool_name = data.get('tool_name', '')
cwd = data.get('cwd', '')

if not session_id or not tool_name:
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'tool_executed',
        'session_id': session_id,
        'tool_name': tool_name,
        'cwd': cwd,
        'tty': _get_tty(),
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Claude if daemon is down

sys.exit(0)
