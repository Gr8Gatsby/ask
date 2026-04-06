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

CODEX_CONFIG_PATH    = os.path.expanduser('~/.codex/config.toml')
CODEX_HOOKS_PATH     = os.path.expanduser('~/.codex/hooks.json')
ALLOWLIST_PATH       = os.path.expanduser('~/.ask/codex_allowlist.json')
PERMISSION_MODE_PATH = os.path.expanduser('~/.ask/codex_permission_mode.json')
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
    """Write ~/.codex/hooks.json with absolute paths to our hook scripts.
    All hooks are invoked via 'python3 <path>' to avoid relying on execute
    permission bits, which rsync/unzip may not preserve."""
    py = sys.executable  # same interpreter running this script
    pre    = f'{py} {os.path.join(hooks_dir, "pre_tool_use.py")}'
    post   = f'{py} {os.path.join(hooks_dir, "post_tool_use.py")}'
    start  = f'{py} {os.path.join(hooks_dir, "session_start.py")}'
    stop   = f'{py} {os.path.join(hooks_dir, "session_stop.py")}'
    prompt = f'{py} {os.path.join(hooks_dir, "user_prompt_submit.py")}'

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
            'UserPromptSubmit': [
                {'hooks': [{'type': 'command', 'command': prompt}]}
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
        # session_id -> asyncio.Task — background TTY (Terminal.app) monitors
        self._tty_monitors: dict = {}
        # session_id -> asyncio.Task — active response capture (deduplicated per session)
        self._capture_tasks: dict = {}
        # CWDs the user explicitly launched via Start Session — pid-* sessions only surface for these
        self._recently_launched_cwds: set = set()
        # session_id -> (text, timestamp) — suppresses duplicate routes within 3s
        self._last_routed: dict = {}
        # session_id -> {tool, preview, ts} — current tool being used
        self._current_tools: dict = {}
        # session_id -> [{tool, preview, ts}] — recent tool history
        self._tool_histories: dict = {}
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
            tmux_target = info.get('tmux_target')
            stored_msg = info.get('last_message', '')
            # Ensure prompt monitoring runs for every tmux-tracked session on startup.
            # This lets us detect any TUI prompt the session was already waiting at
            # before the service came online.
            if tmux_target and tmux_target not in self._tmux_monitors:
                task = asyncio.create_task(self._monitor_tmux_pane(tmux_target))
                self._tmux_monitors[tmux_target] = task
            if stored_msg:
                asyncio.create_task(
                    self._emit_session_block(session_id, last_message=stored_msg, touch_last_seen=False)
                )
            elif tmux_target:
                # No stored message — snapshot current terminal content for the session block
                asyncio.create_task(self._capture_tmux_once(tmux_target, session_id))
            else:
                asyncio.create_task(
                    self._emit_session_block(session_id, touch_last_seen=False)
                )
        asyncio.create_task(self._emit_start_session_block())

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
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

            elif data.get('type') == 'chat_message':
                session_id = data.get('sessionId', '')
                text = data.get('text', '')
                if session_id and text:
                    print(f'[codex-controller] chat_message sessionId={session_id!r} text={text!r}', file=sys.stderr)
                    if text in self._RESERVED_COMMANDS:
                        # Reserved commands arrive via chat_message for agent_session blocks.
                        # Route them to the session reply handler, not the terminal.
                        asyncio.create_task(self._on_session_reply(session_id, text))
                    else:
                        asyncio.create_task(self._route_to_terminal(session_id, text))

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

    @staticmethod
    def _detect_codex_tui_menu(content: str):
        """Detect any Codex boxed TUI menu: '[ Title ]' header + numbered options.

        Covers /permissions, /model, and any other Codex interactive menus that
        follow the same pattern.

        Returns (title, body, options, current_idx) or None.
        options      — clean labels, descriptions and '(current)' stripped
        current_idx  — 0-based index of the option currently marked with '>'
        """
        import re
        ansi_re = re.compile(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r')
        lines = [ansi_re.sub('', l) for l in content.splitlines()]
        text = '\n'.join(lines)

        # Required footer distinguishes this TUI from other numbered menus
        if 'Press enter to confirm' not in text and 'esc to go back' not in text:
            return None

        # Extract option labels first so we can find the title relative to them.
        # Capture each full option line, then split label from inline description
        # at the first 2+ space gap.
        # Handles "  1. Default   Codex can read..." and "> 2. Full Access (current)   desc"
        # Track which option has the '>' cursor marker.
        # Codex uses '›' (U+203A) as the cursor marker, not '>'.
        # Both are included in the prefix pattern for forward-compatibility.
        option_re = re.compile(r'^([›>\s]*)\d+\.\s+(.+)$', re.MULTILINE)
        options = []
        current_idx = 0
        for m in option_re.finditer(text):
            prefix = m.group(1)
            rest   = m.group(2).strip()
            label  = re.split(r'\s{2,}', rest, maxsplit=1)[0].strip()
            label  = label.replace(' (current)', '').strip()
            if not label:
                continue
            if '›' in prefix or '>' in prefix:
                # If the option already exists (deduplicated from an earlier frame),
                # use its existing index rather than len(options) — which would be
                # out-of-bounds and cause wrong navigation direction.
                current_idx = options.index(label) if label in options else len(options)
            if label not in options:
                options.append(label)

        if len(options) < 2:
            return None

        # Extract title. Try boxed header "[ Title ]" first; fall back to the
        # nearest non-empty, non-option line before the first option.
        box_re = re.compile(r'\[\s+(.+?)\s*\]')
        option_line_re = re.compile(r'^[>\s]*\d+\.\s+')
        title = ''
        for line in lines:
            m = box_re.search(line)
            if m:
                title = m.group(1).strip()
                break
        if not title:
            # Find the first option line's index in `lines`, then scan backward
            for i, line in enumerate(lines):
                if option_line_re.match(line):
                    for j in range(i - 1, -1, -1):
                        candidate = lines[j].strip()
                        if candidate and not option_line_re.match(lines[j]):
                            title = candidate
                            break
                    break
        if not title:
            return None

        return title, '', options, current_idx

    @staticmethod
    def _detect_slash_command_menu(content: str):
        """Detect Codex slash-command autocomplete (visible when user types '/').

        The TUI shows an input line '› /' followed by /command   description rows.
        No numbered options, no '›' on individual commands, no footer — just the list.

        Returns list of (cmd, desc) tuples e.g. [('/model', 'choose...'), ...]
        or None if not detected.
        """
        import re
        ansi_re = re.compile(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r')
        lines = [ansi_re.sub('', l) for l in content.splitlines()]
        text = '\n'.join(lines)

        # Require the slash-command input prompt line
        if not re.search(r'^[›>]\s+/', text, re.MULTILINE):
            return None

        # Match /commandname   description (2+ spaces as separator)
        slash_re = re.compile(r'^\s+(/\w+)\s{2,}(.+)$', re.MULTILINE)
        seen: set = set()
        commands = []
        for cmd, desc in slash_re.findall(text):
            if cmd not in seen:
                seen.add(cmd)
                commands.append((cmd, desc.strip()))

        return commands if len(commands) >= 2 else None

    @staticmethod
    def _detect_toggle_menu(content: str):
        """Detect Codex checkbox/toggle TUI (e.g. /experimental).

        Uses '[ ]' / '[x]' option format and footer
        'Press space to select or enter to save'.

        Returns (title, options, current_idx) or None.
        options — list of (label, is_checked) tuples
        current_idx — index of the option under the '›' cursor
        """
        import re
        ansi_re = re.compile(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r')
        lines = [ansi_re.sub('', l) for l in content.splitlines()]
        text = '\n'.join(lines)

        if 'Press space to select' not in text and 'enter to save' not in text:
            return None

        option_re = re.compile(r'^([›>\s]*)\[([x ])\]\s+(.+?)(?:\s{2,}.*)?$', re.MULTILINE)
        options = []
        current_idx = 0
        existing_labels: list = []
        for m in option_re.finditer(text):
            prefix = m.group(1)
            checked = m.group(2).strip() == 'x'
            label = m.group(3).strip()
            if not label:
                continue
            if '›' in prefix or '>' in prefix:
                current_idx = existing_labels.index(label) if label in existing_labels else len(existing_labels)
            if label not in existing_labels:
                existing_labels.append(label)
                options.append((label, checked))

        if not options:
            return None

        # Title: nearest non-option non-empty line above the first option
        option_line_re = re.compile(r'^[›>\s]*\[[x ]]\s+')
        title = ''
        for i, line in enumerate(lines):
            if option_line_re.match(line):
                for j in range(i - 1, -1, -1):
                    candidate = lines[j].strip()
                    if candidate and not option_line_re.match(lines[j]):
                        title = candidate
                        break
                break
        return title or 'Options', options, current_idx

    @staticmethod
    def _detect_codex_permission(content: str):
        """Detect Codex's native 'Would you like to run the following command?' UI.

        Returns (title, body, options, key_map) or None.
        title   — short header for the iOS card
        body    — reason + command shown in the expandable section
        options — clean labels: ['Yes', 'Always Allow', 'No']
        key_map — {label: tmux_key_string} e.g. {'Yes': 'y', 'No': 'Escape'}
        """
        import re
        ansi_re = re.compile(r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r')
        lines = [ansi_re.sub('', l) for l in content.splitlines()]
        text = '\n'.join(lines)

        # Must contain the Codex permission header
        if 'Would you like to run the following command' not in text:
            return None

        # Extract Reason
        reason = ''
        reason_m = re.search(r'Reason:\s*(.+?)(?=\n\s*\n|\n\s*\$|\Z)', text, re.DOTALL)
        if reason_m:
            reason = ' '.join(reason_m.group(1).split())

        # Extract $ command line
        command = ''
        cmd_m = re.search(r'^\s*\$\s+(.+)$', text, re.MULTILINE)
        if cmd_m:
            command = cmd_m.group(1).strip()

        # Must have the numbered options
        if not re.search(r'1\.\s+Yes', text):
            return None

        body_parts = []
        if reason:
            body_parts.append(reason)
        if command:
            body_parts.append(f'$ {command}')
        body = '\n'.join(body_parts)

        options   = ['Yes', 'Always Allow', 'No']
        key_map   = {'Yes': 'y', 'Always Allow': 'p', 'No': 'Escape'}
        return 'Allow command?', body, options, key_map

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

            tui_menu   = self._detect_codex_tui_menu(content)
            codex_perm = None if tui_menu else self._detect_codex_permission(content)
            generic    = None if (tui_menu or codex_perm) else self._parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if tui_menu or codex_perm or generic:
                idle_streak = 0
                poll_interval = 1
                if content_hash != last_hash:
                    last_hash = content_hash
                    session_id = self._session_id_for_tmux(tmux_target) or ''
                    if tui_menu:
                        title, body, options, current_idx = tui_menu
                        # Sync mode file from the '>' cursor so the iOS pill stays accurate
                        # even when the user changed permissions outside of the app.
                        if title == 'Update Model Permissions' and options:
                            selected = options[current_idx] if current_idx < len(options) else ''
                            mode = 'full-auto' if 'Full Access' in selected else 'supervised'
                            self._save_permission_mode(mode)
                            if session_id:
                                asyncio.create_task(self._emit_session_block(session_id))
                        captured = (tmux_target, options, current_idx, block_id, session_id, title)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_codex_tui_menu_reply(c[0], c[1], c[2], v, c[3], c[4], c[5])
                        )
                        payload = {'title': title, 'body': body, 'options': options}
                        if session_id:
                            payload['session_id'] = session_id
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            print(f'[codex-controller] tui menu "{title}" surfaced for {tmux_target}', file=sys.stderr)
                        except Exception as e:
                            print(f'[codex-controller] tui menu emit failed: {e}', file=sys.stderr)
                    # In full-auto mode, silently approve Codex's native permission UI
                    elif codex_perm and self._load_permission_mode() == 'full-auto':
                        _, _, _, key_map = codex_perm
                        asyncio.create_task(
                            self._on_codex_permission_reply(tmux_target, [], key_map, 'Yes', block_id)
                        )
                    elif codex_perm:
                        title, body, options, key_map = codex_perm
                        captured = (tmux_target, options, key_map, block_id)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_codex_permission_reply(c[0], c[1], c[2], v, c[3])
                        )
                        payload = {'title': title, 'body': body, 'options': options}
                        if session_id:
                            payload['session_id'] = session_id
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            print(f'[codex-controller] codex permission surfaced for {tmux_target}', file=sys.stderr)
                        except Exception as e:
                            print(f'[codex-controller] tmux prompt emit failed: {e}', file=sys.stderr)
                    else:
                        body, options = generic
                        captured = (tmux_target, options, block_id)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_tmux_prompt_reply(c[0], c[1], v, c[2])
                        )
                        payload = {'title': body, 'body': '', 'options': options}
                        if session_id:
                            payload['session_id'] = session_id
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            print(f'[codex-controller] generic prompt surfaced for {tmux_target}', file=sys.stderr)
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

    async def _capture_tty_content(self, full_tty: str) -> str:
        """Read current terminal state for TUI detection.

        Uses `history of t` — the same property the TTY monitor uses successfully —
        but returns only the last 30 lines.  This eliminates stale '>' cursor markers
        from earlier TUI renders that would cause current_idx detection to lie.
        30 lines is well above the ~10 lines a Codex TUI menu occupies.
        """
        safe_tty = full_tty.replace('"', '\\"')
        script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe_tty}" then
                    return history of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            return MCPClient._strip_ansi(stdout.decode(errors='replace'))
        except Exception:
            return ''

    async def _run_tty_monitor(self, session_id: str, full_tty: str):
        """Persistent monitor for Terminal.app (non-tmux) sessions.

        Polls the Terminal tab matching `full_tty` every 1.5s via osascript,
        detects any Codex boxed TUI menu or native permission prompt, and
        surfaces them to iOS as confirmation cards — identical to what
        _run_tmux_monitor does for tmux sessions.
        """
        import hashlib as _hl
        safe_tty = full_tty.replace('"', '\\"')
        read_script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe_tty}" then
                    return history of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
        block_id = f'codex-tty-tui-{session_id[:8]}'
        last_hash = ''
        poll_interval = 1.5

        while True:
            await asyncio.sleep(poll_interval)
            # Stop if session gone or switched to tmux
            session = self._sessions.get(session_id)
            if not session:
                break
            if session.get('tmux_target'):
                break

            try:
                proc = await asyncio.create_subprocess_exec(
                    'osascript', '-e', read_script,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=6)
                content = MCPClient._strip_ansi(stdout.decode(errors='replace'))
            except Exception:
                continue

            tui_menu   = self._detect_codex_tui_menu(content)
            codex_perm = None if tui_menu else self._detect_codex_permission(content)
            slash_menu = None if (tui_menu or codex_perm) else self._detect_slash_command_menu(content)
            toggle_menu = None if (tui_menu or codex_perm or slash_menu) else self._detect_toggle_menu(content)
            any_detected = tui_menu or codex_perm or slash_menu or toggle_menu
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if any_detected:
                if content_hash != last_hash:
                    last_hash = content_hash
                    if tui_menu:
                        title, body, options, current_idx = tui_menu
                        captured = (full_tty, session_id, options, current_idx, block_id)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_tty_tui_reply(c[0], c[1], c[2], c[3], v, c[4])
                        )
                        payload = {'title': title, 'body': body, 'options': options,
                                   'session_id': session_id}
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            _log(f'[codex] tty tui menu "{title}" surfaced for {session_id[:8]}')
                        except Exception as e:
                            _log(f'[codex] tty tui emit failed: {e}')
                    elif codex_perm and self._load_permission_mode() == 'full-auto':
                        _, _, _, key_map = codex_perm
                        asyncio.create_task(
                            self._on_codex_permission_reply(None, [], key_map, 'Yes', block_id,
                                                            full_tty=full_tty)
                        )
                    elif codex_perm:
                        title, body, options, key_map = codex_perm
                        captured = (None, options, key_map, block_id, full_tty)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_codex_permission_reply(
                                c[0], c[1], c[2], v, c[3], full_tty=c[4])
                        )
                        payload = {'title': title, 'body': body, 'options': options,
                                   'session_id': session_id}
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            _log(f'[codex] tty permission prompt surfaced for {session_id[:8]}')
                        except Exception as e:
                            _log(f'[codex] tty permission emit failed: {e}')
                    elif slash_menu:
                        cmd_names = [cmd for cmd, _ in slash_menu]
                        cmd_descs = {cmd: desc for cmd, desc in slash_menu}
                        captured = (full_tty, session_id, block_id)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_tty_slash_command_reply(c[0], c[1], v, c[2])
                        )
                        # Surface as confirmation card; options are the command names
                        options_with_desc = [f'{cmd}  {cmd_descs[cmd]}' for cmd in cmd_names]
                        payload = {'title': 'Slash Commands', 'body': '',
                                   'options': cmd_names,
                                   'session_id': session_id}
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=120, inbox=True)
                            _log(f'[codex] tty slash commands surfaced ({len(cmd_names)}) for {session_id[:8]}')
                        except Exception as e:
                            _log(f'[codex] tty slash emit failed: {e}')
                    elif toggle_menu:
                        title, tog_options, current_idx = toggle_menu
                        # Surface labels with checked state visible
                        option_labels = [f'{"[x]" if chk else "[ ]"} {lbl}' for lbl, chk in tog_options]
                        plain_labels  = [lbl for lbl, _ in tog_options]
                        captured = (full_tty, session_id, plain_labels, current_idx, block_id)
                        self._response_callbacks[block_id] = (
                            lambda v, c=captured: self._on_tty_toggle_reply(
                                c[0], c[1], c[2], c[3],
                                # strip checkbox prefix the user sees
                                v.split('] ', 1)[-1] if '] ' in v else v,
                                c[4])
                        )
                        payload = {'title': title, 'body': '',
                                   'options': option_labels,
                                   'session_id': session_id}
                        try:
                            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                            _log(f'[codex] tty toggle menu "{title}" surfaced for {session_id[:8]}')
                        except Exception as e:
                            _log(f'[codex] tty toggle emit failed: {e}')
            else:
                if last_hash:
                    last_hash = ''
                    self._response_callbacks.pop(block_id, None)
                    asyncio.create_task(self.clear_block(block_id))

        self._tty_monitors.pop(session_id, None)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    async def _tty_focus_and_key(self, full_tty: str, key_code: int) -> bool:
        """Focus the Terminal tab and send one key code in a single osascript call.

        Combining focus + keystroke in one script eliminates the Python async gap
        that would otherwise let Terminal lose keyboard focus before the key arrives.
        The keystroke is sent to the frontmost application (Terminal, just activated)
        rather than via 'tell process "Terminal"' which can bypass PTY forwarding.
        Returns True if the tab was found and the keystroke was sent.
        """
        safe_tty = full_tty.replace('"', '\\"')
        script = f'''set targetTTY to "{safe_tty}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then return false
delay 0.3
tell application "System Events"
    key code {key_code}
end tell
return true'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
            return stdout.decode().strip() == 'true'
        except Exception:
            return False

    async def _tty_focus_and_type(self, full_tty: str, text: str) -> bool:
        """Focus the Terminal tab, clear the current input line (Ctrl+U), type text, Enter.

        Used for slash command selection: clear whatever is in the prompt, type
        the full command name (e.g. '/permissions'), and press Enter.
        """
        safe_tty = full_tty.replace('"', '\\"')
        # Escape for AppleScript string literal: backslash and double-quote
        safe_text = text.replace('\\', '\\\\').replace('"', '\\"')
        script = f'''set targetTTY to "{safe_tty}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then return false
