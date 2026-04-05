#!/usr/bin/env python3
"""
test_local.py — interactive local test harness for terminal-manager.

Spawns main.py as a subprocess, registers the current terminal (or a given TTY),
then enters an interactive loop where you can call any tool and see the response.

Usage:
    python3 test_local.py                   # auto-detect TTY
    python3 test_local.py /dev/ttys007      # specific TTY
    python3 test_local.py --tmux myses:0    # tmux pane

Commands at the prompt:
    r              — detect_tui (run all patterns, show match)
    R              — read_output (show last 30 lines of session)
    ls             — list_sessions
    k <key>        — send_key (up/down/enter/escape/space/ctrl_c/ctrl_u)
    t <text>       — send_text (Ctrl+U, type, Enter)
    raw <text>     — send_raw
    q              — quit
"""

import sys
import json
import os
import subprocess
import threading
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── Codex hook config ────────────────────────────────────────────────────────

CODEX_HOOK = {
    'scan_lines': 80,
    'patterns': [
        {
            'id': 'numbered_menu',
            'detect': {
                'type': 'numbered_menu',
                'footers': ['Press enter to confirm', 'esc to go back'],
            },
        },
        {
            'id': 'slash_commands',
            'detect': {
                'type': 'slash_command_list',
                'commands': [
                    {'cmd': '/model',        'desc': 'choose model and reasoning effort'},
                    {'cmd': '/fast',         'desc': 'toggle Fast mode'},
                    {'cmd': '/permissions',  'desc': 'choose what Codex is allowed to do'},
                    {'cmd': '/experimental', 'desc': 'toggle experimental features'},
                    {'cmd': '/skills',       'desc': 'use skills to improve Codex'},
                    {'cmd': '/review',       'desc': 'review changes and find issues'},
                    {'cmd': '/rename',       'desc': 'rename the current thread'},
                    {'cmd': '/new',          'desc': 'start a new chat'},
                ],
            },
        },
        {
            'id': 'toggle_menu',
            'detect': {
                'type': 'checkbox_menu',
                'footers': ['Press space to select', 'enter to save'],
            },
        },
        {
            'id': 'screen_metadata',
            'detect': {'type': 'screen_metadata'},
        },
    ],
}

# ── OpenCode hook config ──────────────────────────────────────────────────────
# OpenCode is a full-screen alt-screen TUI. We use read_mode='contents' to
# read the current visible screen instead of the scrollback buffer.
# Patterns below are based on the observed UI — update as we discover more.

OPENCODE_HOOK = {
    'scan_lines': 200,
    'patterns': [
        # Interactive prompts checked first
        {
            'id': 'yn_prompt',
            'detect': {'type': 'keyword_match', 'keywords': ['[y/n]']},
        },
        {
            'id': 'command_palette',
            'detect': {'type': 'keyword_match', 'keywords': ['commands', 'ctrl+p']},
        },
        # Always-runs: extract all visible UI metadata
        {
            'id': 'screen_metadata',
            'detect': {'type': 'screen_metadata'},
        },
    ],
}


def find_all_terminal_processes():
    """Return list of (label, target) for interesting running processes.

    target is either a /dev/ttysN path or 'tmux:session:window.pane'.
    """
    TARGETS = ['codex', 'claude', 'opencode', 'node']
    r = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
    found = {}  # target -> label (dedup)

    # TTY-based processes
    for line in r.stdout.splitlines():
        low = line.lower()
        if 'test_local' in low or 'grep' in low or 'python' in low:
            continue
        for name in TARGETS:
            if name in low:
                pid = line.split()[1]
                cmd_parts = line.split()[10:]
                label = ' '.join(cmd_parts)[:60]
                lsof = subprocess.run(
                    ['lsof', '-p', pid, '-a', '-d', '0'],
                    capture_output=True, text=True,
                )
                for ll in lsof.stdout.splitlines():
                    if '/dev/tty' in ll:
                        for part in ll.split():
                            if part.startswith('/dev/tty') and part not in found:
                                found[part] = f'{name}: {label}'
                break

    # tmux panes
    try:
        r2 = subprocess.run(
            ['tmux', 'list-panes', '-a',
             '-F', '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'],
            capture_output=True, text=True, timeout=3,
        )
        for line in r2.stdout.splitlines():
            parts = line.split(' ', 1)
            if len(parts) == 2:
                target, cmd = parts
                key = f'tmux:{target}'
                found[key] = f'tmux [{target}] running: {cmd}'
    except Exception:
        pass

    return [(label, target) for target, label in found.items()]


