#!/usr/bin/env python3
"""
Codex PostToolUse hook.
Fires after every tool use. Notifies codex-controller so it can trigger
a response capture and clear any pending permission block.
"""
import sys
import json
import socket
import os
import subprocess

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-2.sock'))


def _get_tmux_target():
    """Return 'session:window.pane' for the current tmux pane, or ''."""
    tmux_pane = os.environ.get('TMUX_PANE', '')
    if not tmux_pane:
        return ''
    try:
        r = subprocess.run(
            ['tmux', 'display-message', '-p', '-t', tmux_pane,
             '#{session_name}:#{window_index}.#{pane_index}'],
            capture_output=True, text=True, timeout=2,
        )
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


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
tool_name = data.get('tool', data.get('tool_name', ''))
cwd = data.get('cwd', '')
last_message = (data.get('last_assistant_message') or '').strip()[:400]

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
        'tmux_target': _get_tmux_target(),
        'last_message': last_message,
    }).encode())
    sock.close()
except Exception:
    pass  # Don't block Codex if daemon is down

sys.exit(0)