delay 0.3
tell application "System Events"
    keystroke "u" using {{control down}}
    delay 0.1
    keystroke "{safe_text}"
    delay 0.05
    key code 36
end tell
return true'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
            return stdout.decode().strip() == 'true'
        except Exception:
            return False

    async def _on_tty_slash_command_reply(self, full_tty: str, session_id: str,
                                           command: str, block_id: str):
        """Handle iOS selection from a slash command card.
        Clears the current terminal input and types the full command + Enter.
        """
        _log(f'[codex] tty slash command reply: {command!r} for {session_id[:8]}')
        ok = await self._tty_focus_and_type(full_tty, command)
        if ok:
            _log(f'[codex] tty slash command submitted: {command!r}')
        else:
            _log(f'[codex] tty slash command submit failed for {session_id[:8]}')
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    async def _on_tty_toggle_reply(self, full_tty: str, session_id: str,
                                    options: list, current_idx: int, value: str, block_id: str):
        """Handle iOS selection from a checkbox/toggle TUI card.
        Navigates to the chosen option, presses Space to toggle, then Enter to save.
        options — list of label strings (checkbox state stripped)
        """
        try:
            target_idx = options.index(value)
        except ValueError:
            return

        async def cleanup():
            self._response_callbacks.pop(block_id, None)
            try:
                await self.clear_block(block_id)
            except Exception:
                pass

        content = await self._capture_tty_content(full_tty)
        detected = self._detect_toggle_menu(content) if content else None
        if not detected:
            _log(f'[codex] tty toggle reply: menu not found, aborting')
            await cleanup()
            return
        _, det_options, pos = detected
        det_labels = [o[0] for o in det_options]

        focused = await self._tty_focus_tab_internal(full_tty)
        if not focused:
            await cleanup()
            return
        await asyncio.sleep(0.5)

        # Navigate one step at a time (same approach as numbered menus)
        max_steps = len(options) + 2
        for step in range(max_steps):
            if pos == target_idx:
                break
            key_code = 125 if pos < target_idx else 126
            ok = await self._tty_focus_and_key(full_tty, key_code)
            if not ok:
                await cleanup()
                return
            await asyncio.sleep(0.8)
            content = await self._capture_tty_content(full_tty)
            detected = self._detect_toggle_menu(content) if content else None
            if not detected:
                await cleanup()
                return
            _, det_options, pos = detected
            _log(f'[codex] tty toggle nav step={step} pos={pos} target={target_idx}')
        else:
            await cleanup()
            return

        # Space to toggle, then Enter to save
        await self._tty_focus_and_key(full_tty, 49)  # Space
        await asyncio.sleep(0.3)
        await self._tty_focus_and_key(full_tty, 36)  # Enter
        _log(f'[codex] tty toggle submitted: {value!r} for {session_id[:8]}')
        await cleanup()

    async def _tty_focus_tab_internal(self, full_tty: str) -> bool:
        """Focus the Terminal tab (reuses _tty_focus_and_key with a no-op key, then cancel).
        Actually just duplicates the focus logic without sending a key."""
        safe_tty = full_tty.replace('"', '\\"')
        script = f'''set targetTTY to "{safe_tty}"
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end try
            end repeat
        end repeat
    end tell
end if
return false'''
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            return stdout.decode().strip() == 'true'
        except Exception:
            return False

    async def _on_tty_tui_reply(self, full_tty: str, session_id: str,
                                 options: list, current_idx: int, value: str, block_id: str):
        """Navigate a Codex TUI menu in a Terminal.app (non-tmux) session.

        Correct strategy:
          1. Read terminal state FIRST (no focus needed for reading) to find
             the actual cursor position from the last 30 lines of history.
          2. If already at target — focus + submit immediately.
          3. Otherwise navigate one step (focus + key in one osascript call),
             wait for the TUI to re-render, read again, repeat.
          4. Only press Enter after a read confirms the cursor is on the target.
        """
        try:
            target_idx = options.index(value)
        except ValueError:
            return

        async def cleanup():
            self._response_callbacks.pop(block_id, None)
            try:
                await self.clear_block(block_id)
            except Exception:
                pass

        # Step 1: read current position BEFORE touching focus or sending any keys
        content = await self._capture_tty_content(full_tty)
        detected = self._detect_codex_tui_menu(content) if content else None
        if not detected:
            _log(f'[codex] tty tui reply: TUI not found before navigation, aborting')
            await cleanup()
            return
        _, _, _, pos = detected
        _log(f'[codex] tty tui: initial pos={pos} target={target_idx}')

        # Steps 2-3: navigate one step at a time, each step atomically focused
        max_steps = len(options) + 2
        for step in range(max_steps):
            if pos == target_idx:
                break
            key_code = 125 if pos < target_idx else 126  # Down=125, Up=126
            ok = await self._tty_focus_and_key(full_tty, key_code)
            if not ok:
                _log(f'[codex] tty tui: focus+key failed at step={step}, aborting')
                await cleanup()
                return
            await asyncio.sleep(0.8)  # let TUI re-render before re-reading
            content = await self._capture_tty_content(full_tty)
            detected = self._detect_codex_tui_menu(content) if content else None
            if not detected:
                _log(f'[codex] tty tui: TUI gone at step={step}, aborting')
                await cleanup()
                return
            _, _, _, pos = detected
            _log(f'[codex] tty nav step={step} new pos={pos} target={target_idx}')
        else:
            _log(f'[codex] tty tui: max steps reached without reaching target, aborting')
            await cleanup()
            return

        # Step 4: cursor confirmed at target — submit with focus + Enter atomically
        ok = await self._tty_focus_and_key(full_tty, 36)  # Return=36
        if ok:
            _log(f'[codex] tty tui submitted: {value!r} for {session_id[:8]}')
        else:
            _log(f'[codex] tty tui: submit focus failed for {session_id[:8]}')
        await cleanup()

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

    async def _on_codex_permission_reply(self, tmux_target: str, options: list,
                                          key_map: dict, value: str, block_id: str):
        """Route a Codex-native permission response using direct letter keys."""
        key = key_map.get(value)
        if not key:
            return
        try:
            p = await asyncio.create_subprocess_exec(
                'tmux', 'send-keys', '-t', tmux_target, key,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await p.communicate()
            # 'Escape' doesn't need Enter; letter keys (y/p) need Enter to confirm
            if key != 'Escape':
                await asyncio.sleep(0.1)
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
        except Exception as e:
            print(f'[codex-controller] codex permission reply failed: {e}', file=sys.stderr)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass
        session_id = self._session_id_for_tmux(tmux_target)
        if session_id:
            asyncio.create_task(self._capture_tmux_response(tmux_target, session_id))

    async def _on_codex_tui_menu_reply(self, tmux_target: str, options: list,
                                       current_idx: int, value: str, block_id: str,
                                       session_id: str, menu_title: str):
        """Navigate a Codex TUI menu with arrow keys and confirm with Enter."""
        try:
            target_idx = options.index(value)
        except ValueError:
            return
        try:
            steps = target_idx - current_idx
            arrow = 'Down' if steps > 0 else 'Up'
            for _ in range(abs(steps)):
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, arrow,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
                await asyncio.sleep(0.05)
            p = await asyncio.create_subprocess_exec(
                'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await p.communicate()
        except Exception as e:
            print(f'[codex-controller] tui menu reply failed: {e}', file=sys.stderr)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass
        # For the permissions menu, sync the controller mode file so the iOS pill updates
        if menu_title == 'Update Model Permissions':
            mode = 'full-auto' if 'Full Access' in value else 'supervised'
            self._save_permission_mode(mode)
        if session_id:
            asyncio.create_task(self._emit_session_block(session_id))
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
                        await self.emit_block(prompt_block_id, 'confirmation', payload, ttl=300, inbox=True)
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
                        live.append({'pid': pid, 'tty': tty, 'comm': comm, 'name': comm.split('/')[-1]})
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
                        is_new = self._register_session(synthetic_id, cwd, tty=tty)
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
                    if self._register_session(synthetic_id, cwd, tty=tty_short):
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

    def _register_session(self, session_id: str, cwd: str, tty: str = ''):
        if session_id in self._sessions:
            return False
        # pid-* sessions are discovery placeholders. Skip if a real (hook-registered)
        # session already exists for the same CWD or TTY — the real session wins.
        if session_id.startswith('pid-') and cwd:
            for sid, info in self._sessions.items():
                if sid.startswith('pid-'):
                    continue
                if info.get('cwd') == cwd:
                    return False
                if tty and info.get('tty') == tty:
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
        # Start persistent TTY monitor for non-tmux sessions so any TUI menu is surfaced to iOS
        session_info = self._sessions.get(session_id, {})
        tty_val = tty or session_info.get('tty', '')
        if tty_val and not session_info.get('tmux_target') and session_id not in self._tty_monitors:
            full_tty = self._tty_to_full_path(tty_val)
            if full_tty:
                task = asyncio.create_task(self._run_tty_monitor(session_id, full_tty))
                self._tty_monitors[session_id] = task

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
        self._current_tools.pop(session_id, None)
        # Cancel any pane/TTY monitors for this session
        tmux_target = self._sessions.get(session_id, {}).get('tmux_target')
        if tmux_target:
            task = self._tmux_monitors.pop(tmux_target, None)
            if task:
                task.cancel()
        tty_task = self._tty_monitors.pop(session_id, None)
        if tty_task:
            tty_task.cancel()
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
        payload['permission_mode'] = self._load_permission_mode()
        activity = self._current_tools.get(session_id)
        if activity and session_id in self._working_sessions:
            payload['current_tool'] = activity['tool']
            if activity.get('preview'):
                payload['current_preview'] = activity['preview']
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
        _log(f'[codex] _on_session_reply session={session_id[:8]} value={value!r}')
        block_id = self._session_block_id(session_id)
        self._response_callbacks[block_id] = lambda v: self._on_session_reply(session_id, v)
        if value == '__close_session__':
            await self._close_session(session_id)
        elif value == '__permissions__':
            await self._send_permissions_command(session_id)
        elif value in ('__full_auto__', '__supervised__'):
            mode = 'full-auto' if value == '__full_auto__' else 'supervised'
            self._save_permission_mode(mode)
            asyncio.create_task(self._emit_session_block(session_id))
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
        """True when Codex is waiting for user input.

        Modern npm Codex (v0.100+) shows an idle state with:
          > [optional text]          ← input prompt line
          gpt-X.X default · N% left ← status bar

        Older Codex shows ⌃C quit in the footer.
        Permission prompts show | Allow...? lines.
        Check the last 6 non-empty lines for any of these patterns.
        """
        import re
        clean = MCPClient._strip_ansi(content)
        lines = [l for l in clean.splitlines() if l.strip()]
        if not lines:
            return False
        tail = lines[-6:]
        for line in tail:
            s = line.strip()
            # Permission prompt waiting for Allow/Deny
            if re.match(r'^\|', s):
                return True
            # Old Codex quit footer
            if re.search(r'([⌃\^]C|[Cc]trl[-+][Cc])\s*\w*\s+quit', s):
                return True
            # Modern Codex input prompt (> with optional text)
            if re.match(r'^>\s', s):
                return True
        return False

    @staticmethod
    def _extract_response(content: str) -> str:
        """Extract Codex's last response from terminal history.

        Modern npm Codex terminal structure (bottom to top):
          gpt-X.X default · N% left · ~/path   ← status bar
          > [last user input or empty]           ← input prompt
          [blank]
          Stop hook (completed)                  ← hook notifications
          • Running Stop hook
          [blank]
          • Codex response text                  ← THIS is what we want
            continuation (indented)
          ...

        Strategy:
          1. Strip the modern footer from the bottom up (status bar, input
             prompt, blank lines, hook notifications).
          2. Walk up from the remaining bottom to find the last response block,
             stopping when we hit a previous user-input prompt (> line).
        """
        import re
        clean = MCPClient._strip_ansi(content)
        lines = clean.splitlines()

        # ── Step 1: strip footer from the bottom ──────────────────────────────
        # Patterns to strip: status bar, input prompt, blank lines, hook lines.
        # Keep looping until nothing more matches at the bottom.
        status_bar_re  = re.compile(r'^(gpt|o\d|claude|codex)[-\w.]*\s', re.IGNORECASE)
        input_prompt_re = re.compile(r'^>\s?')
        hook_re        = re.compile(
            r'(Running\s+\w+\s+hook|hook\s+\(completed\)|'
            r'PreToolUse|PostToolUse|SessionStart|UserPromptSubmit)',
            re.IGNORECASE,
        )
        changed = True
        while changed and lines:
            changed = False
            s = lines[-1].strip()
            if not s:
                lines.pop(); changed = True; continue
            if status_bar_re.match(s) and ('%' in s or 'left' in s):
                lines.pop(); changed = True; continue
            if input_prompt_re.match(s):
                lines.pop(); changed = True; continue
            if hook_re.search(s):
                lines.pop(); changed = True; continue
            # Old-style ⌃C quit footer
            if re.search(r'([⌃\^]C|[Cc]trl[-+][Cc])\s*\w*\s+quit', s):
                lines.pop(); changed = True; continue

        if not lines:
            return ''

        # ── Step 2: collect the last response block ────────────────────────────
        # Walk up from the bottom (max 120 lines). Stop at a previous user-input
        # prompt line (> ...) — that's where the prior exchange ended.
        # Skip hook notification lines and decorative separators inline too.
        separator_re = re.compile(r'^[-─━═╌╍\s]+$')
        # Codex startup box marker — if we encounter this we've scrolled past any
        # real response into the boot banner; stop collecting immediately.
        startup_re = re.compile(r'>\s*_?\s*OpenAI Codex|╭──|^\s*\|\s*>_', re.IGNORECASE)
        result = []
        found_prompt = False
        for line in reversed(lines[-120:]):
            s = line.strip()
            if input_prompt_re.match(s):
                found_prompt = True
                break  # hit the previous user input — stop here
            if startup_re.search(s):
                break  # hit startup banner — no real response above this point
            if hook_re.search(s) or (s and separator_re.match(s)):
                continue  # skip hook noise and decorative lines
            result.append(line.rstrip())

        # If we never found a user-prompt boundary, this is startup/initial terminal
        # content with no real response yet — return empty to avoid capturing banners.
        if not found_prompt:
            return ''

        if result:
            result.reverse()
            # Drop leading blank lines
            while result and not result[0].strip():
                result.pop(0)
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

    async def _send_permissions_command(self, session_id: str):
        """Open the Codex permissions menu and surface it to iOS as a selection card.

        Strategy:
          1. Send /permissions to the terminal (tmux or TTY/osascript).
          2. Immediately emit a confirmation card with the known options so iOS
             shows the picker without waiting for terminal detection.
          3. For tmux sessions also poll the pane to read actual current_idx from
             the '>' cursor so the card reflects the real selection state.
        """
        session = self._sessions.get(session_id, {})
        tmux_target = session.get('tmux_target')
        _log(f'[codex] _send_permissions_command session={session_id[:8]} tmux={tmux_target!r}')

        # Ensure the tmux monitor is running if we have a pane target.
        if tmux_target and tmux_target not in self._tmux_monitors:
            task = asyncio.create_task(self._monitor_tmux_pane(tmux_target))
            self._tmux_monitors[tmux_target] = task

        # Route /permissions to the terminal.
        await self._route_to_terminal(session_id, '/permissions')

        # Known Codex permissions options — always the same two choices.
        options = ['Default', 'Full Access']
        current_mode = self._load_permission_mode()
        current_idx = 1 if current_mode == 'full-auto' else 0

        block_id = (self._tmux_prompt_block_id(tmux_target) if tmux_target
                    else f'codex-perms-{session_id[:8]}-{int(time.time())}')

        # Register reply handler.  For tmux sessions the handler navigates with
        # arrow keys; for TTY sessions it uses osascript key codes.
        captured = (tmux_target, session_id, options, current_idx, block_id)
        self._response_callbacks[block_id] = (
            lambda v, c=captured: self._on_permissions_reply(c[0], c[1], c[2], c[3], v, c[4])
        )

        # For tmux sessions, briefly poll the pane to pick up the actual current_idx
        # from the '>' cursor before emitting (best-effort; emit immediately if no TUI).
        if tmux_target:
            for delay in (0.35, 0.7, 1.5):
                await asyncio.sleep(delay)
                try:
                    proc = await asyncio.create_subprocess_exec(
                        'tmux', 'capture-pane', '-p', '-t', tmux_target,
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                    )
                    stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
                    content = stdout.decode()
                except Exception:
                    break
                tui = self._detect_codex_tui_menu(content)
                if not tui:
                    continue
                _, _, detected_options, detected_idx = tui
                if detected_options:
                    options = detected_options
                    current_idx = detected_idx
                    # Re-register with updated indices
                    captured = (tmux_target, session_id, options, current_idx, block_id)
                    self._response_callbacks[block_id] = (
                        lambda v, c=captured: self._on_permissions_reply(c[0], c[1], c[2], c[3], v, c[4])
                    )
                break  # emit with whatever we have

        payload = {
            'title': 'Update Model Permissions',
            'body': '',
            'options': [f'{o} (current)' if i == current_idx else o
                        for i, o in enumerate(options)],
            'session_id': session_id,
        }
        try:
            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
            _log(f'[codex] permissions card emitted for {session_id[:8]}')
        except Exception as e:
            _log(f'[codex] permissions card emit failed: {e}')

    async def _on_permissions_reply(self, tmux_target, session_id: str,
                                    options: list, current_idx: int,
                                    value: str, block_id: str):
        """Handle the iOS selection from the permissions card.

        Navigates the live Codex TUI to the chosen option using arrow keys + Enter.
        Works for both tmux (send-keys) and TTY (osascript key codes) sessions.
        """
        # Strip the ' (current)' suffix that was added to the card label
        clean_value = value.replace(' (current)', '').strip()
        clean_options = [o.replace(' (current)', '').strip() for o in options]
        try:
            target_idx = clean_options.index(clean_value)
        except ValueError:
            return

        steps = target_idx - current_idx
        _log(f'[codex] permissions reply: {clean_value!r} steps={steps} tmux={tmux_target!r}')

        if tmux_target:
            # tmux path: reset to top then navigate down to target_idx + Enter.
            # Sending Up len(options) times guarantees we're at index 0 regardless
            # of where the cursor actually is (shadow file may be stale).
            try:
                for _ in range(len(options)):
                    p = await asyncio.create_subprocess_exec(
                        'tmux', 'send-keys', '-t', tmux_target, 'Up',
                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                    )
                    await p.communicate()
                    await asyncio.sleep(0.05)
                for _ in range(target_idx):
                    p = await asyncio.create_subprocess_exec(
                        'tmux', 'send-keys', '-t', tmux_target, 'Down',
                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                    )
                    await p.communicate()
                    await asyncio.sleep(0.05)
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
            except Exception as e:
                _log(f'[codex] permissions tmux reply failed: {e}')
        else:
            # TTY path: delegate to _on_tty_tui_reply which focuses the tab,
            # navigates, verifies cursor position, then submits.
            session = self._sessions.get(session_id, {})
            tty_short = session.get('tty', '')
            full_tty = self._tty_to_full_path(tty_short) if tty_short else ''
            if not full_tty:
                _log(f'[codex] permissions TTY reply: no TTY for {session_id[:8]}')
                return
            await self._on_tty_tui_reply(full_tty, session_id, clean_options, current_idx,
                                         clean_value, block_id)
            # Sync mode shadow file and update the iOS pill
            mode = 'full-auto' if 'Full Access' in clean_value else 'supervised'
            self._save_permission_mode(mode)
            asyncio.create_task(self._emit_session_block(session_id))
            return

        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass
        # Sync mode shadow file and update the iOS pill
        mode = 'full-auto' if 'Full Access' in clean_value else 'supervised'
        self._save_permission_mode(mode)
        asyncio.create_task(self._emit_session_block(session_id))

    _RESERVED_COMMANDS = frozenset({
        '__close_session__', '__permissions__', '__full_auto__', '__supervised__',
    })

    async def _route_to_terminal(self, session_id: str, text: str):
        """Route text to the terminal running this session.
        Uses tmux send-keys for tmux-launched sessions; clipboard+osascript otherwise."""
        # Never forward internal control commands — they should only arrive via
        # the block-response path and be handled by _on_session_reply.
        if text in self._RESERVED_COMMANDS:
            _log(f'[codex] reserved command {text!r} dropped from terminal route')
            return
        # Deduplicate: iOS sends both a chat_message notification and a user_response
        # block reply for the same user input. Suppress the second arrival within 3s.
        now = time.time()
        last = self._last_routed.get(session_id)
        if last and last[0] == text and now - last[1] < 3.0:
            _log(f'[codex] duplicate route suppressed for session {session_id[:8]}')
            return
        self._last_routed[session_id] = (text, now)

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
            # Use System Events keystroke to type text + Return.
            # Direct PTY writes (slave fd) interact poorly with npm Codex's raw-mode
            # TUI — ghost suggestions get mixed in and Enter may not register.
            # System Events simulates real OS-level keyboard events which work
            # correctly with any interactive TUI application.
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
                        set selected tab of w to t
                        set index of w to 1
                        activate
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
end if
delay 0.25
tell application "System Events"
    keystroke inputText
    delay 0.1
    keystroke return
end tell'''
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
        delivered = False
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
                # Accessibility permission revoked (error 1002) — fall back to TIOCSTI
                if full_tty and ('1002' in err_str or 'not allowed to send keystrokes' in err_str):
                    _log(f'[codex] falling back to TIOCSTI for {full_tty}')
                    delivered = await self._write_tiocsti(full_tty, text)
            else:
                _log(f'[codex] osascript succeeded — message delivered to terminal')
                delivered = True
        except Exception as e:
            _log(f'[codex] _route_to_terminal exception: {e}')
        if delivered and full_tty:
            asyncio.create_task(self._capture_terminal_response(session_id, full_tty))

    async def _write_tiocsti(self, full_tty: str, text: str) -> bool:
        """Stuff text + newline into a TTY input queue via TIOCSTI ioctl.
        Works without Accessibility permission. Requires the calling process
        to own the TTY (same user). Returns True on success."""
        try:
            import fcntl, termios
            fd = os.open(full_tty, os.O_RDWR | os.O_NOCTTY)
            for byte in (text + '\n').encode('utf-8'):
                fcntl.ioctl(fd, termios.TIOCSTI, bytes([byte]))
            os.close(fd)
            _log(f'[codex] TIOCSTI delivered {len(text)} chars to {full_tty}')
            return True
        except Exception as e:
            _log(f'[codex] TIOCSTI failed: {e}')
            return False

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
                # In full-auto mode auto-approve without routing to iOS
                if self._load_permission_mode() == 'full-auto':
                    response = {'value': 'Allow'}
                else:
                    response = await self._handle_blocking(
                        writer,
                        self._build_permission_block(msg),
                        default='Deny',
                    )
                if response.get('value') == 'Always Allow':
                    self._add_to_allowlist(msg.get('preview', ''))
                    response = {'value': 'Allow'}
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

            elif msg_type == 'user_prompt_submit':
                self._handle_user_prompt_submit(msg)

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
        # Update live tool activity so the session subtitle shows the pending tool
        if session_id and session_id in self._sessions:
            entry = {'tool': tool, 'preview': preview, 'ts': time.time()}
            self._current_tools[session_id] = entry
            history = self._tool_histories.setdefault(session_id, [])
            history.append(entry)
            if len(history) > 20:
                del history[:-20]
            asyncio.create_task(self._emit_session_block(session_id))
        try:
            await self.emit_block(block_id, 'confirmation', payload, inbox=True)
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

    def _handle_user_prompt_submit(self, msg):
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        prompt = msg.get('prompt', '').strip()
        if not session_id:
            return
        self._register_session(session_id, cwd)
        self._working_sessions.add(session_id)
        prompt_label = f'You: {prompt[:120]}' if prompt else ''
        asyncio.create_task(self._emit_session_block(session_id, last_message=prompt_label))

    def _load_permission_mode(self) -> str:
        try:
            with open(PERMISSION_MODE_PATH) as f:
                return json.load(f).get('mode', 'supervised')
        except Exception:
            return 'supervised'

    def _save_permission_mode(self, mode: str):
        try:
            os.makedirs(os.path.dirname(PERMISSION_MODE_PATH), exist_ok=True)
            with open(PERMISSION_MODE_PATH, 'w') as f:
                json.dump({'mode': mode}, f)
            _log(f'[codex] permission mode → {mode!r}')
        except Exception as e:
            _log(f'[codex] permission mode save failed: {e}')

    def _add_to_allowlist(self, pattern: str):
        pattern = pattern.strip()
        if not pattern:
            return
        try:
            if os.path.exists(ALLOWLIST_PATH):
                with open(ALLOWLIST_PATH) as f:
                    data = json.load(f)
            else:
                data = {'patterns': []}
            patterns = data.get('patterns', [])
            if pattern not in patterns:
                patterns.append(pattern)
                data['patterns'] = patterns
                os.makedirs(os.path.dirname(ALLOWLIST_PATH), exist_ok=True)
                with open(ALLOWLIST_PATH, 'w') as f:
                    json.dump(data, f, indent=2)
                _log(f'[codex] added to allowlist: {pattern!r}')
        except Exception as e:
            _log(f'[codex] allowlist write failed: {e}')

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