class TMClient:
    """Synchronous JSON-RPC client talking to terminal-manager subprocess."""

    def __init__(self):
        self._proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, 'main.py')],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._id = 0
        self._lock = threading.Lock()

        # Print stderr (debug output from terminal-manager) in background
        def _pump_stderr():
            for line in self._proc.stderr:
                print(f'\033[90m[TM] {line.rstrip()}\033[0m', flush=True)
        threading.Thread(target=_pump_stderr, daemon=True).start()

    def call(self, name: str, arguments: dict) -> dict:
        with self._lock:
            self._id += 1
            msg = json.dumps({
                'jsonrpc': '2.0',
                'id': self._id,
                'method': 'tools/call',
                'params': {'name': name, 'arguments': arguments},
            })
            self._proc.stdin.write(msg + '\n')
            self._proc.stdin.flush()
            while True:
                line = self._proc.stdout.readline()
                if not line:
                    raise RuntimeError('terminal-manager exited unexpectedly')
                try:
                    resp = json.loads(line)
                    if resp.get('id') == self._id:
                        if 'error' in resp:
                            raise RuntimeError(resp['error']['message'])
                        return resp.get('result', {})
                except json.JSONDecodeError:
                    continue

    def stop(self):
        try:
            self._proc.terminate()
        except Exception:
            pass


