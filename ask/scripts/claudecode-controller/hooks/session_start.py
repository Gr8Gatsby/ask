#!/usr/bin/env python3
"""
Claude Code SessionStart hook.
Registers the session early so the daemon knows about it before any tools fire.
Captures the TTY and Claude's PID at start time so routing is anchored to the
process, not the CWD (which can be shared across sessions).
"""
import sys
import json
import socket
import os
import subprocess

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')


def _get_tty_and_claude_pid():
    """Walk the process parent chain to find:
      - tty:       the controlling terminal (e.g. 's003')
      - claude_pid: the PID of the claude/node process that owns the session

    Returns (tty, claude_pid) — either may be None if not found.
    """
    tty = None
    claude_pid = None
    try:
        pid = os.getpid()
        for _ in range(10):
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'ppid=,tty=,comm='],
                capture_output=True, text=True, timeout=2
            )
            parts = r.stdout.strip().split(None, 2)
            if len(parts) < 2:
                break
            ppid_str = parts[0]
            tty_val = parts[1]
            comm = parts[2].strip() if len(parts) > 2 else ''

            # Capture first non-null TTY
            if tty_val not in ('??', '') and tty is None:
                tty = tty_val

            # Capture first process named 'claude' (Claude Code is Node/Electron)
            if claude_pid is None and 'claude' in comm.lower():
                claude_pid = pid

            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return tty, claude_pid


data = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd = os.getcwd()
project = os.path.basename(cwd)

if not session_id:
    sys.exit(0)

tty, claude_pid = _get_tty_and_claude_pid()

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
        'claude_pid': claude_pid,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
