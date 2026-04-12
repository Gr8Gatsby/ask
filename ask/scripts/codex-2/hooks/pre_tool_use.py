#!/usr/bin/env python3
"""
Codex PreToolUse hook.
Sends the permission request to codex-controller/main.py via Unix socket
and blocks until the user responds on iPhone. Waits indefinitely.
"""
import fnmatch
import sys
import json
import socket
import os
import subprocess

SOCKET_PATH           = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-2.sock'))
ALLOWLIST_PATH        = os.environ.get('ASK_CODEX2_ALLOWLIST_PATH', os.path.expanduser('~/.ask/codex_allowlist.json'))
PERMISSION_MODE_PATH  = os.environ.get('ASK_CODEX2_PERMISSION_MODE_PATH', os.path.expanduser('~/.ask/codex_permission_mode.json'))


def _check_allowlist(preview: str) -> bool:
    try:
        with open(ALLOWLIST_PATH) as f:
            data = json.load(f)
        for pattern in data.get('patterns', []):
            # Glob pattern if it contains wildcard characters
            if '*' in pattern or '?' in pattern:
                if fnmatch.fnmatch(preview, pattern) or fnmatch.fnmatch(preview.split('\n')[0], pattern):
                    return True
            else:
                # Exact-match or prefix-match (original behavior)
                if preview == pattern or preview.startswith(pattern + ' ') or preview.startswith(pattern + '\n'):
                    return True
    except Exception:
        pass
    return False


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
                return tty
            pid = int(ppid_str)
            if pid <= 1:
                break
    except Exception:
        pass
    return None


data = json.load(sys.stdin)

# Check our local permission mode override first.
try:
    with open(PERMISSION_MODE_PATH) as _f:
        _pm = json.load(_f).get('mode', 'supervised')
    if _pm == 'full-auto':
        sys.exit(0)
except Exception:
    pass

# Respect Codex's own approval mode — if the user launched Codex with
# --approval-policy auto-approve-everything (or similar), don't add our
# own gate on top.
permission_mode = data.get('permission_mode', '')
if permission_mode in ('auto-approve-everything', 'full-auto'):
    sys.exit(0)

raw_tool = (data.get('tool') or data.get('tool_name') or '').strip()
session = data.get('session_id', '')
ti = data.get('tool_input', {})

# PreToolUse currently only fires for the Bash tool, but future Codex
# releases have shipped different casing / aliases (e.g. `tool_name`
# omitted entirely). Rather than guess, always surface the permission and
# fall back to a generic label if the tool name is blank. The iOS sheet still
# shows the command preview so the user knows what is being executed.
tool = raw_tool or 'Bash'

# Build human-readable preview
if 'command' in ti:
    preview = ti['command']
elif 'file_path' in ti:
    preview = ti['file_path']
elif 'query' in ti:
    preview = ti['query']
elif 'description' in ti:
    preview = ti['description']
else:
    preview = json.dumps(ti)
preview = preview[:500]

# Auto-approve if the command matches a saved allowlist entry
if _check_allowlist(preview):
    sys.exit(0)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(None)  # wait indefinitely
    sock.connect(SOCKET_PATH)

    request = json.dumps({
        'type': 'permission_request',
        'tool': tool,
        'preview': preview,
        'options': ['Allow', 'Always Allow', 'Deny'],
        'session_id': session,
        'tty': _get_tty(),
        'cwd': data.get('cwd', '') or os.getcwd(),
        'tmux_target': _get_tmux_target(),
    }).encode()
    sock.sendall(request)
    sock.shutdown(socket.SHUT_WR)

    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
    sock.close()

    response = json.loads(b''.join(chunks).decode())
    value = response.get('value', '')

except Exception as e:
    print(f'[pre_tool_use] socket error: {e}', file=sys.stderr)
    # Daemon not running — allow by default so Codex isn't blocked
    sys.exit(0)

if value in ('Allow', 'Always Allow', 'Yes', ''):
    sys.exit(0)
else:
    print(f'Permission denied by user on iPhone.', file=sys.stderr)
    sys.exit(2)
