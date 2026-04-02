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
STATUS_PATH       = os.path.expanduser('~/.ask/status/codex-controller.json')
LOG_PATH          = os.path.expanduser('~/.ask/logs/codex-controller.log')


def _log(msg: str):
    """Write a timestamped line to stderr and the log file."""
    import datetime
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, file=sys.stderr)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


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
                    'hooks': [{'type': 'command', 'command': pre}]
                }
            ],
            'PostToolUse': [
                {
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
        # session_id -> asyncio.Task — active response capture (deduplicated per session)
        self._capture_tasks: dict = {}
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
        await self._discover_active_processes()
        self._prune_dead_pid_sessions()
        dead_real = await self._prune_dead_real_sessions()
        for session_id in dead_real:
            asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
        # Backfill TTYs immediately at startup (don't wait for heartbeat)
        backfilled = False
        for session_id, info in list(self._sessions.items()):
            if not info.get('tty') and info.get('cwd'):
                tty = await self._find_tty_for_cwd(info['cwd'], 'codex')
                if tty:
                    info['tty'] = tty
                    backfilled = True
                    print(f'[codex-controller] startup TTY backfill: {session_id} -> {tty}', file=sys.stderr)
        if backfilled:
            self._save_sessions()
        # Backfill tmux_target from TTY so discovered sessions use the reliable
        # tmux send-keys path instead of the AppleScript do-script fallback.
        await self._backfill_tmux_targets()
        self._write_status()
        for session_id, info in list(self._sessions.items()):
            stored_msg = info.get('last_message', '')
            if stored_msg:
                asyncio.create_task(
                    self._emit_session_block(session_id, last_message=stored_msg, touch_last_seen=False)
                )
            elif info.get('tmux_target'):
                # No stored message — try to read the terminal now
                asyncio.create_task(self._capture_tmux_once(info['tmux_target'], session_id))
            else:
                asyncio.create_task(
                    self._emit_session_block(session_id, touch_last_seen=False)
                )
        asyncio.create_task(self._emit_start_session_block())

    async def emit_block(self, block_id, block_type, payload, ttl=None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        return await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id):
        return await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})

    async def list_terminal_sessions(self, filter: str = '') -> list:
        """Query the daemon for active terminal sessions on this Mac."""
        args = {}
        if filter:
            args['filter'] = filter
        try:
            result = await self._rpc('tools/call', {'name': 'list_terminal_sessions', 'arguments': args})
            return result.get('sessions', []) if isinstance(result, dict) else []
        except Exception as e:
            print(f'[codex-controller] list_terminal_sessions failed: {e}', file=sys.stderr)
            return []

    async def _update_tile(self):
        # Count all sessions that have a TTY (surfaceable on iOS), whether or not the
        # block has been emitted yet (avoids "No sessions" during startup race).
        n = sum(1 for info in self._sessions.values() if info.get('tty'))
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

        # Show a loading block on iOS immediately
        parts = cwd.rstrip('/').split('/')
        project_label = '/'.join(parts[-2:]) if len(parts) >= 2 else (parts[-1] or 'Codex')
        loading_id = self._launching_block_id(cwd)
        loading_payload = {
            'session_id': loading_id,
            'project': project_label,
            'cwd': cwd,
            'agent_name': 'Codex',
            'brand_color': '#74AA9C',
            'placeholder': 'Reply to Codex…',
            'last_message': 'Starting Codex…',
            'is_working': True,
        }
        asyncio.create_task(self.emit_block(loading_id, 'agent_session', loading_payload, ttl=120))

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
        asyncio.create_task(self._monitor_terminal_app_launch(cwd))
        asyncio.create_task(self._delayed_discovery())

    async def _delayed_discovery(self):
        """Re-run process discovery a few seconds after a launch to pick up new processes."""
        await asyncio.sleep(4)
        if not self._initialized:
            return
        await self._discover_active_processes()
        await self._backfill_tmux_targets()
        for session_id, info in list(self._sessions.items()):
            if not info.get('last_emitted'):
                asyncio.create_task(self._emit_session_block(session_id))

    def _tmux_prompt_block_id(self, tmux_target: str) -> str:
        safe = tmux_target.replace(':', '-').replace('.', '-')
        return f'codex-tmux-prompt-{safe}'

    @staticmethod
    def _launching_block_id(cwd: str) -> str:
        import hashlib
        h = hashlib.md5(cwd.encode()).hexdigest()[:8]
        return f'codex-launching-{h}'

    @staticmethod
    def _terminal_prompt_block_id(cwd: str) -> str:
        import hashlib
        h = hashlib.md5(cwd.encode()).hexdigest()[:8]
        return f'codex-terminal-prompt-{h}'

    @staticmethod
    def _parse_tmux_prompt(content: str):
        """Detect interactive prompts in tmux pane output.
        Returns (body, options) or None if no prompt found.

        Handles two formats:
          1. Numbered menu   — lines like "1. Yes", "2. No" + footer "press enter"
          2. Codex approval  — "Allow command?" + horizontal options "Yes    Always    No…"
        """
        import re
        # Strip ANSI escape codes so highlighting doesn't break matching
        ansi_re = re.compile(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r')
        lines = [ansi_re.sub('', l) for l in content.splitlines()]

        # --- Pattern 1: numbered menu (original) ---
        option_re = re.compile(r'^\s*>?\s*(\d+)[.)]\s+(.+)$')
        footer_re = re.compile(r'press\s+enter|to\s+continue', re.IGNORECASE)
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

        # --- Pattern 2: Codex "Allow command?" horizontal option menu ---
        # Indicator: a line containing "Allow" followed by a word and "?"
        allow_re = re.compile(r'\bAllow\b.{0,40}\?', re.IGNORECASE)
        has_allow = any(allow_re.search(l) for l in lines)
        if has_allow:
            # Find the body (the Allow command? line)
            body = 'Allow command?'
            for l in lines:
                if allow_re.search(l):
                    body = l.strip() or body
            # Find the options line: words/phrases separated by 2+ spaces
            # e.g. "  Yes    Always    No, provide feedback"
            for line in reversed(lines):  # options are near the bottom
                stripped = line.strip()
                if not stripped:
                    continue
                parts = re.split(r'\s{2,}', stripped)
                parts = [p.strip() for p in parts if p.strip()]
                # Valid option line: 2-4 items, each ≤ 35 chars, no shell prompt chars
                if (2 <= len(parts) <= 4
                        and all(1 < len(p) <= 35 for p in parts)
                        and not any(c in stripped for c in ('$', '%', '#', '=', '{', '}'))):
                    return body, parts
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
        # Trigger response capture so the session block updates with what
        # Codex does after the user approves/rejects the command.
        session_id = self._session_id_for_tmux(tmux_target)
        if session_id:
            asyncio.create_task(self._capture_tmux_response(tmux_target, session_id))

    async def _monitor_terminal_app_launch(self, cwd: str):
        """Monitor a Terminal.app-launched Codex session for startup prompts.
        Polls for the process TTY, then watches terminal history for numbered menus."""
        prompt_block_id = self._terminal_prompt_block_id(cwd)
        loading_block_id = self._launching_block_id(cwd)

        # Wait for codex process to appear (up to 20s)
        full_tty = None
        for _ in range(20):
            await asyncio.sleep(1)
            tty_short = await self._find_tty_for_cwd(cwd, 'codex')
            if tty_short:
                if tty_short.startswith('/dev/'):
                    full_tty = tty_short
                elif tty_short.startswith('ttys') or tty_short.startswith('ttyp'):
                    full_tty = f'/dev/{tty_short}'
                else:
                    full_tty = f'/dev/tty{tty_short}'
                _log(f'[codex] terminal monitor found TTY: {full_tty}')
                break

        if not full_tty:
            _log(f'[codex] terminal monitor: no TTY found for {cwd}')
            asyncio.create_task(self.clear_block(loading_block_id))
            return

        safe_tty = full_tty.replace('"', '\\"')
        read_script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe_tty}" then
                    return history of tab i of w
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''

        import hashlib as _hl
        last_hash = ''
        no_prompt_streak = 0

        for _ in range(120):
            await asyncio.sleep(1)

            # Stop if real session has registered for this cwd
            if any(
                info.get('cwd') == cwd and info.get('tty') and not info.get('session_id', '').startswith('launching-')
                for info in self._sessions.values()
            ):
                self._response_callbacks.pop(prompt_block_id, None)
                asyncio.create_task(self.clear_block(prompt_block_id))
                return

            try:
                proc = await asyncio.create_subprocess_exec(
                    'osascript', '-e', read_script,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
                content = MCPClient._strip_ansi(stdout.decode(errors='replace'))
            except Exception:
                continue

            if not content.strip():
                continue

            result = self._parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if result:
                no_prompt_streak = 0
                if content_hash != last_hash:
                    last_hash = content_hash
                    body, options = result
                    captured = (full_tty, options, prompt_block_id)
                    self._response_callbacks[prompt_block_id] = (
                        lambda v, c=captured: self._on_terminal_prompt_reply(c[0], c[1], v, c[2])
                    )
                    payload = {'title': body, 'body': '', 'options': options}
                    try:
                        await self.emit_block(prompt_block_id, 'confirmation', payload, ttl=300)
                        _log(f'[codex] terminal startup prompt surfaced for {full_tty}')
                    except Exception as e:
                        _log(f'[codex] terminal prompt emit failed: {e}')
            else:
                if last_hash:
                    last_hash = ''
                    self._response_callbacks.pop(prompt_block_id, None)
                    asyncio.create_task(self.clear_block(prompt_block_id))
                no_prompt_streak += 1
                if no_prompt_streak >= 8:
                    # 8s with no prompts after TTY found — startup complete
                    break

        self._response_callbacks.pop(prompt_block_id, None)
        try:
            await self.clear_block(prompt_block_id)
        except Exception:
            pass

    async def _on_terminal_prompt_reply(self, full_tty: str, options: list, value: str, block_id: str):
        """Send the user's menu selection to a Terminal.app tab via System Events."""
        try:
            idx = options.index(value)
        except ValueError:
            return
        safe_tty = full_tty.replace('"', '\\"')
        # Build the keystroke sequence: focus tab, send Down arrows, confirm twice
        down_keys = '\n    '.join(['key code 125'] * idx) if idx else ''
        focus_and_send = f'''set targetTTY to "{safe_tty}"
tell application "Terminal"
    repeat with w in every window
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is targetTTY then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                end if
            end try
        end repeat
    end repeat
end tell
delay 0.2
tell application "System Events"
    {down_keys}
    key code 36
    delay 0.4
    key code 36
end tell'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', focus_and_send,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
            )
            await proc.communicate()
            _log(f'[codex] terminal prompt reply: option {idx} ({value})')
        except Exception as e:
            _log(f'[codex] terminal prompt reply failed: {e}')
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
        self._write_status()

    def _write_status(self):
        """Write a human-readable status file for AskMac diagnostics."""
        try:
            import subprocess
            os.makedirs(os.path.dirname(STATUS_PATH), exist_ok=True)
            sessions = []
            for sid, info in self._sessions.items():
                sessions.append({
                    'session_id': sid,
                    'project': info.get('project', ''),
                    'cwd': info.get('cwd', ''),
                    'tty': info.get('tty', ''),
                    'last_seen': info.get('last_seen', 0),
                })
            # Live process scan so AskMac can show what's actually running
            live = []
            try:
                r = subprocess.run(['ps', '-eo', 'pid,tty,comm'],
                                   capture_output=True, text=True, timeout=3)
                for line in r.stdout.splitlines()[1:]:
                    parts = line.split()
                    if len(parts) < 3:
                        continue
                    pid, tty, comm = parts[0], parts[1], ' '.join(parts[2:])
                    if 'codex' in comm.lower() and tty != '??':
                        live.append({'pid': pid, 'tty': tty, 'comm': comm})
            except Exception:
                pass
            with open(STATUS_PATH, 'w') as f:
                json.dump({'sessions': sessions, 'live_processes': live, 'updated_at': time.time()}, f, indent=2)
        except Exception:
            pass

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

    async def _discover_active_processes(self):
        """Scan for running codex processes via the list_terminal_sessions MCP tool."""
        if os.environ.get('ASK_SKIP_DISCOVERY'):
            return
        # Try the MCP tool first, fall back to ps+lsof
        mcp_ok = False
        try:
            sessions = await self.list_terminal_sessions(filter='codex')
            if sessions:
                mcp_ok = True
                for s in sessions:
                    pid = s.get('pid')
                    cwd = s.get('cwd', '')
                    tty = s.get('tty', '')
                    if pid and cwd:
                        synthetic_id = f'pid-{pid}'
                        is_new = self._register_session(synthetic_id, cwd)
                        if is_new:
                            print(f'[codex-controller] discovered codex (mcp) pid={pid} cwd={cwd}', file=sys.stderr)
                        if tty and synthetic_id in self._sessions and not self._sessions[synthetic_id].get('tty'):
                            self._sessions[synthetic_id]['tty'] = tty
                            self._save_sessions()
        except Exception:
            pass
        if not mcp_ok:
            await self._discover_via_ps()

    async def _discover_via_ps(self):
        """Scan ps+lsof directly for codex processes — fallback when MCP tool is unavailable."""
        try:
            proc = await asyncio.create_subprocess_exec(
                'ps', '-eo', 'pid,tty,comm',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
            )
            stdout, _ = await proc.communicate()
            candidates = []
            for line in stdout.decode().splitlines()[1:]:
                parts = line.split()
                if len(parts) < 3:
                    continue
                pid_str, tty, comm = parts[0], parts[1], ' '.join(parts[2:])
                if 'codex' in comm.lower() and tty != '??':
                    candidates.append((pid_str, tty))
        except Exception:
            return

        for pid_str, tty_short in candidates:
            synthetic_id = f'pid-{pid_str}'
            # Update TTY if session already tracked without one
            if synthetic_id in self._sessions:
                if tty_short and not self._sessions[synthetic_id].get('tty'):
                    self._sessions[synthetic_id]['tty'] = tty_short
                    self._save_sessions()
                continue
            # Get cwd via lsof
            try:
                lsof = await asyncio.create_subprocess_exec(
                    'lsof', '-p', pid_str, '-a', '-d', 'cwd', '-Fn',
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
                )
                out, _ = await lsof.communicate()
                cwd = None
                for lline in out.decode().splitlines():
                    if lline.startswith('n') and lline[1:].startswith('/'):
                        cwd = lline[1:]
                        break
                if cwd:
                    if self._register_session(synthetic_id, cwd):
                        if synthetic_id in self._sessions:
                            self._sessions[synthetic_id]['tty'] = tty_short
                            self._save_sessions()
                        _log(f'[codex] ps-discovered: pid={pid_str} cwd={cwd} tty={tty_short}')
            except Exception:
                pass

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

    async def _prune_dead_real_sessions(self):
        """Remove hook-registered sessions whose CWD no longer has an active codex process."""
        active = await self.list_terminal_sessions(filter='codex')
        if not active:
            return []
        active_cwds = {s.get('cwd') for s in active if s.get('cwd')}
        dead = []
        for session_id, info in list(self._sessions.items()):
            if session_id.startswith('pid-'):
                continue
            cwd = info.get('cwd', '')
            if cwd and cwd not in active_cwds:
                self._sessions.pop(session_id, None)
                self._working_sessions.discard(session_id)
                dead.append(session_id)
                print(f'[codex-controller] pruned dead session {session_id[:8]} ({cwd})', file=sys.stderr)
        if dead:
            self._save_sessions()
        return dead

    async def _backfill_tmux_targets(self):
        """For sessions that have a TTY but no tmux_target, query tmux list-panes
        to find their pane. This lets us use the reliable tmux send-keys path for
        sessions that were discovered from ps/MCP rather than launched by us."""
        sessions_needing = [
            (sid, info) for sid, info in self._sessions.items()
            if not info.get('tmux_target') and info.get('tty')
        ]
        if not sessions_needing:
            return
        try:
            proc = await asyncio.create_subprocess_exec(
                'tmux', 'list-panes', '-a',
                '-F', '#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await proc.communicate()
        except Exception:
            return
        tty_to_pane: dict = {}
        for line in stdout.decode().splitlines():
            parts = line.strip().split('\t', 1)
            if len(parts) == 2:
                pane_tty, pane_id = parts
                tty_to_pane[pane_tty] = pane_id
                # Also store short form (s003) and medium form (ttys003)
                short = pane_tty.replace('/dev/', '')
                tty_to_pane[short] = pane_id
        changed = False
        for sid, info in sessions_needing:
            tty = info.get('tty', '')
            pane = tty_to_pane.get(tty) or tty_to_pane.get(tty.lstrip('/dev/'))
            if pane:
                info['tmux_target'] = pane
                changed = True
                print(f'[codex-controller] backfilled tmux_target={pane} for {sid}', file=sys.stderr)
                if pane not in self._tmux_monitors:
                    task = asyncio.create_task(self._monitor_tmux_pane(pane))
                    self._tmux_monitors[pane] = task
        if changed:
            self._save_sessions()

    async def _find_tty_for_cwd(self, cwd: str, comm_filter: str):
        """Find the TTY of a running process matching comm_filter in cwd via ps+lsof.
        Returns the short TTY string (e.g. 's003') suitable for /dev/tty{short}."""
        try:
            proc = await asyncio.create_subprocess_exec(
                'ps', '-eo', 'pid,tty,comm',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
            )
            stdout, _ = await proc.communicate()
            candidates = []
            for line in stdout.decode().splitlines()[1:]:
                parts = line.split()
                if len(parts) < 3:
                    continue
                pid_str, tty, comm = parts[0], parts[1], ' '.join(parts[2:])
                if comm_filter.lower() in comm.lower() and tty != '??':
                    candidates.append((pid_str, tty))
            for pid_str, tty in candidates:
                try:
                    lsof = await asyncio.create_subprocess_exec(
                        'lsof', '-p', pid_str, '-a', '-d', 'cwd', '-Fn',
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
                    )
                    out, _ = await lsof.communicate()
                    for lline in out.decode().splitlines():
                        if lline.startswith('n') and lline[1:] == cwd:
                            return tty  # e.g. 's003'
                except Exception:
                    pass
        except Exception:
            pass
        return None

    def _register_session(self, session_id: str, cwd: str):
        if session_id in self._sessions:
            return False
        project = self._project_label(cwd, session_id)
        entry = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
        tmux_target = self._pending_tmux_targets.pop(cwd, None)
        if tmux_target:
            entry['tmux_target'] = tmux_target
        if not session_id.startswith('pid-') and cwd:
            # A real hook-registered session supersedes all old sessions for this CWD
            # (pid-* placeholders AND stale real sessions from previous runs).
            for sid in list(self._sessions.keys()):
                if self._sessions[sid].get('cwd') == cwd:
                    self._sessions.pop(sid)
                    self._recently_launched_cwds.discard(cwd)
                    asyncio.create_task(self.clear_block(self._session_block_id(sid)))
        # Always clear the "Starting Codex…" launching placeholder for this CWD
        asyncio.create_task(self.clear_block(self._launching_block_id(cwd)))
        self._sessions[session_id] = entry
        self._save_sessions()
        return True

    def _handle_session_active(self, msg):
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '') or msg.get('tool_cwd', '')
        tty = msg.get('tty')
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd)
        if tty and session_id in self._sessions:
            self._sessions[session_id]['tty'] = tty
            self._save_sessions()  # persist TTY immediately so it survives restarts
        self._working_sessions.add(session_id)
        if is_new:
            if cwd:
                # Clear loading placeholder and startup prompt blocks
                asyncio.create_task(self.clear_block(self._launching_block_id(cwd)))
                asyncio.create_task(self.clear_block(self._terminal_prompt_block_id(cwd)))
        # Always re-emit so iOS sees is_working=true for every new turn, not just the first
        asyncio.create_task(self._emit_session_block(session_id))
        # Start (or restart) response capture; delay lets tmux backfill run first on new sessions
        self._start_capture(session_id, delay=6 if is_new else 2)

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
        if last_message:
            asyncio.create_task(self._emit_session_block(session_id, last_message=last_message))
        elif tmux_target:
            # Hook didn't provide a message — read it directly from the pane
            asyncio.create_task(self._capture_tmux_once(tmux_target, session_id))
        else:
            asyncio.create_task(self._emit_session_block(session_id))

    async def _emit_session_block(self, session_id: str, last_message: str = '', touch_last_seen: bool = True):
        """touch_last_seen=False during startup re-emit so sessions past SESSION_TTL
        are not artificially kept alive across restarts."""
        if not self._initialized:
            print(f'[codex-controller] skipping session block — not yet initialized', file=sys.stderr)
            return
        session = self._sessions.get(session_id, {})
        if not session.get('tty'):
            # Can't route replies without a TTY — don't surface this session on iOS
            asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
            return
        project = session.get('project', 'Codex')
        cwd = session.get('cwd', '')
        block_id = self._session_block_id(session_id)
        # Fall back to stored last_message so heartbeats / re-emits never clear it.
        if not last_message:
            last_message = session.get('last_message', '')
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
        if value == '__close_session__':
            await self._close_session(session_id)
        elif value:
            await self._route_to_terminal(session_id, value)

    async def _close_session(self, session_id: str):
        """Send Ctrl+C to the terminal running this session, then remove it."""
        session = self._sessions.get(session_id, {})
        tty_short = session.get('tty', '')
        _log(f'[codex] close_session {session_id} tty={tty_short!r}')

        if tty_short:
            if tty_short.startswith('/dev/'):
                full_tty = tty_short
            elif tty_short.startswith('ttys') or tty_short.startswith('ttyp'):
                full_tty = f'/dev/{tty_short}'
            else:
                full_tty = f'/dev/tty{tty_short}'
            safe_tty = full_tty.replace('"', '\\"')
            script = f'''
set targetTTY to "{safe_tty}"
tell application "Terminal"
    repeat with w in every window
        repeat with t in every tab of w
            try
                if tty of t is targetTTY then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    exit repeat
                end if
            end try
        end repeat
    end repeat
end tell
delay 0.3
tell application "System Events"
    keystroke "c" using control down
end tell
delay 0.5
tell application "System Events"
    keystroke "c" using control down
end tell
'''
            try:
                proc = await asyncio.create_subprocess_exec(
                    'osascript', '-e', script,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                _, err = await asyncio.wait_for(proc.communicate(), timeout=8.0)
                if err and err.strip():
                    _log(f'[codex] close_session osascript error: {err.decode().strip()}')
            except Exception as e:
                _log(f'[codex] close_session failed: {e}')

        # Remove from tracked sessions and clear the iOS block
        self._sessions.pop(session_id, None)
        self._working_sessions.discard(session_id)
        self._save_sessions()
        self._write_status()
        block_id = self._session_block_id(session_id)
        self._response_callbacks.pop(block_id, None)
        asyncio.create_task(self.clear_block(block_id))
        asyncio.create_task(self._update_tile())

    @staticmethod
    def _strip_ansi(text: str) -> str:
        import re
        return re.sub(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b\][^\x07]*\x07|\r', '', text)

    @staticmethod
    def _is_codex_idle(content: str) -> bool:
        """True when Codex shows its idle footer.
        Matches variants: ⌃C quit, ^C quit, Ctrl+C quit, ctrl-c quit.
        Terminal.app history uses U+2303 (⌃) not literal caret."""
        import re
        return bool(re.search(r'([⌃\^]C|[Cc]trl[-+][Cc])\s*\w*\s+quit', content))

    @staticmethod
    def _extract_response(content: str) -> str:
        """Extract Codex's response from terminal history.

        Codex renders responses as:
          > First line of response
            continuation line (indented, no > prefix)
            ...
        User input shows as: | user typed text  (or • text)
        Status bar: ... ^C quit ...

        Strategy: trim at the LAST status bar (history may have multiple
        sessions), trim any pending user input line just above it, then
        take from the last '> ' line (inclusive) to the end.
        """
        import re
        clean = MCPClient._strip_ansi(content)
        lines = clean.splitlines()

        # Trim at the LAST idle status bar — search from end so older sessions
        # earlier in history don't confuse us.
        for i in range(len(lines) - 1, -1, -1):
            if re.search(r'([⌃\^]C|[Cc]trl[-+][Cc])\s*\w*\s+quit', lines[i]):
                lines = lines[:i]
                break

        # Remove any current user-input line sitting just above the status bar
        # (Codex shows what the user is typing with | or • prefix)
        for i in range(len(lines) - 1, max(len(lines) - 6, -1), -1):
            stripped = lines[i].strip()
            if stripped and (stripped.startswith('| ') or stripped.startswith('• ')
                             or stripped.startswith('● ')):
                lines = lines[:i]
                break

        # Strip trailing blank lines
        while lines and not lines[-1].strip():
            lines.pop()

        # Find the last "> " prefixed line — the start of Codex's last response
        last_response_start = None
        for i in range(len(lines) - 1, -1, -1):
            stripped = lines[i].strip()
            if stripped.startswith('> ') and len(stripped) > 2:
                last_response_start = i
                break

        if last_response_start is not None:
            # Include the "> " line itself (strip its prefix) plus all continuation lines
            response_lines = [l.rstrip() for l in lines[last_response_start:]]
            if response_lines and response_lines[0].strip().startswith('> '):
                response_lines[0] = response_lines[0].strip()[2:]
            return '\n'.join(response_lines).strip()[:4000]

        # Fallback: take the last paragraph block — consecutive non-empty lines
        # at the bottom of the trimmed content (stops at first blank line going up).
        # Much tighter than taking 40 arbitrary lines.
        result = []
        for i in range(len(lines) - 1, -1, -1):
            stripped = lines[i].strip()
            if not stripped:
                break  # blank line = top of paragraph
            if re.match(r'^[|•●]\s', stripped):
                break  # user-input marker
            result.append(lines[i].rstrip())
        if result:
            result.reverse()
            return '\n'.join(result).strip()[:4000]
        return ''

    def _session_id_for_tmux(self, tmux_target: str) -> Optional[str]:
        """Find the session_id that owns this tmux_target."""
        for sid, info in self._sessions.items():
            if info.get('tmux_target') == tmux_target:
                return sid
        return None

    def _tty_to_full_path(self, tty_short: str) -> str:
        """Normalise a stored tty value to a full /dev/ path."""
        if tty_short.startswith('/dev/'):
            return tty_short
        if tty_short.startswith('ttys') or tty_short.startswith('ttyp'):
            return f'/dev/{tty_short}'
        return f'/dev/tty{tty_short}'

    def _start_capture(self, session_id: str, delay: float = 0):
        """Cancel any in-flight capture for this session and start a fresh one.
        Uses tmux capture-pane when a tmux_target is known; falls back to
        reading Terminal.app history via AppleScript when only a TTY is available."""
        old = self._capture_tasks.pop(session_id, None)
        if old and not old.done():
            old.cancel()
        async def _run():
            if delay:
                await asyncio.sleep(delay)
            info = self._sessions.get(session_id, {})
            tmux_target = info.get('tmux_target')
            if tmux_target:
                await self._capture_tmux_response(tmux_target, session_id)
            elif info.get('tty'):
                full_tty = self._tty_to_full_path(info['tty'])
                await self._capture_terminal_response(session_id, full_tty)
        task = asyncio.create_task(_run())
        self._capture_tasks[session_id] = task

    async def _capture_tmux_once(self, tmux_target: str, session_id: str):
        """Single-shot tmux read — used at session stop or startup when Codex is already idle."""
        try:
            proc = await asyncio.create_subprocess_exec(
                'tmux', 'capture-pane', '-p', '-S', '-300', '-t', tmux_target,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
            content = stdout.decode()
        except Exception:
            asyncio.create_task(self._emit_session_block(session_id))
            return
        response = self._extract_response(content)
        if response:
            print(f'[codex-controller] one-shot capture for {session_id} ({len(response)} chars)', file=sys.stderr)
        asyncio.create_task(self._emit_session_block(session_id, last_message=response))

    async def _capture_tmux_response(self, tmux_target: str, session_id: str):
        """After routing a message, poll until Codex is idle, then emit last_message."""
        # Wait for Codex to start processing
        await asyncio.sleep(2)
        prev_content = ''
        stable_count = 0
        stable_no_idle_count = 0
        for _ in range(180):  # max ~3 min
            await asyncio.sleep(1)
            try:
                # Capture up to 300 lines of history so a long response that
                # scrolled off the visible screen is still included.
                proc = await asyncio.create_subprocess_exec(
                    'tmux', 'capture-pane', '-p', '-S', '-300', '-t', tmux_target,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
                content = stdout.decode()
            except Exception:
                return  # pane gone

            is_idle = self._is_codex_idle(content)
            if content == prev_content:
                stable_count += 1
                if not is_idle:
                    stable_no_idle_count += 1
            else:
                stable_count = 0
                stable_no_idle_count = 0

            # Capture if: idle + stable 2s, OR content has been stable 5s without
            # idle detection (handles cases where status bar format doesn't match).
            if (is_idle and stable_count >= 2) or stable_no_idle_count >= 5:
                response = self._extract_response(content)
                if response:
                    print(f'[codex-controller] captured response for {session_id} ({len(response)} chars, idle={is_idle})', file=sys.stderr)
                    asyncio.create_task(self._emit_session_block(session_id, last_message=response))
                return
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

        # Use the TTY captured at session registration time if available.
        cwd = session.get('cwd', '')
        tty_short = session.get('tty')
        _log(f'[codex] route session={session_id} cwd={cwd!r} stored_tty={tty_short!r}')

        # Fall back to list_terminal_sessions, then ps+lsof.
        if not tty_short:
            try:
                terminal_sessions = await self.list_terminal_sessions(filter='codex')
                for s in terminal_sessions:
                    if s.get('cwd') == cwd:
                        tty_short = s.get('tty')
                        _log(f'[codex] tty from list_terminal_sessions: {tty_short!r}')
                        break
            except Exception:
                pass

        if not tty_short and cwd:
            tty_short = await self._find_tty_for_cwd(cwd, 'codex')
            _log(f'[codex] tty from ps+lsof: {tty_short!r}')

        # Normalize TTY to full /dev/ path.
        if tty_short:
            if tty_short.startswith('/dev/'):
                full_tty = tty_short
            elif tty_short.startswith('ttys') or tty_short.startswith('ttyp'):
                full_tty = f'/dev/{tty_short}'
            else:
                full_tty = f'/dev/tty{tty_short}'
        else:
            full_tty = None

        # Escape text for AppleScript string literal
        safe_text = text.replace('\\', '\\\\').replace('"', '\\"')

        if full_tty:
            _log(f'[codex] routing via TTY: {full_tty}')
            safe_tty = full_tty.replace('\\', '\\\\').replace('"', '\\"')
            # Use "do script in tab" — sends text directly to the tab by TTY, no focus needed.
            script = f'''set targetTTY to "{safe_tty}"
set inputText to "{safe_text}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        do script inputText in tab i of w
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then
    error "No Terminal tab found for TTY " & targetTTY
end if'''
        else:
            # Fallback: match by CWD path in window title, paste via clipboard
            _log(f'[codex] routing via window title fallback (no TTY)')
            parts = cwd.rstrip('/').split('/') if cwd else []
            path_fragment = '/'.join(parts[-2:]) if len(parts) >= 2 else (parts[-1] if parts else '')
            safe_path = path_fragment.replace('\\', '\\\\').replace('"', '\\"')
            try:
                pbcopy = await asyncio.create_subprocess_exec(
                    'pbcopy', stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await pbcopy.communicate(input=text.encode('utf-8'))
            except Exception as e:
                _log(f'[codex] pbcopy failed: {e}')
                return
            script = f'''set pathFragment to "{safe_path}"
set foundWindow to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in every window
            try
                if name of w contains pathFragment then
                    set index of w to 1
                    activate
                    set foundWindow to true
                    exit repeat
                end if
            end try
        end repeat
        if not foundWindow then activate
    end tell
end if
delay 0.4
tell application "System Events"
    keystroke "v" using command down
    delay 0.4
    keystroke return
end tell'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, err = await asyncio.wait_for(proc.communicate(), timeout=8.0)
            err_str = err.decode().strip() if err else ''
            if proc.returncode != 0 or err_str:
                _log(f'[codex] osascript error (rc={proc.returncode}): {err_str}')
            else:
                _log(f'[codex] osascript succeeded — message delivered to terminal')
                if full_tty:
                    asyncio.create_task(self._capture_terminal_response(session_id, full_tty))
        except Exception as e:
            _log(f'[codex] _route_to_terminal exception: {e}')

    async def _capture_terminal_response(self, session_id: str, full_tty: str):
        """Poll Terminal.app tab contents until Codex finishes responding, then emit."""
        await asyncio.sleep(2)  # let Codex start processing
        self._working_sessions.add(session_id)
        asyncio.create_task(self._emit_session_block(session_id))

        safe_tty = full_tty.replace('"', '\\"')
        # Use history (full buffer) with explicit index — 'contents of t' in a
        # repeat loop returns the object reference, not the text.
        read_script = f'''
tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe_tty}" then
                    return history of tab i of w
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
'''
        prev_content = ''
        stable_count = 0
        stable_no_idle_count = 0
        for _ in range(180):  # max ~3 min
            await asyncio.sleep(1)
            try:
                proc = await asyncio.create_subprocess_exec(
                    'osascript', '-e', read_script,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
                content = stdout.decode()
            except Exception:
                break

            is_idle = self._is_codex_idle(content)
            if content == prev_content:
                stable_count += 1
                if not is_idle:
                    stable_no_idle_count += 1
            else:
                stable_count = 0
                stable_no_idle_count = 0

            if (is_idle and stable_count >= 2) or stable_no_idle_count >= 5:
                self._working_sessions.discard(session_id)
                response = self._extract_response(content)
                if response:
                    _log(f'[codex] captured response for {session_id} ({len(response)} chars, idle={is_idle})')
                    asyncio.create_task(self._emit_session_block(session_id, last_message=response))
                return
            prev_content = content

        self._working_sessions.discard(session_id)

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
        tty = msg.get('tty')
        if not session_id or not tool_name:
            return
        is_new = self._register_session(session_id, cwd)
        if tty and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
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
        # After each tool Codex will produce a response — capture it.
        # Use _start_capture for deduplication: cancels any in-flight capture
        # for this session and starts a fresh one.
        self._start_capture(session_id, delay=2)

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

    async def _read_terminal_content(self, full_tty: str) -> str:
        """Single AppleScript read of Terminal.app tab history for the given TTY.
        Returns empty string on any error."""
        safe_tty = full_tty.replace('"', '\\"')
        script = f'''
tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe_tty}" then
                    return history of tab i of w
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            return stdout.decode()
        except Exception:
            return ''

    async def _poll_idle_sessions(self):
        """Background loop: every 10 s scan all sessions.
        If Codex is idle and the terminal content differs from stored last_message,
        extract and emit an update. Supports both tmux panes and Terminal.app tabs."""
        POLL_INTERVAL = 10
        while True:
            await asyncio.sleep(POLL_INTERVAL)
            if not self._initialized:
                continue
            for session_id, info in list(self._sessions.items()):
                # Skip if a dedicated capture task is already running
                task = self._capture_tasks.get(session_id)
                if task and not task.done():
                    continue
                tmux_target = info.get('tmux_target')
                tty = info.get('tty')
                if not tmux_target and not tty:
                    continue
                # Read terminal content
                if tmux_target:
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            'tmux', 'capture-pane', '-p', '-S', '-300', '-t', tmux_target,
                            stdout=asyncio.subprocess.PIPE,
                            stderr=asyncio.subprocess.DEVNULL,
                        )
                        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
                        content = stdout.decode()
                    except Exception:
                        continue
                else:
                    full_tty = self._tty_to_full_path(tty)
                    content = await self._read_terminal_content(full_tty)
                    if not content:
                        continue
                if not self._is_codex_idle(content):
                    continue
                response = self._extract_response(content)
                if not response:
                    continue
                stored = info.get('last_message', '')
                if response != stored:
                    print(f'[codex-controller] idle poll: updating last_message for {session_id[:8]}', file=sys.stderr)
                    asyncio.create_task(self._emit_session_block(session_id, last_message=response))

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
        await client._discover_active_processes()
        dead = client._prune_dead_pid_sessions()
        dead += await client._prune_dead_real_sessions()
        for session_id in dead:
            try:
                await client.clear_block(client._session_block_id(session_id))
            except Exception:
                pass
        # Backfill TTY for sessions that don't have one yet
        for session_id, info in list(client._sessions.items()):
            if not info.get('tty') and info.get('cwd'):
                tty = await client._find_tty_for_cwd(info['cwd'], 'codex')
                if tty:
                    info['tty'] = tty
        client._write_status()
        for session_id, info in list(client._sessions.items()):
            # Skip re-emit if block was written recently — TTL is SESSION_TTL (3600s),
            # so only re-emit when more than half the TTL has elapsed.
            last_emitted = info.get('last_emitted', 0)
            if time.time() - last_emitted < SESSION_TTL * 0.5:
                continue
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
    asyncio.create_task(client._poll_idle_sessions())

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
