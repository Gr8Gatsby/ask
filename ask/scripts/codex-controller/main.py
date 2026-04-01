#!/usr/bin/env python3
"""
codex-controller — MCP client bridging Codex CLI hooks to the Ask iOS app.

Protocol:
  - Reads JSON-RPC 2.0 from stdin  (daemon → script)
  - Writes JSON-RPC 2.0 to stdout  (script → daemon)
  - Listens on a Unix socket for hook scripts
  - Auto-installs hooks into ~/.codex/hooks.json on first run
"""

import sys
import json
import asyncio
import hashlib
import os
import time
import uuid
from typing import Optional

# Force UTF-8 on stdout so emoji pass through cleanly to the Mac daemon
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SCRIPT_DIR     = os.path.dirname(os.path.abspath(__file__))
SOCKET_PATH    = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-controller.sock'))
BLOCK_TILE     = 'codex-controller-tile'
SESSION_TTL    = 3600  # seconds — block TTL and session load cutoff

CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')
CODEX_HOOKS_PATH  = os.path.expanduser('~/.codex/hooks.json')
SESSIONS_PATH     = os.environ.get('ASK_SESSIONS_PATH', os.path.expanduser('~/.ask/codex_sessions.json'))


# ------------------------------------------------------------------
# Hook installer — runs once at startup
# ------------------------------------------------------------------

def _install_hooks():
    """Ensure ~/.codex/config.toml has codex_hooks=true and
    ~/.codex/hooks.json points to this script's hook files."""
    hooks_dir = os.path.join(SCRIPT_DIR, 'hooks')
    _ensure_config_flag()
    _write_hooks_json(hooks_dir)


def _ensure_config_flag():
    """Add [features] codex_hooks = true to ~/.codex/config.toml if missing."""
    os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
    try:
        content = open(CODEX_CONFIG_PATH).read() if os.path.exists(CODEX_CONFIG_PATH) else ''
    except Exception:
        content = ''

    if 'codex_hooks' in content:
        return  # already set

    addition = '\n[features]\ncodex_hooks = true\n'
    try:
        with open(CODEX_CONFIG_PATH, 'a') as f:
            f.write(addition)
        print('[codex-controller] enabled codex_hooks in ~/.codex/config.toml', file=sys.stderr)
    except Exception as e:
        print(f'[codex-controller] could not update config.toml: {e}', file=sys.stderr)


