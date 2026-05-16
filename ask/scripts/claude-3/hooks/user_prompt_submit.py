#!/usr/bin/env python3
"""
Claude Code UserPromptSubmit hook for claude-3.
Notifies the daemon when the user submits a prompt so it can record it in
the session's task feed.  Also sends tty/cwd so the daemon can backfill
routing info if the session was recreated after an eviction.
"""
import sys
import json
import os
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon


def _tty_name_to_short(path: str) -> str:
    name = os.path.basename(path)
    if name.startswith('tty'):
        name = name[3:]
    return name


def _get_tty():
    tty_env = os.environ.get('TTY', '')
    if tty_env and os.path.exists(tty_env):
        return _tty_name_to_short(tty_env)
    for fd in (0, 1, 2):
        try:
            return _tty_name_to_short(os.ttyname(fd))
        except Exception:
            pass
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


data    = json.load(sys.stdin)
session = data.get('session_id', '')
message = data.get('prompt', '').strip()[:500]
cwd     = os.getcwd()

if not session or not message:
    sys.exit(0)

tty = _get_tty()
tmux_target = _get_tmux_target()

send_to_daemon({
    'type': 'user_prompt',
    'message': message,
    'session_id': session,
    'cwd': cwd,
    'tty': tty,
    'tmux_target': tmux_target,
})

sys.exit(0)
