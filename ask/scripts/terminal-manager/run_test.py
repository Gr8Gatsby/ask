#!/usr/bin/env python3
"""
run_test.py — automated test: finds all terminals, registers each, reads output
and runs detection. Prints everything. No interaction required.
"""
import sys, json, os, subprocess, threading, time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from test_local import find_all_terminal_processes, CODEX_HOOK, OPENCODE_HOOK

class TMClient:
    def __init__(self):
        self._proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, 'main.py')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self._id = 0
        self._lock = threading.Lock()
        def _pump():
            for line in self._proc.stderr:
                print(f'  \033[90m[TM] {line.rstrip()}\033[0m', flush=True)
        threading.Thread(target=_pump, daemon=True).start()

    def call(self, name, arguments):
        with self._lock:
            self._id += 1
            self._proc.stdin.write(json.dumps({
                'jsonrpc': '2.0', 'id': self._id,
                'method': 'tools/call',
                'params': {'name': name, 'arguments': arguments},
            }) + '\n')
            self._proc.stdin.flush()
            while True:
                line = self._proc.stdout.readline()
                if not line:
                    raise RuntimeError('terminal-manager exited')
                try:
                    r = json.loads(line)
                    if r.get('id') == self._id:
                        if 'error' in r:
                            raise RuntimeError(r['error']['message'])
                        return r.get('result', {})
                except json.JSONDecodeError:
                    continue

    def stop(self):
        try: self._proc.terminate()
        except: pass

def sep(title=''):
    w = 70
    if title:
        pad = '─' * ((w - len(title) - 2) // 2)
        print(f'\n{pad} {title} {pad}')
    else:
        print('─' * w)

client = TMClient()
time.sleep(0.3)

procs = find_all_terminal_processes()
sep('Discovered terminals')
for i, (label, target) in enumerate(procs):
    print(f'  [{i}] {target}  —  {label}')

print()

for label, target in procs:
    app_label = label.lower()
    is_tmux = target.startswith('tmux:')

    if is_tmux:
        tmux_target = target[len('tmux:'):]
        tty = ''
        read_mode = 'tmux'
        hook = OPENCODE_HOOK if 'opencode' in app_label else CODEX_HOOK
    else:
        tty = target
        tmux_target = ''
        read_mode = 'contents' if 'opencode' in app_label else 'history'
        hook = OPENCODE_HOOK if 'opencode' in app_label else CODEX_HOOK

    session_id = f'auto-{target.replace("/dev/","").replace("tmux:","tmux-").replace(":","_").replace(".","_")}'

    sep(f'{label[:40]}')
    print(f'  target={target}  read_mode={read_mode}')

    # Register
    reg = client.call('register_session', {
        'session_id': session_id,
        'app_id': 'run_test',
        'tty': tty,
        'tmux_target': tmux_target,
        'hook': hook,
        'read_mode': read_mode,
    })
    print(f'  registered: {reg}')

    # Read output
    out = client.call('read_output', {'session_id': session_id, 'lines': 40})
    lines = out.get('lines', [])
    non_empty = [l for l in lines if l.strip()]
    print(f'  read_output: {len(lines)} lines ({len(non_empty)} non-empty)')
    if non_empty:
        print('  last 8 non-empty lines:')
        for l in non_empty[-8:]:
            print(f'    | {l}')

    # Detect TUI
    det = client.call('detect_tui', {'session_id': session_id})
    pid = det.get('pattern_id')
    meta = det.get('metadata')
    print(f'  detect_tui: pattern_id={pid!r}')
    if pid:
        print(f'  result: {json.dumps(det.get("result"), indent=4)}')
    if meta:
        print(f'  metadata: {json.dumps(meta, indent=4)}')

    print()

sep('Done')
client.stop()
