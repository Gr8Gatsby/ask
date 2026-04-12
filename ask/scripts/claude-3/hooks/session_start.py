#!/usr/bin/env python3
"""
Claude Code SessionStart hook for claude-3.
Registers the session early so the daemon knows about it before any tools fire.
Captures the TTY and Claude's PID at start time so routing is anchored to the
process, not the CWD (which can be shared across sessions).
"""
import sys
import json
import socket
import os
import subprocess

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claude-3.sock'))


def _tty_name_to_short(path: str) -> str:
    """Convert /dev/ttys003 or ttys003 → s003."""
    name = os.path.basename(path)
    if name.startswith('tty'):
        name = name[3:]
    return name


def _get_tty():
    # 1. Environment variable — set by the shell and inherited by Claude Code.
    tty_env = os.environ.get('TTY', '')
    if tty_env and os.path.exists(tty_env):
        return _tty_name_to_short(tty_env)

    # 2. os.ttyname() on standard file descriptors.
    for fd in (0, 1, 2):
        try:
            return _tty_name_to_short(os.ttyname(fd))
        except Exception:
            pass

    # 3. Walk parent-process chain via ps.
    try:
        pid = os.getpid()
        for _ in range(10):
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty=,comm='],
                capture_output=True, text=True, timeout=2,
            )
            parts = r.stdout.strip().split(None, 2)
            if len(parts) < 2:
                break
            ppid_str, tty_val = parts[0], parts[1]
            if tty_val not in ('??', ''):
                return tty_val
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


data = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd = os.getcwd()
project = os.path.basename(cwd)

if not session_id:
    sys.exit(0)

tty = _get_tty()

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'session_start',
        'session_id': session_id,
        'cwd': cwd,
        'project': project,
        'tty': tty,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
