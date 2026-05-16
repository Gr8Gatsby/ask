#!/usr/bin/env python3
"""
Claude Code SessionStart hook for claude-3.
Registers the session early so the daemon knows about it before any tools fire.
Captures the TTY and Claude's PID at start time so routing is anchored to the
process, not the CWD (which can be shared across sessions).
"""
import sys
import json
import os
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon


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


def _get_tmux_target() -> str:
    """Return the tmux target for the pane running this hook, e.g. 'ask:@31'.

    tmux sets TMUX_PANE (e.g. '%12') when running inside a tmux pane.
    We resolve that to the session:@window_id format the daemon uses.
    """
    pane_id = os.environ.get('TMUX_PANE', '')
    if not pane_id:
        return ''
    try:
        r = subprocess.run(
            ['tmux', 'display-message', '-t', pane_id, '-p',
             '#{session_name}:#{window_id}'],
            capture_output=True, text=True, timeout=2,
        )
        return r.stdout.strip()
    except Exception:
        return ''


data = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd = os.getcwd()
project = os.path.basename(cwd)

if not session_id:
    sys.exit(0)

tty = _get_tty()
tmux_target = _get_tmux_target()

send_to_daemon({
    'type': 'session_start',
    'session_id': session_id,
    'cwd': cwd,
    'project': project,
    'tty': tty,
    'tmux_target': tmux_target,
})

sys.exit(0)