def _write_hooks_json(hooks_dir: str):
    """Write ~/.codex/hooks.json with absolute paths to our hook scripts."""
    pre  = os.path.join(hooks_dir, 'pre_tool_use.py')
    post = os.path.join(hooks_dir, 'post_tool_use.py')
    start = os.path.join(hooks_dir, 'session_start.py')
    stop = os.path.join(hooks_dir, 'session_stop.py')

    hooks = {
        'hooks': {
            'SessionStart': [
                {'hooks': [{'type': 'command', 'command': start}]}
            ],
            'PreToolUse': [
                {
                    'matcher': 'tool == "Bash"',
                    'hooks': [{'type': 'command', 'command': pre}]
                }
            ],
            'PostToolUse': [
                {
                    'matcher': 'tool == "Bash"',
                    'hooks': [{'type': 'command', 'command': post}]
                }
            ],
            'Stop': [
                {'hooks': [{'type': 'command', 'command': stop}]}
            ],
        }
    }
    os.makedirs(os.path.dirname(CODEX_HOOKS_PATH), exist_ok=True)
    try:
        with open(CODEX_HOOKS_PATH, 'w') as f:
            json.dump(hooks, f, indent=2)
        print(f'[codex-controller] wrote hooks to {CODEX_HOOKS_PATH}', file=sys.stderr)
    except Exception as e:
        print(f'[codex-controller] could not write hooks.json: {e}', file=sys.stderr)


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}      # rpc_id  -> asyncio.Future (tool call responses)
        self._pending_blocks = {}     # block_id -> asyncio.Queue (blocking waiters)
        self._response_callbacks = {} # block_id -> async callable(value)
        # session_id -> {'cwd': str, 'project': str, 'last_message': str}
        self._sessions: dict = {}
        # session IDs where Codex is actively running (PreToolUse → PostToolUse)
        self._working_sessions: set = set()
        # (session_id, tool_name) -> [block_id, ...] — cleared when the tool runs
        self._tool_block_map = {}
        # cwd -> tmux window target (e.g. "0:2") for sessions launched via tmux
        self._pending_tmux_targets: dict = {}
        # tmux_target -> asyncio.Task — background pane monitors
        self._tmux_monitors: dict = {}
        # CWDs the user explicitly launched via Start Session — pid-* sessions only surface for these
        self._recently_launched_cwds: set = set()
        # Tile state
        self._active_confirmations = 0
        self._tile_body: Optional[str] = None
        self._initialized = False  # True after MCP handshake completes

    # ------------------------------------------------------------------
    # MCP outbound helpers
    # ------------------------------------------------------------------

    def _id(self):
        self._next_id += 1
        return self._next_id

    def _write(self, obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method, params=None):
        rpc_id = self._id()
        fut = asyncio.get_running_loop().create_future()
        self._pending_calls[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._write(msg)
        return await asyncio.wait_for(fut, timeout=10.0)

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'codex-controller', 'version': '1.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self._initialized = True
        print('[codex-controller] MCP initialized', file=sys.stderr)
        self._load_sessions()
        self._discover_active_processes()
        self._prune_dead_pid_sessions()
        for session_id, info in list(self._sessions.items()):
            asyncio.create_task(
                self._emit_session_block(session_id, last_message=info.get('last_message', ''), touch_last_seen=False)
            )
        asyncio.create_task(self._emit_start_session_block())

    async def emit_block(self, block_id, block_type, payload, ttl=None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        return await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id):
        return await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})

    async def _update_tile(self):
        # Count only sessions with an emitted block — excludes stale/filtered pid-* sessions
        n = sum(1 for info in self._sessions.values() if info.get('last_emitted'))
        if self._active_confirmations > 0:
            payload = {
                'label': 'Approval needed',
                'status_color': 'orange',
                'action_required': True,
            }
            if self._tile_body:
                payload['body'] = self._tile_body
        elif n == 0:
            payload = {
                'label': 'No sessions',
                'status_color': 'blue',
                'action_required': False,
            }
        else:
            label = '1 session' if n == 1 else f'{n} sessions'
            payload = {
                'label': label,
                'status_color': 'blue',
                'action_required': False,
            }
        try:
            await self.emit_block(BLOCK_TILE, 'tile', payload, ttl=600)
        except Exception as e:
            print(f'[codex-controller] tile update failed: {e}', file=sys.stderr)

    # ------------------------------------------------------------------
    # Stdin reader (daemon → script)
    # ------------------------------------------------------------------

    async def read_stdin(self):
        loop = asyncio.get_running_loop()
        stdin_buf = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, stdin_buf.readline)
            except Exception:
                break
            if not raw:
                break
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            await self._dispatch_inbound(msg)

    async def _dispatch_inbound(self, msg):
        rpc_id = msg.get('id')

        if rpc_id is not None and 'result' in msg:
            fut = self._pending_calls.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return

        if rpc_id is not None and 'error' in msg:
            fut = self._pending_calls.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return

        method = msg.get('method', '')
        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value = data.get('value', '')

                callback = self._response_callbacks.pop(block_id, None)
                if callback:
                    asyncio.create_task(callback(value))
                    return

                q = self._pending_blocks.get(block_id)
                if q:
                    await q.put(value)

    async def wait_for_block_response(self, block_id):
        """Wait indefinitely for the user to respond via iOS."""
        q = asyncio.Queue()
        self._pending_blocks[block_id] = q
        try:
            return await q.get()
        finally:
            self._pending_blocks.pop(block_id, None)

    # ------------------------------------------------------------------
    # Per-session blocks — one agent_session block per active Codex session
    # ------------------------------------------------------------------

    def _session_block_id(self, session_id: str) -> str:
        digest = hashlib.sha256(session_id.encode()).hexdigest()[:8]
        return f'codex-session-{digest}'

    def _start_session_block_id(self) -> str:
        return 'codex-start-session'

    def _scan_git_repos(self) -> list:
        """Return a sorted list of {name, path} dicts for local git repos."""
        import subprocess
        home = os.path.expanduser('~')
        search_dirs = [
            home,
            os.path.join(home, 'Documents'),
            os.path.join(home, 'code'),
            os.path.join(home, 'Desktop'),
            os.path.join(home, 'Developer'),
            os.path.join(home, 'projects'),
            os.path.join(home, 'src'),
            os.path.join(home, 'repos'),
        ]
        repo_paths = set()
        for info in self._sessions.values():
            cwd = info.get('cwd', '')
            if cwd and os.path.isdir(cwd):
                repo_paths.add(cwd)
        for base in search_dirs:
            if not os.path.isdir(base):
                continue
            try:
                result = subprocess.run(
                    ['find', base, '-maxdepth', '3', '-name', '.git', '-type', 'd'],
                    capture_output=True, text=True, timeout=10
                )
                for line in result.stdout.splitlines():
                    repo_path = os.path.dirname(line.strip())
                    if repo_path:
                        repo_paths.add(repo_path)
            except Exception:
                pass
        repos = []
        for path in sorted(repo_paths):
            parts = path.rstrip('/').split('/')
            name = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
            repos.append({'name': name, 'path': path})
        repos.sort(key=lambda x: x['name'].lower())
        return repos

    async def _emit_start_session_block(self):
        """Emit (or refresh) the start_session block containing the repo list."""
        if not self._initialized:
            return
        block_id = self._start_session_block_id()
        repos = self._scan_git_repos()
        payload = {'repos': repos}
        self._response_callbacks[block_id] = lambda v: self._on_start_session_reply(v)
        try:
            await self.emit_block(block_id, 'start_session', payload)
        except Exception as e:
            print(f'[codex-controller] start_session block emit failed: {e}', file=sys.stderr)

    async def _on_start_session_reply(self, value: str):
        """Called when the user picks a repo path from the iOS start-session sheet."""
        block_id = self._start_session_block_id()
        self._response_callbacks[block_id] = lambda v: self._on_start_session_reply(v)
        if value:
            await self._launch_session(value.strip())

    async def _launch_session(self, cwd: str):
        """Launch a new codex session in cwd via tmux, falling back to Terminal.app."""
        import shutil
        self._recently_launched_cwds.add(cwd)
        if shutil.which('tmux'):
            try:
                proc = await asyncio.create_subprocess_exec(
                    'tmux', 'new-window', '-P', '-c', cwd, 'codex',
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await proc.communicate()
                tmux_target = stdout.decode().strip()
                if tmux_target:
                    self._pending_tmux_targets[cwd] = tmux_target
                    task = asyncio.create_task(self._monitor_tmux_pane(tmux_target))
                    self._tmux_monitors[tmux_target] = task
                    asyncio.create_task(self._delayed_discovery())
                    print(f'[codex-controller] launched codex in tmux {tmux_target} at {cwd}', file=sys.stderr)
                    return
            except Exception as e:
                print(f'[codex-controller] tmux launch failed: {e}, falling back to Terminal.app', file=sys.stderr)
        safe_cwd = cwd.replace('\\', '\\\\').replace('"', '\\"')
        script = f'tell application "Terminal" to do script "cd \\"{safe_cwd}\\" && codex"'
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            print(f'[codex-controller] launched codex in Terminal.app at {cwd}', file=sys.stderr)
        except Exception as e:
            print(f'[codex-controller] Terminal.app launch failed: {e}', file=sys.stderr)
        asyncio.create_task(self._delayed_discovery())

    async def _delayed_discovery(self):
        """Re-run process discovery a few seconds after a launch to pick up new processes."""
        await asyncio.sleep(4)
        if not self._initialized:
            return
        self._discover_active_processes()
        for session_id, info in list(self._sessions.items()):
            if not info.get('last_emitted'):
                asyncio.create_task(self._emit_session_block(session_id))

    def _tmux_prompt_block_id(self, tmux_target: str) -> str:
        safe = tmux_target.replace(':', '-').replace('.', '-')
        return f'codex-tmux-prompt-{safe}'

    @staticmethod
    def _parse_tmux_prompt(content: str):
        """Detect a numbered interactive menu in tmux pane output.
        Returns (body, options) list, or None if no prompt found."""
        import re
        option_re = re.compile(r'^\s*>?\s*(\d+)[.)]\s+(.+)$')
        footer_re = re.compile(r'press\s+enter|to\s+continue', re.IGNORECASE)
        lines = content.splitlines()
        options = []
        body_lines = []
        found_options = False
        for line in lines:
            m = option_re.match(line)
            if m:
                found_options = True
                options.append(m.group(2).strip())
            elif not found_options:
                stripped = line.strip()
                if stripped and not re.match(r'^[$%#>]\s', stripped):
                    body_lines.append(stripped)
        has_footer = any(footer_re.search(l) for l in lines)
        if len(options) >= 2 and has_footer:
            body = ' '.join(body_lines[-2:]) if body_lines else 'Choose an option'
            return body, options
        return None

    async def _monitor_tmux_pane(self, tmux_target: str):
        """Poll a tmux pane for interactive prompts and surface them to iOS."""
        import hashlib as _hl
        block_id = self._tmux_prompt_block_id(tmux_target)
        last_hash = ''
        poll_interval = 1
        idle_streak = 0

        while True:
            await asyncio.sleep(poll_interval)
            try:
                proc = await asyncio.create_subprocess_exec(
                    'tmux', 'capture-pane', '-p', '-t', tmux_target,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
                content = stdout.decode()
            except Exception:
                break  # pane is gone

            result = self._parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if result:
                idle_streak = 0
                poll_interval = 1
                if content_hash != last_hash:
                    last_hash = content_hash
                    body, options = result
                    captured = (tmux_target, options, block_id)
                    self._response_callbacks[block_id] = (
                        lambda v, c=captured: self._on_tmux_prompt_reply(c[0], c[1], v, c[2])
                    )
                    payload = {'title': body, 'body': '', 'options': options}
                    try:
                        await self.emit_block(block_id, 'confirmation', payload, ttl=300)
                        print(f'[codex-controller] tmux prompt surfaced for {tmux_target}', file=sys.stderr)
                    except Exception as e:
                        print(f'[codex-controller] tmux prompt emit failed: {e}', file=sys.stderr)
            else:
                if last_hash:
                    last_hash = ''
                    self._response_callbacks.pop(block_id, None)
                    try:
                        await self.clear_block(block_id)
                    except Exception:
                        pass
                idle_streak += 1
                if idle_streak > 30:
                    poll_interval = 5  # slow down after startup phase

        # Pane gone — clean up
        self._tmux_monitors.pop(tmux_target, None)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    async def _on_tmux_prompt_reply(self, tmux_target: str, options: list, value: str, block_id: str):
        """Send the user's selection to the tmux pane."""
        try:
            idx = options.index(value)  # 0-based
        except ValueError:
            return
        try:
            # Navigate from default (option 0) to selected option using Down arrows
            for _ in range(idx):
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, 'Down',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
                await asyncio.sleep(0.05)
            # Confirm selection
            p = await asyncio.create_subprocess_exec(
                'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await p.communicate()
            # Handle any "Press Enter to continue" step
            await asyncio.sleep(0.4)
            p = await asyncio.create_subprocess_exec(
                'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await p.communicate()
        except Exception as e:
            print(f'[codex-controller] tmux prompt reply failed: {e}', file=sys.stderr)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    @staticmethod
    def _project_label(cwd: str, session_id: str) -> str:
        if cwd:
            parts = cwd.rstrip('/').split('/')
            path_label = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
        else:
            path_label = 'Codex'
        short = session_id if session_id.startswith('pid-') else session_id[:6]
        return f'{path_label} [{short}]'

    def _save_sessions(self):
        """PID-based sessions (pid-*) are transient and NOT persisted."""
        try:
            os.makedirs(os.path.dirname(SESSIONS_PATH), exist_ok=True)
            to_save = {sid: info for sid, info in self._sessions.items()
                       if not sid.startswith('pid-')}
            with open(SESSIONS_PATH, 'w') as f:
                json.dump(to_save, f)
        except Exception as e:
            print(f'[codex-controller] session save failed: {e}', file=sys.stderr)

    def _load_sessions(self):
        try:
            with open(SESSIONS_PATH) as f:
                data = json.load(f)
            cutoff = time.time() - SESSION_TTL
            self._sessions = {
                sid: info for sid, info in data.items()
                if isinstance(info, dict) and info.get('last_seen', 0) >= cutoff
            }
            print(f'[codex-controller] restored {len(self._sessions)} session(s)', file=sys.stderr)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f'[codex-controller] session load failed: {e}', file=sys.stderr)

    def _discover_active_processes(self):
        if os.environ.get('ASK_SKIP_DISCOVERY'):
            return
        """Scan for running codex processes and register their cwds as sessions."""
        import subprocess
        try:
            # Match the codex binary directly — avoid matching other node processes
            # that may reference 'codex' in their module paths (e.g. Claude Code)
            ps = subprocess.run(
                ['pgrep', '-f', r'(^|/)codex(\s|$)'],
                capture_output=True, text=True, timeout=3
            )
            pids = [p.strip() for p in ps.stdout.splitlines() if p.strip()]
            if not pids:
                return
            for pid in pids:
                try:
                    # Skip background/daemon processes — only track interactive terminal sessions.
                    # A controlling terminal (tty != '?') confirms the process is user-facing.
                    tty = subprocess.run(
                        ['ps', '-p', pid, '-o', 'tty='],
                        capture_output=True, text=True, timeout=3
                    ).stdout.strip()
                    if tty == '?' or not tty:
                        continue
                    lsof = subprocess.run(
                        ['lsof', '-a', '-p', pid, '-d', 'cwd', '-Fn'],
                        capture_output=True, text=True, timeout=3
                    )
                    cwd = next(
                        (line[1:] for line in lsof.stdout.splitlines() if line.startswith('n')),
                        ''
                    )
                    if cwd and cwd not in ('/', '/private'):
                        synthetic_id = f'pid-{pid}'
                        if self._register_session(synthetic_id, cwd):
                            print(f'[codex-controller] discovered codex process pid={pid} cwd={cwd}', file=sys.stderr)
                except Exception:
                    pass
        except Exception as e:
            print(f'[codex-controller] process discovery failed: {e}', file=sys.stderr)

    @staticmethod
    def _pid_session_alive(session_id: str) -> bool:
        if not session_id.startswith('pid-'):
            return True
        try:
            pid = int(session_id[4:])
            os.kill(pid, 0)
            return True
        except (ValueError, ProcessLookupError):
            return False
        except PermissionError:
            return True

    def _prune_dead_pid_sessions(self):
        dead = [sid for sid in list(self._sessions) if sid.startswith('pid-') and not self._pid_session_alive(sid)]
        for sid in dead:
            self._sessions.pop(sid, None)
            self._working_sessions.discard(sid)
            print(f'[codex-controller] pruned dead pid session {sid}', file=sys.stderr)
        return dead

    def _register_session(self, session_id: str, cwd: str):
        if session_id in self._sessions:
            return False
        project = self._project_label(cwd, session_id)
        entry = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
        tmux_target = self._pending_tmux_targets.pop(cwd, None)
        if tmux_target:
            entry['tmux_target'] = tmux_target
        if not session_id.startswith('pid-'):
            for sid in list(self._sessions.keys()):
                if sid.startswith('pid-') and self._sessions[sid].get('cwd') == cwd:
                    self._sessions.pop(sid)
                    self._recently_launched_cwds.discard(cwd)
                    asyncio.create_task(self.clear_block(self._session_block_id(sid)))
        self._sessions[session_id] = entry
        self._save_sessions()
        return True

    def _handle_session_active(self, msg):
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '') or msg.get('tool_cwd', '')
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd)
        self._working_sessions.add(session_id)
        if is_new:
            asyncio.create_task(self._emit_session_block(session_id))

    def _handle_session_stop(self, msg):
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        last_message = msg.get('last_message', '')
        if not session_id:
            return
        self._register_session(session_id, cwd)
        if session_id in self._sessions:
            if cwd:
                self._sessions[session_id]['cwd'] = cwd
                self._sessions[session_id]['project'] = self._project_label(cwd, session_id)
            self._sessions[session_id]['last_seen'] = time.time()
        self._working_sessions.discard(session_id)
        # Cancel any tmux pane monitor for this session
        tmux_target = self._sessions.get(session_id, {}).get('tmux_target')
        if tmux_target:
            task = self._tmux_monitors.pop(tmux_target, None)
            if task:
                task.cancel()
        print(f'[codex-controller] session stopped: {session_id}', file=sys.stderr)
        asyncio.create_task(self._emit_session_block(session_id, last_message=last_message))

    async def _emit_session_block(self, session_id: str, last_message: str = '', touch_last_seen: bool = True):
        """touch_last_seen=False during startup re-emit so sessions past SESSION_TTL
        are not artificially kept alive across restarts."""
        if session_id.startswith('pid-'):
            cwd = self._sessions.get(session_id, {}).get('cwd', '')
            if cwd not in self._recently_launched_cwds:
                return
        if not self._initialized:
            print(f'[codex-controller] skipping session block — not yet initialized', file=sys.stderr)
            return
        session = self._sessions.get(session_id, {})
        project = session.get('project', 'Codex')
        cwd = session.get('cwd', '')
        block_id = self._session_block_id(session_id)
        payload: dict = {
            'session_id': session_id,
            'project': project,
            'cwd': cwd,
            'agent_name': 'Codex',
            'brand_color': '#74AA9C',
            'placeholder': 'Reply to Codex…',
        }
        if last_message:
            payload['last_message'] = last_message
        payload['is_working'] = session_id in self._working_sessions
        self._response_callbacks[block_id] = lambda v: self._on_session_reply(session_id, v)
        try:
            if session_id in self._sessions:
                now = time.time()
                if touch_last_seen:
                    self._sessions[session_id]['last_seen'] = now
                self._sessions[session_id]['last_emitted'] = now
                if last_message:
                    self._sessions[session_id]['last_message'] = last_message
            self._save_sessions()
            await self.emit_block(block_id, 'agent_session', payload, ttl=SESSION_TTL)
        except Exception as e:
            print(f'[codex-controller] agent_session emit failed: {e}', file=sys.stderr)

    async def _on_session_reply(self, session_id: str, value: str):
        block_id = self._session_block_id(session_id)
        self._response_callbacks[block_id] = lambda v: self._on_session_reply(session_id, v)
        if value:
            await self._route_to_terminal(session_id, value)

    @staticmethod
    def _strip_ansi(text: str) -> str:
        import re
        return re.sub(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b\][^\x07]*\x07|\r', '', text)

    @staticmethod
    def _is_codex_idle(content: str) -> bool:
        """True when Codex is at its input prompt (^C quit footer visible)."""
        import re
        return bool(re.search(r'\^C\s+quit', content))

    @staticmethod
    def _extract_response(content: str) -> str:
        """Extract the most recent Codex response from pane content."""
        import re
        clean = MCPClient._strip_ansi(content)
        lines = clean.splitlines()
        # Bottom boundary: first ^C quit line
        bottom_idx = next(
            (i for i, l in enumerate(lines) if re.search(r'\^C\s+quit', l)),
            len(lines)
        )
        # Top boundary: last prompt/input line above the response
        # Look for a line that looks like a user prompt divider (blank line or "> " prompt)
        candidate = lines[:bottom_idx]
        # Strip trailing blank lines above ^C quit
        while candidate and not candidate[-1].strip():
            candidate.pop()
        # Remove lines that are purely decorative (box-drawing, all dashes, etc.)
        response_lines = [l for l in candidate if l.strip() and not re.match(r'^[-─━═╌╍\s]+$', l)]
        # Return last 40 lines, trimmed
        return '\n'.join(response_lines[-40:]).strip()[:4000]

    def _session_id_for_tmux(self, tmux_target: str) -> Optional[str]:
        """Find the session_id that owns this tmux_target."""
        for sid, info in self._sessions.items():
            if info.get('tmux_target') == tmux_target:
                return sid
        return None

    async def _capture_tmux_response(self, tmux_target: str, session_id: str):
        """After routing a message, poll until Codex is idle, then emit last_message."""
        # Wait for Codex to start processing
        await asyncio.sleep(2)
        prev_content = ''
        stable_count = 0
        for _ in range(180):  # max ~3 min
            await asyncio.sleep(1)
            try:
                proc = await asyncio.create_subprocess_exec(
                    'tmux', 'capture-pane', '-p', '-t', tmux_target,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
                content = stdout.decode()
            except Exception:
                return  # pane gone

            if self._is_codex_idle(content):
                if content == prev_content:
                    stable_count += 1
                    if stable_count >= 2:
                        response = self._extract_response(content)
                        if response:
                            print(f'[codex-controller] captured response for {session_id} ({len(response)} chars)', file=sys.stderr)
                            asyncio.create_task(self._emit_session_block(session_id, last_message=response))
                        return
                else:
                    stable_count = 0
            else:
                stable_count = 0
            prev_content = content

    async def _route_to_terminal(self, session_id: str, text: str):
        """Route text to the terminal running this session.
        Uses tmux send-keys for tmux-launched sessions; clipboard+osascript otherwise."""
        session = self._sessions.get(session_id, {})
        tmux_target = session.get('tmux_target')
        if tmux_target:
            try:
                p1 = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, '-l', text,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p1.communicate()
                p2 = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p2.communicate()
            except Exception as e:
                print(f'[codex-controller] tmux send-keys failed: {e}', file=sys.stderr)
            asyncio.create_task(self._capture_tmux_response(tmux_target, session_id))
            return

        try:
            pbcopy = await asyncio.create_subprocess_exec(
                'pbcopy',
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await pbcopy.communicate(input=text.encode('utf-8'))
        except Exception as e:
            print(f'[codex-controller] pbcopy failed: {e}', file=sys.stderr)
            return

        session = self._sessions.get(session_id, {})
        project = session.get('project', '')
        safe_project = project.replace('\\', '\\\\').replace('"', '\\"')

        script = f'''
set projectName to "{safe_project}"
set didFocus to false

if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tList to tabs of w
            repeat with t in tList
                try
                    if name of t contains projectName then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set didFocus to true
                        exit repeat
                    end if
                end try
            end repeat
            if didFocus then exit repeat
        end repeat
        if not didFocus then activate
    end tell
    set didFocus to true
end if

if not didFocus and application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            set tList to tabs of w
            repeat with t in tList
                set sList to sessions of t
                repeat with s in sList
                    try
                        if name of s contains projectName then
                            select t
                            activate
                            set didFocus to true
                            exit repeat
                        end if
                    end try
                end repeat
                if didFocus then exit repeat
            end repeat
            if didFocus then exit repeat
        end repeat
        if not didFocus then activate
    end tell
    set didFocus to true
end if

delay 0.4
tell application "System Events"
    keystroke "v" using command down
    delay 0.4
    keystroke return
end tell
'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, err = await asyncio.wait_for(proc.communicate(), timeout=8.0)
            if err:
                print(f'[codex-controller] osascript: {err.decode().strip()}', file=sys.stderr)
        except Exception as e:
            print(f'[codex-controller] _route_to_terminal failed: {e}', file=sys.stderr)

    # ------------------------------------------------------------------
    # Unix socket server (hook scripts → main.py)
    # ------------------------------------------------------------------

    async def handle_socket_client(self, reader, writer):
        try:
            raw = await asyncio.wait_for(reader.read(65536), timeout=5.0)
            if not raw:
                return
            msg = json.loads(raw.decode())
            msg_type = msg.get('type', '')

            if msg_type == 'permission_request':
                response = await self._handle_blocking(
                    writer,
                    self._build_permission_block(msg),
                    default='Deny',
                )
                if not writer.is_closing():
                    writer.write(json.dumps(response, ensure_ascii=False).encode())
                    await writer.drain()

            elif msg_type == 'session_active':
                self._handle_session_active(msg)
                writer.write(json.dumps({'status': 'ok'}, ensure_ascii=False).encode())
                await writer.drain()

            elif msg_type == 'notification':
                await self._handle_notification(msg)

            elif msg_type == 'tool_executed':
                await self._handle_tool_executed(msg)

            elif msg_type == 'session_stop':
                self._handle_session_stop(msg)

        except Exception as e:
            print(f'[codex-controller] socket client error: {e}', file=sys.stderr)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _handle_blocking(self, writer, block_coro, default):
        """
        Emit a block, then race waiting for an iOS response against the hook
        process exiting (user answered in the terminal). Waits indefinitely for
        iOS response — no automatic timeout.
        """
        block_id, _ = await block_coro
        if block_id is None:
            return {'value': default}

        async def wait_writer_closed():
            """Resolve when the hook process fully closes the socket.
            After SHUT_WR the read side is already at EOF; we detect the
            full peer close via a zero-length probe write which raises
            BrokenPipeError / ConnectionResetError once the peer exits."""
            transport = writer.transport
            while not transport.is_closing():
                await asyncio.sleep(0.3)
                if transport.is_closing():
                    return
                try:
                    writer.write(b'')
                    await asyncio.wait_for(writer.drain(), timeout=0.5)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return
                except asyncio.TimeoutError:
                    pass
                except Exception:
                    return

        response_task = asyncio.create_task(self.wait_for_block_response(block_id))
        disconnect_task = asyncio.create_task(wait_writer_closed())

        done, pending = await asyncio.wait(
            [response_task, disconnect_task],
            return_when=asyncio.FIRST_COMPLETED,
        )

        for task in pending:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

        if disconnect_task in done and response_task not in done:
            print(f'[codex-controller] hook exited — clearing block {block_id}', file=sys.stderr)
            try:
                await self.clear_block(block_id)
            except Exception:
                pass
            self._active_confirmations = max(0, self._active_confirmations - 1)
            if self._active_confirmations == 0:
                self._tile_body = None
            asyncio.create_task(self._update_tile())
            return {'value': default}

        value = response_task.result() if response_task in done else None
        try:
            await self.clear_block(block_id)
        except Exception:
            pass
        self._active_confirmations = max(0, self._active_confirmations - 1)
        if self._active_confirmations == 0:
            self._tile_body = None
        asyncio.create_task(self._update_tile())
        return {'value': value or default}

    async def _build_permission_block(self, msg):
        if not self._initialized:
            print(f'[codex-controller] skipping permission block — not yet initialized', file=sys.stderr)
            return None, None
        block_id = str(uuid.uuid4())
        tool = msg.get('tool', 'Unknown')
        session_id = msg.get('session_id', '')
        preview = msg.get('preview', '')
        options = msg.get('options', ['Allow', 'Deny'])
        payload = {'title': f'Allow {tool}?', 'body': preview, 'options': options}
        if session_id:
            payload['session_id'] = session_id
        try:
            await self.emit_block(block_id, 'confirmation', payload)
            if session_id:
                key = (session_id, tool)
                self._tool_block_map.setdefault(key, []).append(block_id)
            self._active_confirmations += 1
            self._tile_body = f'Allow {tool}?\n{preview[:100]}' if preview else f'Allow {tool}?'
            asyncio.create_task(self._update_tile())
            return block_id, payload
        except Exception as e:
            print(f'[codex-controller] emit_block failed: {e}', file=sys.stderr)
            return None, None

    async def _handle_tool_executed(self, msg):
        session_id = msg.get('session_id', '')
        tool_name = msg.get('tool_name', '') or msg.get('tool', '')
        cwd = msg.get('cwd', '')
        if not session_id or not tool_name:
            return
        is_new = self._register_session(session_id, cwd)
        if is_new:
            asyncio.create_task(self._emit_session_block(session_id))
        else:
            last = self._sessions[session_id].get('last_emitted', 0)
            if time.time() - last > 300:
                asyncio.create_task(self._emit_session_block(session_id))
        key = (session_id, tool_name)
        block_ids = self._tool_block_map.pop(key, [])
        for block_id in block_ids:
            q = self._pending_blocks.get(block_id)
            if q:
                print(f'[codex-controller] tool {tool_name} ran — clearing block {block_id}', file=sys.stderr)
                await q.put('Allow')

    async def _handle_notification(self, msg):
        block_id = str(uuid.uuid4())
        payload = {
            'title': msg.get('title', 'Codex'),
            'body': msg.get('body', ''),
            'icon': msg.get('icon', 'bell.fill')
        }
        try:
            await self.emit_block(block_id, 'alert', payload, ttl=3600)
        except Exception as e:
            print(f'[codex-controller] notification emit failed: {e}', file=sys.stderr)

    async def start_socket_server(self):
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        return await asyncio.start_unix_server(self.handle_socket_client, path=SOCKET_PATH)


# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

async def _tile_heartbeat(client):
    while True:
        await asyncio.sleep(300)
        await client._update_tile()


async def _session_heartbeat(client):
    while True:
        await asyncio.sleep(300)
        if not client._initialized:
            continue
        client._discover_active_processes()
        dead = client._prune_dead_pid_sessions()
        for session_id in dead:
            try:
                await client.clear_block(client._session_block_id(session_id))
            except Exception:
                pass
        for session_id in list(client._sessions.keys()):
            try:
                await client._emit_session_block(session_id)
            except Exception as e:
                print(f'[codex-controller] session heartbeat error for {session_id[:8]}: {e}', file=sys.stderr)
        try:
            await client._emit_start_session_block()
        except Exception as e:
            print(f'[codex-controller] start_session heartbeat error: {e}', file=sys.stderr)


async def run():
    _install_hooks()

    client = MCPClient()
    server = await client.start_socket_server()

    stdin_task = asyncio.create_task(client.read_stdin())

    asyncio.create_task(_tile_heartbeat(client))
    asyncio.create_task(_session_heartbeat(client))

    try:
        await client.initialize()
        await client._update_tile()
    except Exception as e:
        print(f'[codex-controller] MCP initialize error: {e}', file=sys.stderr)

    async with server:
        await stdin_task


if __name__ == '__main__':
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        if os.path.exists(SOCKET_PATH):
            try:
                os.unlink(SOCKET_PATH)
            except Exception:
                pass