def pretty(obj: dict, indent: int = 2) -> str:
    return json.dumps(obj, indent=indent, ensure_ascii=False)


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    tmux_target = None
    tty = None

    if arg and arg.startswith('--tmux'):
        tmux_target = sys.argv[2] if len(sys.argv) > 2 else arg.split('=', 1)[-1]
    elif arg:
        tty = arg
    else:
        procs = find_all_terminal_processes()
        if not procs:
            print('No terminal processes found. Pass /dev/ttys00N as argument.')
            sys.exit(1)
        elif len(procs) == 1:
            label, tty = procs[0]
            print(f'Auto-detected: {tty}  ({label})')
        else:
            print('Multiple terminal processes found:')
            for i, (label, t) in enumerate(procs):
                print(f'  [{i}] {t}  —  {label}')
            choice = input('Pick [0]: ').strip() or '0'
            label, tty = procs[int(choice)]
            print(f'Using: {tty}')

    if not tty and not tmux_target:
        print('Could not detect a TTY. Pass /dev/ttys00N or --tmux <target> as argument.')
        sys.exit(1)

    # Pick hook + read_mode based on detected app
    app_label = label.lower() if 'label' in dir() else ''
    is_tmux = tty.startswith('tmux:') if tty else bool(tmux_target)
    if 'opencode' in app_label:
        hook = OPENCODE_HOOK
        read_mode = 'contents'
        print('App: OpenCode (alt-screen)')
    else:
        hook = CODEX_HOOK
        read_mode = 'history'
        print('App: Codex/Claude (inline TUI)')

    if is_tmux and tty.startswith('tmux:'):
        tmux_target = tty[len('tmux:'):]
        tty = ''
        read_mode = 'tmux'
        print(f'tmux target: {tmux_target}')
    else:
        print(f'TTY: {tty}')

    print('Starting terminal-manager...')
    client = TMClient()
    time.sleep(0.3)  # let it start

    # Register session
    session_id = 'test-session'
    reg = client.call('register_session', {
        'session_id': session_id,
        'app_id': 'test_local',
        'tty': tty or '',
        'tmux_target': tmux_target or '',
        'hook': hook,
        'read_mode': read_mode,
    })
    print(f'Registered: {pretty(reg)}')
    print()
    def switch_session():
        nonlocal session_id, tty, tmux_target, hook, read_mode, label
        procs = find_all_terminal_processes()
        if not procs:
            print('No terminal processes found.')
            return
        print('Switch to:')
        for i, (lbl, t) in enumerate(procs):
            marker = ' ◀ current' if t == tty else ''
            print(f'  [{i}] {t}  —  {lbl}{marker}')
        choice = input('Pick: ').strip()
        if not choice.isdigit() or int(choice) >= len(procs):
            print('Cancelled.')
            return
        label, new_target = procs[int(choice)]
        app_label = label.lower()
        if 'opencode' in app_label:
            hook = OPENCODE_HOOK
            read_mode = 'contents'
            print('App: OpenCode (alt-screen)')
        else:
            hook = CODEX_HOOK
            read_mode = 'history'
            print('App: Codex/Claude (inline TUI)')

        if new_target.startswith('tmux:'):
            tmux_target = new_target[len('tmux:'):]
            tty = ''
            read_mode = 'tmux'
            session_id = f'test-tmux-{tmux_target.replace(":", "-")}'
            print(f'tmux target: {tmux_target}')
        else:
            tty = new_target
            tmux_target = ''
            session_id = f'test-{tty.split("/")[-1]}'
            print(f'TTY: {tty}')

        reg = client.call('register_session', {
            'session_id': session_id,
            'app_id': 'test_local',
            'tty': tty,
            'tmux_target': tmux_target,
            'hook': hook,
            'read_mode': read_mode,
        })
        print(f'Switched → session={session_id}  {reg}')

    print('Commands: r=detect_tui  R=read_output  ls=list  sw=switch terminal  k <key>=send_key  t <text>=send_text  raw <text>=send_raw  q=quit')
    print()

    while True:
        try:
            cmd = input('> ').strip()
        except (EOFError, KeyboardInterrupt):
            break

        if not cmd:
            continue

        if cmd in ('q', 'Q'):
            break

        elif cmd in ('sw', 'switch'):
            switch_session()
            print()

        elif cmd == 'r':
            result = client.call('detect_tui', {'session_id': session_id})
            pid = result.get('pattern_id')
            metadata = result.get('metadata')
            if pid is None:
                print('  → No TUI detected')
            else:
                print(f'  → MATCH pattern_id={pid!r}')
                print(pretty(result.get('result', {})))
            if metadata:
                print('  → Metadata:')
                print(pretty(metadata))
            print()

        elif cmd == 'R':
            result = client.call('read_output', {'session_id': session_id, 'lines': 30})
            lines = result.get('lines', [])
            print(f'\n─── last {len(lines)} lines ───')
            for i, line in enumerate(lines):
                print(f'{i:3}: {line!r}')
            print()

        elif cmd == 'ls':
            result = client.call('list_sessions', {})
            print(pretty(result))
            print()

        elif cmd.startswith('k '):
            key = cmd[2:].strip()
            result = client.call('send_key', {'session_id': session_id, 'key': key})
            print(f'  → {pretty(result)}')
            print()

        elif cmd.startswith('t '):
            text = cmd[2:]
            result = client.call('send_text', {'session_id': session_id, 'text': text})
            print(f'  → {pretty(result)}')
            print()

        elif cmd.startswith('raw '):
            text = cmd[4:]
            result = client.call('send_raw', {'session_id': session_id, 'text': text})
            print(f'  → {pretty(result)}')
            print()

        else:
            print('Unknown command. r / R / ls / k <key> / t <text> / raw <text> / q')

    client.stop()
    print('Done.')


if __name__ == '__main__':
    main()
