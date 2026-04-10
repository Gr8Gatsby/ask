#!/usr/bin/env python3
"""
claudecode-controller — MCP client bridging Claude Code hooks to the Ask iOS app.

Protocol:
  - Reads JSON-RPC 2.0 from stdin  (daemon → script)
  - Writes JSON-RPC 2.0 to stdout  (script → daemon)
  - Listens on a Unix socket for hook scripts
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
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

SOCKET_PATH    = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claudecode-controller.sock'))
BLOCK_TILE     = 'claudecode-controller-tile'
SESSIONS_PATH  = os.environ.get('ASK_SESSIONS_PATH', os.path.expanduser('~/.ask/claudecode_sessions.json'))
STATUS_PATH    = os.path.expanduser('~/.ask/status/claudecode-controller.json')
LOG_PATH       = os.path.expanduser('~/.ask/logs/claudecode-controller.log')
SESSION_BLOCK_TTL = 3600   # seconds — how long an agent_session block lives in CloudKit
SESSION_DISK_TTL  = 86400  # seconds — how long sessions are kept in the on-disk registry
SESSION_TTL       = SESSION_BLOCK_TTL  # backward-compat alias


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


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}      # rpc_id  -> asyncio.Future (tool call responses)
        self._pending_blocks = {}     # block_id -> asyncio.Queue (blocking waiters)
        self._response_callbacks = {} # block_id -> async callable(value)
        # session_id -> {'cwd': str, 'project': str, 'last_message': str}
        self._sessions: dict = {}
        # session IDs where Claude is actively running (PostToolUse fired, Stop hasn't yet)
        self._working_sessions: set = set()
        self._current_tools: dict = {}        # session_id -> {tool, preview, ts}
        self._tool_histories: dict = {}        # session_id -> [{tool, preview, ts}, ...] last 20
        self._pending_activity_emits: dict = {} # session_id -> debounce Task
        # (session_id, tool_name) -> [block_id, ...] — cleared when the tool runs
        self._tool_block_map = {}
        # cwd -> tmux window target (e.g. "0:2") for sessions launched via tmux
        self._pending_tmux_targets: dict = {}
        # tmux_target -> asyncio.Task — background pane monitors
        self._tmux_monitors: dict = {}
        # session_id -> asyncio.Task — TTY session prompt monitors
        self._tty_monitors: dict = {}
        # CWDs the user explicitly launched via Start Session — pid-* sessions only surface for these
        self._recently_launched_cwds: set = set()
        # per-session locks so concurrent iOS replies are serialized (prevents clipboard races)
        self._route_locks: dict = {}
        # Tile state
        self._active_confirmations = 0
        self._tile_body: Optional[str] = None
        self._initialized = False  # True after MCP handshake completes
        self._tm_healthy: Optional[bool] = None  # None = unknown, True/False after health check

    # ------------------------------------------------------------------
    # terminal-manager integration helpers
    # ------------------------------------------------------------------

    async def _tm_register(self, session_id: str):
        """Register (or re-register) this session with terminal-manager.

        terminal-manager becomes the single source of truth for routing:
        it handles TTY-based (osascript) and tmux sessions uniformly.
        Called whenever a TTY or tmux_target is first set for a session."""
        session = self._sessions.get(session_id, {})
        tty = session.get('tty', '')
        tmux_target = session.get('tmux_target', '')
        if not tty and not tmux_target:
            return  # nothing to route to yet
        try:
            await self._rpc('tools/call', {
                'name': 'register_session',
                'arguments': {
                    'session_id': session_id,
                    'app_id': 'claudecode-controller',
                    'tty': tty,
                    'tmux_target': tmux_target,
                }
            }, timeout=4.0)
            _log(f'[claudecode] tm_register {session_id[:8]} tty={tty!r} tmux={tmux_target!r}')
        except Exception as e:
            _log(f'[claudecode] tm_register failed: {e}')

    async def _tm_unregister(self, session_id: str):
        """Remove this session from terminal-manager's registry."""
        try:
            await self._rpc('tools/call', {
                'name': 'unregister_session',
                'arguments': {'session_id': session_id}
            }, timeout=4.0)
        except Exception as e:
            _log(f'[claudecode] tm_unregister failed: {e}')

    # ------------------------------------------------------------------
    # MCP outbound helpers
    # ------------------------------------------------------------------

    def _id(self):
        self._next_id += 1
        return self._next_id

    def _write(self, obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method, params=None, timeout: float = 10.0):
        rpc_id = self._id()
        fut = asyncio.get_running_loop().create_future()
        self._pending_calls[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._write(msg)
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending_calls.pop(rpc_id, None)
            raise

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'claudecode-controller', 'version': '1.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self._initialized = True
        print('[claudecode-controller] MCP initialized', file=sys.stderr)
        # Restore sessions from disk, then backfill TTYs BEFORE discovery so that
        # _discover_active_processes sees the real sessions' TTYs and doesn't create duplicates.
        self._load_sessions()
        backfilled = False
        for session_id, info in list(self._sessions.items()):
            if not info.get('tty') and info.get('cwd'):
                tty = await self._find_tty_for_cwd(info['cwd'], 'claude')
                if tty:
                    info['tty'] = tty
                    backfilled = True
                    print(f'[claudecode-controller] startup TTY backfill: {session_id} -> {tty}', file=sys.stderr)
        if backfilled:
            self._save_sessions()
        # Now scan for any claude processes not yet tracked (backfill ensures no duplicates).
        await self._discover_active_processes()
        # Re-register ALL sessions with terminal-manager BEFORE pruning.
        # TM loses its registry on restart; if we prune first, real sessions that
        # haven't re-registered yet look dead and get incorrectly evicted.
        for session_id, info in list(self._sessions.items()):
            if info.get('tty') or info.get('tmux_target'):
                await self._tm_register(session_id)
        dead_pid = self._prune_dead_pid_sessions()
        dead_real = await self._prune_dead_real_sessions()
        for session_id in dead_pid + dead_real:
            asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
        self._write_status()
        # Await session block emits so that _update_tile() (called after initialize())
        # sees the correct last_emitted counts and doesn't show "No sessions".
        for session_id, info in list(self._sessions.items()):
            await self._emit_session_block(session_id, last_message=info.get('last_message', ''), touch_last_seen=False)
        await self._emit_start_session_block()
        await self._emit_diagnostics_block()
        # Check terminal-manager is reachable
        try:
            await asyncio.wait_for(
                self._rpc('tools/call', {'name': 'list_sessions', 'arguments': {}}),
                timeout=5.0
            )
            self._tm_healthy = True
            _log('[claudecode] terminal-manager: reachable')
        except Exception as tm_err:
            self._tm_healthy = False
            _log(f'[claudecode] terminal-manager: unreachable ({tm_err})')
            await self.emit_block('claudecode-tm-diagnostic', 'alert', {
                'title': 'terminal-manager not running',
                'body': 'TUI detection and keyboard input are unavailable. Start the terminal-manager script to enable interactive prompts.',
            }, ttl=300)
        asyncio.create_task(self._session_keepalive())

    async def _session_keepalive(self):
        """Re-emit session blocks and refresh last_seen every 30 minutes.

        Two jobs:
        1. Disk freshness — updates last_seen so sessions survive daemon restarts
           across the 24-hour SESSION_DISK_TTL window.
        2. Block freshness — re-emits any agent_session block whose last_emitted is
           more than half SESSION_BLOCK_TTL ago, preventing CloudKit TTL expiry from
           making sessions appear to vanish while the daemon is still running.
           This also recovers blocks that expired during a previous daemon outage."""
        while True:
            await asyncio.sleep(1800)  # 30 minutes
            if not self._sessions:
                continue
            now = time.time()
            stale_threshold = SESSION_BLOCK_TTL / 2  # re-emit at 50% of TTL remaining
            refreshed = 0
            for session_id, info in list(self._sessions.items()):
                if session_id.startswith('pid-'):
                    continue
                info['last_seen'] = now
                last_emitted = info.get('last_emitted', 0)
                if now - last_emitted >= stale_threshold:
                    try:
                        await self._emit_session_block(session_id)
                        refreshed += 1
                    except Exception as e:
                        _log(f'[claudecode] keepalive re-emit failed for {session_id[:8]}: {e}')
            self._save_sessions()
            _log(f'[claudecode] keepalive: refreshed {len(self._sessions)} session(s), re-emitted {refreshed} block(s)')

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        return await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def emit_quick_reply(self, block_id, title, options, description=None,
                               allow_custom=False, urgency='warning', ttl=300):
        """Emit a quick_reply block — compact inline response card shown in the home queue."""
        payload = {'title': title, 'options': options, 'urgency': urgency}
        if description:
            payload['description'] = description
        if allow_custom:
            payload['allow_custom'] = True
        return await self.emit_block(block_id, 'quick_reply', payload, ttl=ttl, inbox=True)

    async def clear_block(self, block_id):
        return await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})

    async def list_terminal_sessions(self, filter: str = '') -> list:
        """Query the daemon for active terminal sessions on this Mac."""
        args = {}
        if filter:
            args['filter'] = filter
        try:
            result = await self._rpc('tools/call', {'name': 'list_sessions', 'arguments': args})
            return result.get('sessions', []) if isinstance(result, dict) else []
        except Exception as e:
            print(f'[claudecode-controller] list_terminal_sessions failed: {e}', file=sys.stderr)
            return []

    async def _update_tile(self):
        """Re-emit the tile block reflecting current state."""
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
            print(f'[claudecode-controller] tile update failed: {e}', file=sys.stderr)

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
            if not raw:  # EOF
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

        # Tool-call response
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

        # Daemon notification — check for user_response or chat_message
        method = msg.get('method', '')
        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            msg_type = data.get('type')

            if msg_type == 'user_response':
                block_id = data.get('blockId', '')
                value = data.get('value', '')

                # Async callback (non-blocking chat replies)
                callback = self._response_callbacks.pop(block_id, None)
                if callback:
                    asyncio.create_task(callback(value))
                    return

                # Blocking waiter (permission_request, question)
                q = self._pending_blocks.get(block_id)
                if q:
                    await q.put(value)

            elif msg_type == 'chat_message':
                session_id = data.get('sessionId', '')
                text = data.get('text', '')
                _log(f'[claudecode] chat_message received session={session_id[:8] if session_id else "?"} len={len(text)}')
                if session_id and text:
                    asyncio.create_task(self._on_session_reply(session_id, text))

    async def wait_for_block_response(self, block_id, timeout=300):
        q = asyncio.Queue()
        self._pending_blocks[block_id] = q
        try:
            return await asyncio.wait_for(q.get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None
        finally:
            self._pending_blocks.pop(block_id, None)

    # ------------------------------------------------------------------
    # Per-session blocks — one agent_session block per active Claude session
    # ------------------------------------------------------------------

    def _session_block_id(self, session_id: str) -> str:
        # Use a hash so sessions with the same prefix don't collide.
        digest = hashlib.sha256(session_id.encode()).hexdigest()[:8]
        return f'claudecode-session-{digest}'

    def _activity_feed_block_id(self, session_id: str) -> str:
        digest = hashlib.sha256(session_id.encode()).hexdigest()[:8]
        return f'claudecode-activity-{digest}'

    def _start_session_block_id(self) -> str:
        return 'claudecode-start-session'

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
        # Include recently-used CWDs from known sessions
        for info in self._sessions.values():
            cwd = info.get('cwd', '')
            if cwd and os.path.isdir(cwd):
                repo_paths.add(cwd)
        # Scan common directories for .git folders
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

    # ------------------------------------------------------------------
    # Diagnostics
    # ------------------------------------------------------------------

    DIAG_BLOCK_ID = 'claudecode-diagnostics'

    def _check_hooks(self) -> list:
        """Return a list of {event, path, ok} dicts for each registered hook."""
        results = []
        try:
            settings_path = os.path.expanduser('~/.claude/settings.json')
            if not os.path.exists(settings_path):
                return [{'event': '(settings.json missing)', 'path': settings_path, 'ok': False}]
            with open(settings_path) as f:
                settings = json.load(f)
            hooks = settings.get('hooks', {})
            for event, blocks in hooks.items():
                for block in blocks:
                    for h in block.get('hooks', []):
                        cmd = h.get('command', '')
                        if 'claudecode-controller' in cmd:
                            results.append({
                                'event': event,
                                'path': cmd,
                                'ok': os.path.exists(cmd),
                            })
        except Exception as e:
            results.append({'event': '(error)', 'path': str(e), 'ok': False})
        return results

    def _tail_log(self, n: int = 10) -> list:
        """Return the last n lines of the log file."""
        try:
            if not os.path.exists(LOG_PATH):
                return []
            with open(LOG_PATH) as f:
                lines = f.readlines()
            return [l.rstrip() for l in lines[-n:]]
        except Exception:
            return []

    async def _emit_diagnostics_block(self):
        """Emit a diagnostics block with hook status, socket state, and recent logs."""
        if not self._initialized:
            return
        import datetime, zipfile

        hooks = self._check_hooks()
        all_ok = all(h['ok'] for h in hooks) and len(hooks) > 0
        socket_ok = os.path.exists(SOCKET_PATH)
        log_lines = self._tail_log(10)

        # Read version from manifest
        try:
            manifest_path = os.path.join(os.path.dirname(__file__), 'manifest.json')
            with open(manifest_path) as f:
                version = json.load(f).get('version', '?')
        except Exception:
            version = '?'

        payload = {
            'version': version,
            'hooks': hooks,
            'hooks_ok': all_ok,
            'socket_ok': socket_ok,
            'log_lines': log_lines,
        }
        self._response_callbacks[self.DIAG_BLOCK_ID] = lambda v: self._on_diagnostics_reply(v)
        try:
            await self.emit_block(self.DIAG_BLOCK_ID, 'diagnostics', payload, ttl=3600)
        except Exception as e:
            print(f'[claudecode-controller] diagnostics emit failed: {e}', file=sys.stderr)

    async def _on_diagnostics_reply(self, value: str):
        """Called when the user taps 'Collect Logs' on iOS."""
        self._response_callbacks[self.DIAG_BLOCK_ID] = lambda v: self._on_diagnostics_reply(v)
        if value == 'collect_logs':
            await self._collect_logs()

    async def _collect_logs(self):
        """Zip the last 24 hours of all script logs into ~/Downloads/ask-logs-{date}.zip."""
        import datetime, zipfile
        now = datetime.datetime.now()
        cutoff = now - datetime.timedelta(hours=24)
        logs_dir = os.path.expanduser('~/.ask/logs')
        downloads = os.path.expanduser('~/Downloads')
        zip_name = f"ask-logs-{now.strftime('%Y-%m-%d')}.zip"
        zip_path = os.path.join(downloads, zip_name)

        try:
            os.makedirs(downloads, exist_ok=True)
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
                if os.path.isdir(logs_dir):
                    for fname in os.listdir(logs_dir):
                        fpath = os.path.join(logs_dir, fname)
                        if not os.path.isfile(fpath):
                            continue
                        # Filter to lines from last 24h
                        try:
                            with open(fpath) as f:
                                lines = f.readlines()
                            recent = []
                            for line in lines:
                                # Lines are prefixed [HH:MM:SS] — filter by file mtime date
                                recent.append(line)
                            # Include file if modified in last 24h
                            mtime = datetime.datetime.fromtimestamp(os.path.getmtime(fpath))
                            if mtime >= cutoff:
                                zf.writestr(fname, ''.join(recent))
                        except Exception:
                            pass
            print(f'[claudecode-controller] logs collected: {zip_path}', file=sys.stderr)
            # Notify iOS
            await self.emit_block(str(uuid.uuid4()), 'notification', {
                'title': 'Logs collected',
                'body': f'Saved to ~/Downloads/{zip_name}',
            }, ttl=300)
            # Refresh diagnostics
            await self._emit_diagnostics_block()
        except Exception as e:
            print(f'[claudecode-controller] collect_logs failed: {e}', file=sys.stderr)

    async def _emit_start_session_block(self):
        """Emit (or refresh) the start_session block containing the repo list."""
        if not self._initialized:
            return
        block_id = self._start_session_block_id()
        repos = self._scan_git_repos()
        payload = {'repos': repos}
        self._response_callbacks[block_id] = lambda v: self._on_start_session_reply(v)
        try:
            # TTL slightly longer than the heartbeat interval (300s) so the button
            # stays visible even if one heartbeat fails, but cleans up if the script stops.
            await self.emit_block(block_id, 'start_session', payload, ttl=620)
        except Exception as e:
            print(f'[claudecode-controller] start_session block emit failed: {e}', file=sys.stderr)

    async def _on_start_session_reply(self, value: str):
        """Called when the user picks a repo path from the iOS start-session sheet."""
        # Re-register immediately so another session can be started right away
        block_id = self._start_session_block_id()
        self._response_callbacks[block_id] = lambda v: self._on_start_session_reply(v)
        if value:
            await self._launch_session(value.strip())

    async def _launch_session(self, cwd: str):
        """Launch a new claude session in cwd via tmux, falling back to Terminal.app."""
        import shutil
        self._recently_launched_cwds.add(cwd)
        if shutil.which('tmux'):
            try:
                proc = await asyncio.create_subprocess_exec(
                    'tmux', 'new-window', '-P', '-c', cwd, 'claude',
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
                    print(f'[claudecode-controller] launched claude in tmux {tmux_target} at {cwd}', file=sys.stderr)
                    return
            except Exception as e:
                print(f'[claudecode-controller] tmux launch failed: {e}, falling back to Terminal.app', file=sys.stderr)
        # Terminal.app fallback
        safe_cwd = cwd.replace('\\', '\\\\').replace('"', '\\"')
        script = f'tell application "Terminal" to do script "cd \\"{safe_cwd}\\" && claude"'
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            print(f'[claudecode-controller] launched claude in Terminal.app at {cwd}', file=sys.stderr)
        except Exception as e:
            print(f'[claudecode-controller] Terminal.app launch failed: {e}', file=sys.stderr)
        asyncio.create_task(self._delayed_discovery())

    async def _delayed_discovery(self):
        """Re-run process discovery a few seconds after a launch to pick up new processes."""
        await asyncio.sleep(4)
        if not self._initialized:
            return
        await self._discover_active_processes()
        for session_id, info in list(self._sessions.items()):
            if not info.get('last_emitted'):
                asyncio.create_task(self._emit_session_block(session_id))

    def _tmux_prompt_block_id(self, tmux_target: str) -> str:
        safe = tmux_target.replace(':', '-').replace('.', '-')
        return f'claudecode-tmux-prompt-{safe}'

    @staticmethod
    def _parse_tmux_prompt(content: str):
        """Detect an interactive prompt in tmux pane output.
        Returns (body, options, reply_mode) or None if no prompt found.
        reply_mode is one of: 'numbered', 'yn', 'arrow'
        """
        import re
        lines = content.splitlines()

        # Format 1: Numbered menu (e.g. "1. Option") with a footer line
        option_re = re.compile(r'^\s*[>❯]?\s*(\d+)[.)]\s+(.+)$')
        footer_re = re.compile(r'press\s+enter|to\s+continue|to\s+confirm|esc\s+to', re.IGNORECASE)
        options_numbered = []
        body_lines = []
        found_options = False
        for line in lines:
            m = option_re.match(line)
            if m:
                found_options = True
                options_numbered.append(m.group(2).strip())
            elif not found_options:
                s = line.strip()
                if s and not re.match(r'^[$%#>]\s', s):
                    body_lines.append(s)
        has_footer = any(footer_re.search(l) for l in lines)
        if len(options_numbered) >= 2 and has_footer:
            body = ' '.join(body_lines[-2:]) if body_lines else 'Choose an option'
            return body, options_numbered, 'numbered'

        # Format 2: Arrow-key menu (lines prefixed with ❯ or >, no numbers)
        # e.g. "❯ Yes, proceed" / "  No, exit" or Claude Code trust prompt
        arrow_re = re.compile(r'^[❯>]\s+(.+)$')
        plain_re = re.compile(r'^\s{2,}(\S.+)$')
        arrow_options = []
        in_menu = False
        menu_body_lines = []
        for line in lines:
            ma = arrow_re.match(line.rstrip())
            if ma:
                in_menu = True
                arrow_options.append(ma.group(1).strip())
            elif in_menu:
                mp = plain_re.match(line.rstrip())
                if mp:
                    arrow_options.append(mp.group(1).strip())
                elif line.strip():
                    in_menu = False
            elif not in_menu and line.strip() and not re.match(r'^[$%#❯>]', line.strip()):
                menu_body_lines.append(line.strip())
        if len(arrow_options) >= 2:
            body = ' '.join(menu_body_lines[-2:]) if menu_body_lines else 'Choose an option'
            return body, arrow_options, 'arrow'

        # Format 3: y/n inline prompt
        yn_re = re.compile(r'(\(y[/\\]n\)|\[y[/\\]N\]|\[Y[/\\]n\])\s*[›>]?\s*$', re.IGNORECASE)
        for line in lines:
            m = yn_re.search(line)
            if m:
                body = line.strip()
                return body, ['Yes', 'No'], 'yn'

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

            parse_result = self._parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if parse_result:
                idle_streak = 0
                poll_interval = 1
                if content_hash != last_hash:
                    last_hash = content_hash
                    body, options, reply_mode = parse_result
                    captured = (tmux_target, options, block_id, reply_mode)
                    self._response_callbacks[block_id] = (
                        lambda v, c=captured: self._on_tmux_prompt_reply(c[0], c[1], v, c[2], c[3])
                    )
                    payload = {'title': body, 'body': '', 'options': options, 'urgency': 'warning'}
                    try:
                        await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
                        print(f'[claudecode-controller] tmux prompt surfaced for {tmux_target}', file=sys.stderr)
                    except Exception as e:
                        print(f'[claudecode-controller] tmux prompt emit failed: {e}', file=sys.stderr)
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

    async def _on_tmux_prompt_reply(self, tmux_target: str, options: list, value: str, block_id: str, reply_mode: str = 'numbered'):
        """Send the user's selection to the tmux pane."""
        try:
            if reply_mode == 'yn':
                key = 'y' if value == 'Yes' else 'n'
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, key, 'Enter',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
            elif reply_mode == 'arrow':
                try:
                    idx = options.index(value)
                except ValueError:
                    idx = 0
                for _ in range(idx):
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
            else:  # numbered
                try:
                    idx = options.index(value)
                except ValueError:
                    idx = 0
                for _ in range(idx):
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
                await asyncio.sleep(0.4)
                p = await asyncio.create_subprocess_exec(
                    'tmux', 'send-keys', '-t', tmux_target, 'Enter',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await p.communicate()
        except Exception as e:
            print(f'[claudecode-controller] tmux prompt reply failed: {e}', file=sys.stderr)
        self._response_callbacks.pop(block_id, None)
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    def _tty_prompt_block_id(self, session_id: str) -> str:
        digest = hashlib.sha256(f'tty-prompt-{session_id}'.encode()).hexdigest()[:8]
        return f'claudecode-tty-prompt-{digest}'

    async def _monitor_tty_session(self, session_id: str):
        """Poll a TTY session for interactive prompts (e.g. trust prompt) and surface them to iOS.

        When a numbered menu is detected, the options are embedded directly in the
        session's agent_session block (via pending_confirmation) rather than as a
        separate floating inbox item.  Replies come through the session's normal
        response callback and are routed to _on_tty_prompt_reply."""
        import hashlib as _hl
        last_hash = ''
        poll_interval = 1
        idle_streak = 0
        active_options: list = []

        # Give terminal-manager time to register the session before first poll
        await asyncio.sleep(2)

        while True:
            await asyncio.sleep(poll_interval)
            if session_id not in self._sessions:
                break

            try:
                result = await self._rpc('tools/call', {
                    'name': 'read_output',
                    'arguments': {'session_id': session_id, 'lines': 40},
                }, timeout=4.0)
                if not isinstance(result, dict):
                    idle_streak += 1
                    if idle_streak > 60:
                        break
                    continue
                lines = result.get('lines', [])
                content = '\n'.join(lines)
            except Exception:
                idle_streak += 1
                if idle_streak > 60:
                    break
                continue

            # Don't scan for TUI prompts while Claude is actively streaming a
            # response — markdown output (numbered lists, ❯ arrows) false-positives.
            if session_id in self._working_sessions:
                if last_hash:
                    # Clear any stale pending_confirmation from before work started.
                    last_hash = ''
                    active_options = []
                    session = self._sessions.get(session_id, {})
                    session.pop('pending_confirmation', None)
                    session_block_id = self._session_block_id(session_id)
                    self._response_callbacks[session_block_id] = (
                        lambda v, sid=session_id: self._on_session_reply(sid, v)
                    )
                    await self._emit_session_block(session_id)
                continue

            parsed = self._parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if parsed:
                idle_streak = 0
                poll_interval = 1
                if content_hash != last_hash:
                    last_hash = content_hash
                    body, options, _reply_mode = parsed
                    active_options = options
                    # Embed the confirmation in the session block so it appears
                    # inside the session card rather than floating above all sessions.
                    session = self._sessions.get(session_id, {})
                    session['pending_confirmation'] = {'title': body, 'options': options}
                    session_block_id = self._session_block_id(session_id)
                    # Emit first (emit registers the default callback), then override
                    await self._emit_session_block(session_id)
                    # Set override AFTER emit so _emit_session_block doesn't clobber it
                    self._response_callbacks[session_block_id] = (
                        lambda v, sid=session_id, opts=options:
                            self._on_tty_prompt_reply(sid, opts, v)
                    )
                    _log(f'[claudecode] TTY prompt surfaced for {session_id[:8]}')
            else:
                if last_hash:
                    last_hash = ''
                    active_options = []
                    session = self._sessions.get(session_id, {})
                    session.pop('pending_confirmation', None)
                    # Restore normal reply callback
                    session_block_id = self._session_block_id(session_id)
                    self._response_callbacks[session_block_id] = (
                        lambda v, sid=session_id: self._on_session_reply(sid, v)
                    )
                    await self._emit_session_block(session_id)
                idle_streak += 1
                if idle_streak > 60:
                    poll_interval = 5

        self._tty_monitors.pop(session_id, None)
        session = self._sessions.get(session_id, {})
        session.pop('pending_confirmation', None)

    async def _on_tty_prompt_reply(self, session_id: str, options: list, value: str):
        """Send the user's menu selection to the terminal via inject_tty (TIOCSTI).

        inject_tty sends Ctrl-U + text + Enter directly into the TTY input queue —
        no Accessibility permission required, no window focus needed."""
        try:
            idx = options.index(value)
        except ValueError:
            return
        # Build keystroke sequence: idx Down arrows (\x1b[B each), then Enter.
        # do script in Terminal.app appends the Enter automatically.
        down_seq = '\x1b[B' * idx
        try:
            await self._rpc('tools/call', {
                'name': 'inject_tty',
                'arguments': {'session_id': session_id, 'text': down_seq},
            }, timeout=5.0)
            _log(f'[claudecode] TTY prompt replied idx={idx} downs={idx} for {session_id[:8]}')
        except Exception as e:
            _log(f'[claudecode] TTY prompt reply failed: {e}')
        # Clear confirmation state and restore normal reply routing
        session = self._sessions.get(session_id, {})
        session.pop('pending_confirmation', None)
        session_block_id = self._session_block_id(session_id)
        self._response_callbacks[session_block_id] = (
            lambda v, sid=session_id: self._on_session_reply(sid, v)
        )

    @staticmethod
    def _project_label(cwd: str, session_id: str, tty: str = '') -> str:
        """Human-readable label: last 2 path parts + TTY (or short session ID fallback)."""
        if cwd:
            parts = cwd.rstrip('/').split('/')
            path_label = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
        else:
            path_label = 'Claude Code'
        identifier = tty if tty else (session_id if session_id.startswith('pid-') else session_id[:6])
        return f'{path_label} [{identifier}]'

    def _save_sessions(self):
        """Persist _sessions to disk so restarts can re-emit known sessions.
        PID-based sessions (pid-*) are transient process discoveries and are NOT persisted."""
        try:
            os.makedirs(os.path.dirname(SESSIONS_PATH), exist_ok=True)
            to_save = {sid: info for sid, info in self._sessions.items()
                       if not sid.startswith('pid-')}
            with open(SESSIONS_PATH, 'w') as f:
                json.dump(to_save, f)
        except Exception as e:
            print(f'[claudecode-controller] session save failed: {e}', file=sys.stderr)
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
                    if 'claude' in comm.lower() and tty != '??':
                        live.append({'pid': pid, 'tty': tty, 'comm': comm})
            except Exception:
                pass
            with open(STATUS_PATH, 'w') as f:
                json.dump({'sessions': sessions, 'live_processes': live, 'updated_at': time.time()}, f, indent=2)
        except Exception:
            pass

    def _load_sessions(self):
        """Load persisted sessions, discarding any older than SESSION_DISK_TTL.

        Uses a 24-hour cutoff (SESSION_DISK_TTL) instead of the 1-hour block TTL
        so that long-running sessions survive daemon restarts without disappearing.
        Dead sessions are evicted by _prune_dead_pid_sessions / _prune_dead_real_sessions.

        After loading, deduplicate by TTY: only one session per TTY is allowed.
        When multiple sessions share a TTY, the real (non-pid-*) session wins;
        if multiple real sessions share a TTY, the most-recently-seen wins."""
        try:
            with open(SESSIONS_PATH) as f:
                data = json.load(f)
            cutoff = time.time() - SESSION_DISK_TTL
            self._sessions = {
                sid: info for sid, info in data.items()
                if isinstance(info, dict) and info.get('last_seen', 0) >= cutoff
            }
            # Deduplicate: one session per TTY — prefer real over pid-*, newest over old.
            seen_ttys: dict[str, str] = {}  # normalized tty -> winning session_id
            for sid, info in sorted(self._sessions.items(),
                                    key=lambda x: (x[0].startswith('pid-'), -x[1].get('last_seen', 0))):
                tty = self._normalize_tty(info.get('tty', ''))
                if not tty:
                    continue
                if tty not in seen_ttys:
                    seen_ttys[tty] = sid
                else:
                    _log(f'[claudecode] load dedup: evicting {sid} — TTY {tty} already owned by {seen_ttys[tty][:8]}')
                    del self._sessions[sid]
            print(f'[claudecode-controller] restored {len(self._sessions)} session(s)', file=sys.stderr)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f'[claudecode-controller] session load failed: {e}', file=sys.stderr)

    async def _discover_active_processes(self):
        """Scan for running 'claude' processes via ps/lsof and register untracked ones."""
        if os.environ.get('ASK_SKIP_DISCOVERY'):
            return
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
                if 'claude' in comm.lower() and tty != '??':
                    candidates.append((int(pid_str), tty))
        except Exception as e:
            print(f'[claudecode-controller] _discover_active_processes ps failed: {e}', file=sys.stderr)
            return

        for pid, tty in candidates:
            synthetic_id = f'pid-{pid}'
            if synthetic_id in self._sessions:
                continue
            # Get CWD via lsof
            cwd = None
            try:
                lsof = await asyncio.create_subprocess_exec(
                    'lsof', '-p', str(pid), '-a', '-d', 'cwd', '-Fn',
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
                )
                out, _ = await lsof.communicate()
                for lline in out.decode().splitlines():
                    if lline.startswith('n'):
                        cwd = lline[1:]
                        break
            except Exception:
                pass
            if not cwd:
                continue
            # Skip if an existing session already owns this PID or TTY.
            # TTY check catches hook sessions (which don't store claude_pid) on the same terminal.
            norm_tty = self._normalize_tty(tty)
            if any(info.get('claude_pid') == pid or self._normalize_tty(info.get('tty', '')) == norm_tty
                   for info in self._sessions.values()):
                continue
            if self._register_session(synthetic_id, cwd, claude_pid=pid):
                self._sessions[synthetic_id]['tty'] = tty
                self._sessions[synthetic_id]['is_headless'] = self._detect_headless(tty)
                self._recently_launched_cwds.add(cwd)
                self._save_sessions()
                asyncio.create_task(self._tm_register(synthetic_id))
                if synthetic_id not in self._tty_monitors:
                    task = asyncio.create_task(self._monitor_tty_session(synthetic_id))
                    self._tty_monitors[synthetic_id] = task
                _log(f'[claudecode] discovered claude pid={pid} tty={tty} cwd={cwd}')

    @staticmethod
    def _is_pid_alive(pid: int) -> bool:
        """Return True if the process with this PID still exists."""
        try:
            os.kill(pid, 0)
            return True
        except (ProcessLookupError, ValueError):
            return False
        except PermissionError:
            return True  # process exists but we can't signal it

    @staticmethod
    def _pid_session_alive(session_id: str) -> bool:
        """Return True if the process behind a pid-{n} session still exists."""
        if not session_id.startswith('pid-'):
            return True
        try:
            pid = int(session_id[4:])
            return MCPClient._is_pid_alive(pid)
        except ValueError:
            return False

    def _prune_dead_pid_sessions(self):
        """Remove pid-* sessions whose process is no longer running."""
        dead = [sid for sid in list(self._sessions) if sid.startswith('pid-') and not self._pid_session_alive(sid)]
        for sid in dead:
            self._sessions.pop(sid, None)
            self._working_sessions.discard(sid)
            asyncio.create_task(self._tm_unregister(sid))
            print(f'[claudecode-controller] pruned dead pid session {sid}', file=sys.stderr)
        return dead

    async def _prune_dead_real_sessions(self):
        """Remove hook-registered sessions whose claude process has died.

        Two-pass approach:
        1. Always prune sessions whose stored claude_pid is no longer alive.
        2. If TM returns a non-empty session list, also prune any real session
           absent from TM (TM returning empty just means it restarted and lost
           state — we can't use that as a signal that all sessions are dead)."""
        dead = []

        # Pass 1: PID-based liveness — works even when TM has no state.
        for session_id, info in list(self._sessions.items()):
            if session_id.startswith('pid-'):
                continue
            claude_pid = info.get('claude_pid')
            if claude_pid and not self._is_pid_alive(claude_pid):
                self._sessions.pop(session_id, None)
                self._working_sessions.discard(session_id)
                dead.append(session_id)
                asyncio.create_task(self._tm_unregister(session_id))
                cwd = info.get('cwd', '')
                print(f'[claudecode-controller] pruned dead session {session_id[:8]} pid={claude_pid} ({cwd})', file=sys.stderr)

        # Pass 2: TM-based cross-check (only when TM has sessions to report).
        active = await self.list_terminal_sessions()
        if active:
            active_ids = {s.get('session_id') for s in active if s.get('session_id')}
            for session_id, info in list(self._sessions.items()):
                if session_id.startswith('pid-') or session_id in dead:
                    continue
                if session_id not in active_ids:
                    self._sessions.pop(session_id, None)
                    self._working_sessions.discard(session_id)
                    dead.append(session_id)
                    asyncio.create_task(self._tm_unregister(session_id))
                    cwd = info.get('cwd', '')
                    print(f'[claudecode-controller] pruned dead session {session_id[:8]} (not in TM, {cwd})', file=sys.stderr)

        if dead:
            self._save_sessions()
        return dead

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

    def _register_session(self, session_id: str, cwd: str, claude_pid: int = None):
        """Register a session if new; return True if it was new.

        claude_pid — the PID of the claude process that owns this session.
        When provided, it is used to verify liveness and evict stale sessions
        in the same CWD whose process is no longer running.
        """
        if session_id in self._sessions:
            # Already known — update pid if we now have a better one
            if claude_pid and not self._sessions[session_id].get('claude_pid'):
                self._sessions[session_id]['claude_pid'] = claude_pid
            return False
        project = self._project_label(cwd, session_id)
        entry = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
        if claude_pid:
            entry['claude_pid'] = claude_pid
        # If this session was launched via tmux, attach the window target for reply routing
        tmux_target = self._pending_tmux_targets.pop(cwd, None)
        if tmux_target:
            entry['tmux_target'] = tmux_target
        # When a hook-confirmed session registers, evict any sessions for the same CWD
        # whose process is no longer running (pid-* placeholders and stale real sessions).
        if not session_id.startswith('pid-'):
            for sid in list(self._sessions.keys()):
                old_info = self._sessions.get(sid, {})
                if old_info.get('cwd') != cwd:
                    continue
                # Determine if the old session's process is dead
                is_dead = False
                if sid.startswith('pid-'):
                    is_dead = not self._pid_session_alive(sid)
                else:
                    old_pid = old_info.get('claude_pid')
                    if old_pid is not None:
                        is_dead = not self._is_pid_alive(old_pid)
                    # No PID info — cannot confirm dead, leave it alone
                if is_dead:
                    # Migrate tmux_target so routing is preserved if we took over
                    if not entry.get('tmux_target') and old_info.get('tmux_target'):
                        entry['tmux_target'] = old_info['tmux_target']
                    self._sessions.pop(sid)
                    self._working_sessions.discard(sid)
                    self._recently_launched_cwds.discard(cwd)
                    asyncio.create_task(self.clear_block(self._session_block_id(sid)))
                    asyncio.create_task(self._tm_unregister(sid))
                    print(f'[claudecode-controller] evicted dead session {sid[:8]} ({cwd})', file=sys.stderr)
        self._sessions[session_id] = entry
        self._save_sessions()
        return True

    @staticmethod
    def _normalize_tty(tty: str) -> str:
        """Normalize TTY to short form (e.g. 's003') for consistent comparison.

        ps returns 's003'; Claude Code hooks return 'ttys003'; both must compare equal.
        Strips any /dev/ prefix, then strips the 'tty' prefix from ttys*/ttyp* forms."""
        if not tty:
            return tty
        if tty.startswith('/dev/'):
            tty = tty[5:]
        # 'ttys003' -> 's003', 'ttyp0' -> 'p0', etc.
        if tty.startswith('tty') and len(tty) > 3:
            tty = tty[3:]
        return tty

    @staticmethod
    def _detect_headless(tty: str) -> bool:
        """Return True if the given TTY belongs to a tmux pane with no attached clients.

        A 'headless' session means Claude is running inside tmux but no terminal
        window is actually open — the user would need to attach to see it."""
        if not tty:
            return False
        try:
            import subprocess
            # Check if this TTY belongs to any tmux pane
            r = subprocess.run(
                ['tmux', 'list-panes', '-a', '-F', '#{pane_tty} #{session_name}'],
                capture_output=True, text=True, timeout=2,
            )
            tty_dev = tty if tty.startswith('/dev/') else f'/dev/{tty}'
            for line in r.stdout.strip().splitlines():
                parts = line.split()
                if len(parts) == 2 and parts[0] == tty_dev:
                    session_name = parts[1]
                    # Check if the tmux session has any attached clients
                    lc = subprocess.run(
                        ['tmux', 'list-clients', '-t', session_name, '-F', '#{client_tty}'],
                        capture_output=True, text=True, timeout=2,
                    )
                    return not bool(lc.stdout.strip())
        except Exception:
            pass
        return False

    def _evict_sessions_for_tty(self, tty: str, keep_session_id: str):
        """Remove all sessions sharing a TTY except the one being registered.

        A TTY can only host one claude session at a time — any prior entry for
        the same TTY is stale and would create a duplicate card on iOS."""
        if not tty:
            return
        tty = self._normalize_tty(tty)
        for sid in list(self._sessions.keys()):
            if sid == keep_session_id:
                continue
            if self._normalize_tty(self._sessions[sid].get('tty', '')) == tty:
                _log(f'[claudecode] evicting {sid} — TTY {tty} superseded by {keep_session_id[:8]}')
                asyncio.create_task(self.clear_block(self._session_block_id(sid)))
                # Also clear any pending confirmation blocks linked to this session
                # so the ghost session card with orange badge disappears on iOS.
                for block_ids in list(self._tool_block_map.keys()):
                    if block_ids[0] == sid:
                        for bid in self._tool_block_map.pop(block_ids, []):
                            asyncio.create_task(self.clear_block(bid))
                del self._sessions[sid]
        self._save_sessions()

    def _handle_session_active(self, msg):
        """Called by PostToolUse — registers the session and emits an initial block."""
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '') or msg.get('tool_cwd', '')
        tty = self._normalize_tty(msg.get('tty') or '')
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd)
        if tty and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._sessions[session_id]['is_headless'] = self._detect_headless(tty)
            self._save_sessions()  # persist TTY immediately so it survives restarts
            asyncio.create_task(self._tm_register(session_id))
        # Evict any other session on this TTY — only one session per terminal.
        if tty:
            self._evict_sessions_for_tty(tty, session_id)
        # Start TTY prompt monitor if not already running
        if tty and session_id not in self._tty_monitors:
            task = asyncio.create_task(self._monitor_tty_session(session_id))
            self._tty_monitors[session_id] = task
        self._working_sessions.add(session_id)
        if is_new:
            asyncio.create_task(self._emit_session_block(session_id))

    def _handle_session_stop(self, msg):
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        if not session_id:
            return
        # Cancel any pane/TTY monitors for this session
        tmux_target = self._sessions.get(session_id, {}).get('tmux_target')
        if tmux_target:
            task = self._tmux_monitors.pop(tmux_target, None)
            if task:
                task.cancel()
        tty_task = self._tty_monitors.pop(session_id, None)
        if tty_task:
            tty_task.cancel()
        # Remove the session and clear its iOS block immediately.
        # Re-emitting with is_working=false left ghost sessions visible for up to
        # SESSION_TTL (1h), causing duplicates when a new session started in the same repo.
        info = self._sessions.pop(session_id, {})
        self._working_sessions.discard(session_id)
        self._current_tools.pop(session_id, None)
        self._tool_histories.pop(session_id, None)
        self._save_sessions()
        project = info.get('project') or (os.path.basename(cwd) if cwd else 'Claude Code')
        print(f'[claudecode-controller] session stopped: {session_id} ({project})', file=sys.stderr)
        asyncio.create_task(self._tm_unregister(session_id))
        asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
        asyncio.create_task(self.emit_block(str(uuid.uuid4()), 'session_event', {
            'event': 'stopped', 'project': project, 'cwd': cwd, 'ts': time.time()
        }, ttl=3600))

    async def _emit_session_block(self, session_id: str, last_message: str = '', touch_last_seen: bool = True):
        """Emit (or re-emit) the claude_session block for this session.

        touch_last_seen=False during startup re-emit so that sessions whose
        last hook activity predates SESSION_TTL are not artificially kept alive.

        last_message defaults to the stored value in self._sessions so that
        heartbeat re-emissions preserve the last response text."""
        # Fall back to stored last_message so heartbeats don't erase it
        if not last_message:
            last_message = self._sessions.get(session_id, {}).get('last_message', '')
        # pid-* sessions are background process discoveries — always surface them on iOS.
        # CWD deduplication in _discover_active_processes already prevents duplicates
        # when an Agent Session (hook-registered) tracks the same directory.
        if not self._initialized:
            print(f'[claudecode-controller] skipping session block — not yet initialized', file=sys.stderr)
            return
        session = self._sessions.get(session_id, {})
        if not session.get('tty') and not session.get('tmux_target'):
            # Can't route replies without a TTY or tmux target — don't surface this session on iOS
            asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
            return
        cwd = session.get('cwd', '')
        block_id = self._session_block_id(session_id)
        tty = session.get('tty', '')
        project = self._project_label(cwd, session_id, tty)
        payload: dict = {
            'session_id': session_id,
            'project': project,
            'cwd': cwd,
            'agent_name': 'Claude',
            'brand_color': '#D97757',
            'placeholder': 'Reply to Claude…',
        }
        if tty:
            payload['tty'] = tty
        if last_message:
            payload['last_message'] = last_message
        payload['is_working'] = session_id in self._working_sessions
        payload['is_headless'] = session.get('is_headless', False)
        if pc := session.get('pending_confirmation'):
            payload['pending_confirmation'] = pc
        activity = self._current_tools.get(session_id)
        if activity:
            payload['current_tool'] = activity['tool']
            payload['current_preview'] = activity['preview']
        history = self._tool_histories.get(session_id, [])
        if history:
            payload['tool_history'] = list(history[-10:])
        # Register reply callback (re-registered after each use in _on_session_reply)
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
            print(f'[claudecode-controller] agent_session emit failed: {e}', file=sys.stderr)

    async def _on_session_reply(self, session_id: str, value: str):
        """Called when the user sends a reply from iOS for a specific session."""
        block_id = self._session_block_id(session_id)
        # Re-register immediately so the user can reply again
        self._response_callbacks[block_id] = lambda v: self._on_session_reply(session_id, v)
        if value == '__close_session__':
            await self._close_session(session_id)
        elif value:
            await self._route_to_terminal(session_id, value)

    async def _close_session(self, session_id: str):
        """Stop the Claude Code process and remove the session."""
        session = self._sessions.get(session_id, {})
        tty_short = session.get('tty', '')
        tmux_target = session.get('tmux_target', '')
        _log(f'[claudecode] close_session {session_id} tty={tty_short!r}')

        # Priority 1: direct SIGINT to the claude process by PID.
        # Works regardless of terminal mode, no Accessibility needed.
        # Find PID from session, or look it up from the TTY.
        claude_pid = session.get('claude_pid')
        if not claude_pid and tty_short:
            try:
                import subprocess as _sp
                r = _sp.run(['ps', '-eo', 'pid,tty,comm'],
                            capture_output=True, text=True, timeout=2)
                full_tty = tty_short if not tty_short.startswith('ttys') else tty_short
                for line in r.stdout.splitlines()[1:]:
                    parts = line.split()
                    if len(parts) >= 3 and parts[1] == full_tty and 'claude' in parts[2].lower():
                        claude_pid = int(parts[0])
                        break
            except Exception:
                pass

        killed = False
        if claude_pid and self._is_pid_alive(claude_pid):
            try:
                import signal as _sig
                os.kill(claude_pid, _sig.SIGINT)
                _log(f'[claudecode] close_session SIGINT → pid {claude_pid}')
                await asyncio.sleep(0.8)
                if self._is_pid_alive(claude_pid):
                    os.kill(claude_pid, _sig.SIGTERM)
                    _log(f'[claudecode] close_session SIGTERM → pid {claude_pid}')
                killed = True
            except Exception as e:
                _log(f'[claudecode] close_session kill failed: {e}')

        # Priority 2: tmux send-keys C-c (for tmux sessions without a reachable PID)
        if not killed and tmux_target:
            try:
                for _ in range(2):
                    await self._rpc('tools/call', {
                        'name': 'send_key',
                        'arguments': {'session_id': session_id, 'key': 'ctrl_c'}
                    }, timeout=3.0)
                    await asyncio.sleep(0.3)
                _log(f'[claudecode] close_session ctrl_c via tmux send-keys')
            except Exception as e:
                _log(f'[claudecode] close_session tmux ctrl_c failed: {e}')

        # Remove from tracked sessions and clear the iOS block
        asyncio.create_task(self._tm_unregister(session_id))
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
    def _is_claude_idle(content: str) -> bool:
        """True when Claude Code is at its input prompt (> on last non-empty line)."""
        import re
        clean = MCPClient._strip_ansi(content)
        lines = [l for l in clean.splitlines() if l.strip()]
        if not lines:
            return False
        last = lines[-1]
        # Claude Code input prompt: line that is just "> " or "> <cursor>"
        return bool(re.match(r'^\s*>\s*$', last))

    @staticmethod
    def _extract_response(content: str) -> str:
        """Extract the most recent Claude Code response from pane content."""
        import re
        clean = MCPClient._strip_ansi(content)
        lines = clean.splitlines()
        # Bottom boundary: the trailing "> " prompt line(s)
        bottom_idx = len(lines)
        for i in range(len(lines) - 1, -1, -1):
            if re.match(r'^\s*>\s*$', lines[i]):
                bottom_idx = i
            else:
                break
        candidate = lines[:bottom_idx]
        # Remove trailing blank lines
        while candidate and not candidate[-1].strip():
            candidate.pop()
        # Strip decorative lines
        response_lines = [l for l in candidate if l.strip() and not re.match(r'^[-─━═╌╍\s]+$', l)]
        return '\n'.join(response_lines[-40:]).strip()[:4000]

    def _session_id_for_tmux(self, tmux_target: str) -> Optional[str]:
        """Find the session_id that owns this tmux_target."""
        for sid, info in self._sessions.items():
            if info.get('tmux_target') == tmux_target:
                return sid
        return None

    async def _capture_tmux_response(self, tmux_target: str, session_id: str):
        """After routing a message, poll until Claude Code is idle, then emit last_message."""
        # Wait for Claude Code to start processing
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

            if self._is_claude_idle(content):
                if content == prev_content:
                    stable_count += 1
                    if stable_count >= 2:
                        response = self._extract_response(content)
                        if response:
                            print(f'[claudecode-controller] captured response for {session_id} ({len(response)} chars)', file=sys.stderr)
                            asyncio.create_task(self._emit_session_block(session_id, last_message=response))
                        return
                else:
                    stable_count = 0
            else:
                stable_count = 0
            prev_content = content

    async def _capture_tty_response(self, session_id: str):
        """After routing a reply to a TTY session, wait for Claude to finish
        and emit the response as last_message — mirrors _capture_tmux_response
        for non-tmux sessions using terminal-manager's wait_for_idle tool."""
        await asyncio.sleep(2)   # give Claude a moment to start processing
        try:
            result = await self._rpc('tools/call', {
                'name': 'wait_for_idle',
                'arguments': {
                    'session_id': session_id,
                    'timeout': 1800,
                    'poll_interval': 2,
                    'stable_count': 2,
                    # Match Claude's idle '>' prompt OR the diff-viewer '>> accept edits'
                    # line — both mean Claude has finished streaming and is waiting for input.
                    'prompt_pattern': r'^\s*(>\s*$|>>\s)',
                }
            }, timeout=1820.0)
            if isinstance(result, dict) and result.get('idle') and result.get('output'):
                response = result['output']
                _log(f'[claudecode] TTY response captured for {session_id[:8]} ({len(response)} chars)')
                asyncio.create_task(self._emit_session_block(session_id, last_message=response))
        except Exception as e:
            _log(f'[claudecode] _capture_tty_response failed: {e}')

    async def _route_to_terminal(self, session_id: str, text: str):
        """Route text to the terminal running this session.

        Priority:
          1. terminal-manager send_text (handles both TTY and tmux uniformly)
          2. direct tmux send-keys fallback (for tmux sessions if terminal-manager fails)
          3. pbcopy + osascript fallback (for TTY sessions)

        For tmux sessions _capture_tmux_response is always scheduled so iOS
        receives Claude's reply regardless of which transport sent the text."""
        # Serialize per session — prevents clipboard race when two replies arrive quickly
        lock = self._route_locks.setdefault(session_id, asyncio.Lock())
        async with lock:
            await self._route_to_terminal_locked(session_id, text)

    async def _route_to_terminal_locked(self, session_id: str, text: str):
        """Inner routing logic, always called under the per-session lock.

        Transport priority:
          TTY sessions:  inject_tty (TIOCSTI, no focus/clipboard) →
                         send_text (osascript fallback) →
                         pbcopy+osascript (last resort)
          tmux sessions: send_text (terminal-manager) →
                         direct tmux send-keys fallback

        Response capture:
          tmux — _capture_tmux_response (polls capture-pane)
          TTY  — _capture_tty_response  (polls via wait_for_idle)
        """
        session = self._sessions.get(session_id, {})
        tmux_target = session.get('tmux_target')

        # ── TTY sessions ─────────────────────────────────────────────────────
        if not tmux_target:
            # Priority 1: inject_tty — TIOCSTI, no clipboard, no focus needed.
            # Retry once with re-registration: TM may have restarted and lost
            # its session registry, causing "Unknown session" → -32601.
            for attempt in range(2):
                try:
                    result = await self._rpc('tools/call', {
                        'name': 'inject_tty',
                        'arguments': {'session_id': session_id, 'text': text}
                    }, timeout=3.0)
                    if isinstance(result, dict) and result.get('ok'):
                        _log(f'[claudecode] routed via inject_tty: {session_id[:8]}')
                        asyncio.create_task(self._capture_tty_response(session_id))
                        return
                    break  # got a valid response (ok=False), no point retrying
                except Exception as e:
                    if attempt == 0:
                        _log(f'[claudecode] inject_tty failed, re-registering and retrying: {e}')
                        await self._tm_register(session_id)
                    else:
                        _log(f'[claudecode] inject_tty failed after re-register, falling back: {e}')

            # Priority 2: send_text via terminal-manager (osascript, focuses window).
            # Same retry-with-reregister pattern.
            for attempt in range(2):
                try:
                    result = await self._rpc('tools/call', {
                        'name': 'send_text',
                        'arguments': {'session_id': session_id, 'text': text}
                    }, timeout=3.0)
                    if isinstance(result, dict) and result.get('ok'):
                        _log(f'[claudecode] routed via send_text: {session_id[:8]}')
                        asyncio.create_task(self._capture_tty_response(session_id))
                        return
                    break
                except Exception as e:
                    if attempt == 0:
                        _log(f'[claudecode] send_text failed, re-registering and retrying: {e}')
                        await self._tm_register(session_id)
                    else:
                        _log(f'[claudecode] send_text failed after re-register, falling back to osascript: {e}')

            # Priority 3 handled below (pbcopy + osascript)

        # ── tmux sessions ─────────────────────────────────────────────────────
        else:
            # Primary: terminal-manager send_text.
            # Retry once with re-registration on error (TM may have restarted).
            for attempt in range(2):
                try:
                    result = await self._rpc('tools/call', {
                        'name': 'send_text',
                        'arguments': {'session_id': session_id, 'text': text}
                    }, timeout=3.0)
                    if isinstance(result, dict) and result.get('ok'):
                        _log(f'[claudecode] routed via terminal-manager send_text: {session_id[:8]}')
                        asyncio.create_task(self._capture_tmux_response(tmux_target, session_id))
                        return
                    break
                except Exception as e:
                    if attempt == 0:
                        _log(f'[claudecode] send_text failed, re-registering and retrying: {e}')
                        await self._tm_register(session_id)
                    else:
                        _log(f'[claudecode] send_text failed after re-register, falling back: {e}')

            # Fallback: direct tmux send-keys
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
                print(f'[claudecode-controller] tmux send-keys fallback failed: {e}', file=sys.stderr)
            asyncio.create_task(self._capture_tmux_response(tmux_target, session_id))
            return

        # ── TTY last-resort: pbcopy + osascript ──────────────────────────────

        try:
            pbcopy = await asyncio.create_subprocess_exec(
                'pbcopy',
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await pbcopy.communicate(input=text.encode('utf-8'))
        except Exception as e:
            print(f'[claudecode-controller] pbcopy failed: {e}', file=sys.stderr)
            return

        session = self._sessions.get(session_id, {})
        cwd = session.get('cwd', '')
        claude_pid = session.get('claude_pid')
        _log(f'[claudecode] route session={session_id} cwd={cwd!r} pid={claude_pid}')

        # Priority 1: PID-anchored TTY lookup — unambiguous even with multiple sessions.
        # If we have the claude PID, verify it's alive and get its current TTY directly.
        tty_short = None
        if claude_pid:
            if self._is_pid_alive(claude_pid):
                try:
                    import subprocess as _sp
                    r = _sp.run(['ps', '-p', str(claude_pid), '-o', 'tty='],
                                capture_output=True, text=True, timeout=2)
                    t = r.stdout.strip()
                    if t and t not in ('??', ''):
                        tty_short = t
                        _log(f'[claudecode] tty from pid {claude_pid}: {tty_short!r}')
                except Exception:
                    pass
            else:
                _log(f'[claudecode] claude_pid {claude_pid} is dead — will fall through')

        # Priority 2: stored TTY (set at session registration; may differ from live if
        # the process moved to a new window, but usually correct)
        if not tty_short:
            tty_short = session.get('tty')
            if tty_short:
                _log(f'[claudecode] using stored tty={tty_short!r}')

        # Priority 3: CWD-based fallbacks (ambiguous if multiple sessions share a CWD,
        # but better than nothing when PID and stored TTY are unavailable)
        if not tty_short:
            try:
                terminal_sessions = await self.list_terminal_sessions(filter='claude')
                for s in terminal_sessions:
                    if s.get('cwd') == cwd:
                        tty_short = s.get('tty')
                        _log(f'[claudecode] tty from list_terminal_sessions (cwd match): {tty_short!r}')
                        break
            except Exception:
                pass

        if not tty_short and cwd:
            tty_short = await self._find_tty_for_cwd(cwd, 'claude')
            _log(f'[claudecode] tty from ps+lsof (cwd match): {tty_short!r}')

        if not tty_short:
            # No TTY found — Claude is not running or terminal is closed.
            # Notify iOS so the user knows the message wasn't delivered.
            session = self._sessions.get(session_id, {})
            project = session.get('project', 'Claude Code')
            _log(f'[claudecode] no TTY found for {session_id[:8]} — notifying delivery failure')
            asyncio.create_task(self.emit_block(
                str(uuid.uuid4()), 'notification', {
                    'title': f'Message not delivered',
                    'body': f'{project} — Claude is not running or the terminal is closed.',
                    'icon': 'exclamationmark.bubble',
                }, ttl=300))
            return

        if tty_short:
            # Normalize TTY to full /dev/ path.
            # Hooks store "ttys009"; list_terminal_sessions stores "s009"; handle both.
            if tty_short.startswith('/dev/'):
                full_tty = tty_short
            elif tty_short.startswith('ttys') or tty_short.startswith('ttyp'):
                full_tty = f'/dev/{tty_short}'
            else:
                full_tty = f'/dev/tty{tty_short}'
            _log(f'[claudecode] routing via TTY: {full_tty}')
            safe_tty = full_tty.replace('\\', '\\\\').replace('"', '\\"')
            script = f'''
set targetTTY to "{safe_tty}"
set didFocus to false

if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in every window
            repeat with t in every tab of w
                try
                    if tty of t is targetTTY then
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

delay 0.4
tell application "System Events"
    keystroke "u" using control down
    keystroke "v" using command down
    delay 0.4
    keystroke return
end tell
'''
        else:
            # Fallback: match on window name (CWD path fragment).
            # Note: Terminal.app tabs don't have a reliable name property — use window name.
            parts = cwd.rstrip('/').split('/') if cwd else []
            path_fragment = '/'.join(parts[-2:]) if len(parts) >= 2 else (parts[-1] if parts else '')
            safe_path = path_fragment.replace('\\', '\\\\').replace('"', '\\"')
            script = f'''
set pathFragment to "{safe_path}"
set didFocus to false

if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in every window
            try
                if name of w contains pathFragment then
                    set index of w to 1
                    activate
                    set didFocus to true
                    exit repeat
                end if
            end try
        end repeat
        if not didFocus then activate
    end tell
    set didFocus to true
end if

delay 0.4
tell application "System Events"
    keystroke "u" using control down
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
            if err and err.strip():
                _log(f'[claudecode] osascript error: {err.decode().strip()}')
            else:
                _log(f'[claudecode] osascript succeeded (rc={proc.returncode})')
                asyncio.create_task(self._capture_tty_response(session_id))
        except Exception as e:
            _log(f'[claudecode] _route_to_terminal exception: {e}')

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
                    default='',   # empty = fall through to Claude Code's built-in prompt
                )
                if not writer.is_closing():
                    writer.write(json.dumps(response, ensure_ascii=False).encode())
                    await writer.drain()

            elif msg_type == 'question':
                response = await self._handle_blocking(
                    writer,
                    self._build_question_block(msg),
                    default='',
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

            elif msg_type == 'pre_tool_use':
                await self._handle_pre_tool_use(msg)

            elif msg_type == 'user_prompt':
                self._handle_user_prompt(msg)

            elif msg_type == 'session_start':
                self._handle_session_start_hook(msg)

            elif msg_type == 'pre_compact':
                await self._handle_pre_compact(msg)

            elif msg_type == 'post_compact':
                await self._handle_post_compact(msg)

        except Exception as e:
            print(f'[claudecode-controller] socket client error: {e}', file=sys.stderr)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _handle_blocking(self, writer, block_coro, default):
        """
        Emit a block, then race waiting for an iOS response against the hook
        process exiting (user answered in the terminal). When the hook process
        dies its socket fully closes — the writer transport transitions to
        closing, which we detect by polling. Clears the block in both cases.

        Note: we cannot use reader.read() for disconnect detection because
        hooks call socket.SHUT_WR after sending, leaving the reader at EOF
        before we even start waiting.
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

        response_task = asyncio.create_task(
            self.wait_for_block_response(block_id, timeout=300)
        )
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
            print(f'[claudecode-controller] hook exited — clearing block {block_id}', file=sys.stderr)
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
            print(f'[claudecode-controller] skipping permission block — not yet initialized', file=sys.stderr)
            return None, None
        block_id = str(uuid.uuid4())
        tool = msg.get('tool', 'Unknown')
        session_id = msg.get('session_id', '')
        preview = msg.get('preview', '')
        options = msg.get('options', ['Allow', 'Deny'])
        payload = {'title': f'Allow {tool}?', 'body': preview, 'options': options, 'urgency': 'urgent'}
        if session_id:
            payload['session_id'] = session_id
        # Capture TTY from the permission hook — ensures the session block is surfaced
        # even on the very first tool use before any PostToolUse has fired.
        tty = self._normalize_tty(msg.get('tty') or '')
        if tty and session_id and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._save_sessions()
            asyncio.create_task(self._tm_register(session_id))
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
            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
            # Track so PostToolUse can wake this block if the user accepts in terminal
            if session_id:
                key = (session_id, tool)
                self._tool_block_map.setdefault(key, []).append(block_id)
            self._active_confirmations += 1
            self._tile_body = f'Allow {tool}?\n{preview[:100]}' if preview else f'Allow {tool}?'
            asyncio.create_task(self._update_tile())
            return block_id, payload
        except Exception as e:
            print(f'[claudecode-controller] emit_block failed: {e}', file=sys.stderr)
            return None, None

    async def _handle_tool_executed(self, msg):
        """Called by PostToolUse hook — registers session and unblocks any pending permission block."""
        session_id = msg.get('session_id', '')
        tool_name = msg.get('tool_name', '')
        cwd = msg.get('cwd', '')
        tty = self._normalize_tty(msg.get('tty') or '')
        if not session_id or not tool_name:
            return
        # Register session if new; refresh the block TTL on every tool use.
        # Rate-limit to once per 5 min — TTL is 1 hour so frequent refreshes are unnecessary.
        is_new = self._register_session(session_id, cwd)
        if tty and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._save_sessions()  # persist TTY immediately so it survives restarts
            asyncio.create_task(self._tm_register(session_id))
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
                print(f'[claudecode-controller] tool {tool_name} ran — clearing block {block_id}', file=sys.stderr)
                await q.put('Allow')

    async def _build_question_block(self, msg):
        if not self._initialized:
            print(f'[claudecode-controller] skipping question block — not yet initialized', file=sys.stderr)
            return None, None
        block_id = str(uuid.uuid4())
        title = msg.get('title', 'Choose an option')
        body = msg.get('body', '')
        options = msg.get('options', [])
        payload = {'title': title, 'body': body, 'options': options, 'urgency': 'warning'}
        try:
            await self.emit_block(block_id, 'confirmation', payload, ttl=300, inbox=True)
            self._active_confirmations += 1
            self._tile_body = f'{title}\n{body[:100]}' if body else title
            asyncio.create_task(self._update_tile())
            return block_id, payload
        except Exception as e:
            print(f'[claudecode-controller] emit_block failed: {e}', file=sys.stderr)
            return None, None

    async def _handle_notification(self, msg):
        block_id = str(uuid.uuid4())
        payload = {
            'title': msg.get('title', 'Claude Code'),
            'body': msg.get('body', ''),
            'icon': msg.get('icon', 'bell.fill')
        }
        try:
            await self.emit_block(block_id, 'alert', payload, ttl=3600)
        except Exception as e:
            print(f'[claudecode-controller] notification emit failed: {e}', file=sys.stderr)

    async def _handle_pre_tool_use(self, msg):
        """PreToolUse hook — update live tool activity and debounce-emit the session block."""
        session_id = msg.get('session_id', '')
        tool = msg.get('tool', '')
        preview = msg.get('preview', '')
        cwd = msg.get('cwd', '')
        if not session_id or not tool:
            return
        self._register_session(session_id, cwd)
        self._working_sessions.add(session_id)
        entry = {"tool": tool, "preview": preview, "ts": time.time()}
        self._current_tools[session_id] = entry
        history = self._tool_histories.setdefault(session_id, [])
        history.append(entry)
        if len(history) > 20:
            del history[:-20]
        # Debounce: cancel any pending emit and schedule a new one
        existing = self._pending_activity_emits.get(session_id)
        if existing and not existing.done():
            existing.cancel()
        async def _emit():
            await asyncio.sleep(0.3)
            self._pending_activity_emits.pop(session_id, None)
            await self._emit_session_block(session_id)
            # Also update the activity_feed block with the latest tool history
            sess = self._sessions.get(session_id, {})
            project = sess.get('project', 'Claude Code')
            feed_entries = list(self._tool_histories.get(session_id, []))
            if feed_entries:
                feed_block_id = self._activity_feed_block_id(session_id)
                await self.emit_block(feed_block_id, 'activity_feed', {
                    'session_id': session_id,
                    'project': project,
                    'entries': feed_entries,
                }, ttl=3600)
        self._pending_activity_emits[session_id] = asyncio.create_task(_emit())

    def _handle_user_prompt(self, msg):
        """UserPromptSubmit hook — store the user message on the session."""
        session_id = msg.get('session_id', '')
        message = msg.get('message', '').strip()
        cwd = msg.get('cwd', '')
        if not session_id:
            return
        self._register_session(session_id, cwd)
        if session_id in self._sessions and message:
            self._sessions[session_id]['last_user_message'] = message

    def _handle_session_start_hook(self, msg):
        """SessionStart hook — register the session early before any tool fires.

        The hook now provides tty and claude_pid so routing can be anchored to
        the process immediately, without waiting for the first PostToolUse."""
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        tty = self._normalize_tty(msg.get('tty') or '')  # Captured by session_start.py from the process tree
        claude_pid = msg.get('claude_pid')  # PID of the claude process
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd, claude_pid=claude_pid)
        # Set TTY immediately if the hook provided it — no CWD-based search needed
        if tty and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._sessions[session_id]['is_headless'] = self._detect_headless(tty)
            self._save_sessions()
            print(f'[claudecode-controller] session_start tty={tty} pid={claude_pid} sid={session_id[:8]}', file=sys.stderr)
        # Evict any other session on this TTY — only one session per terminal.
        if tty:
            self._evict_sessions_for_tty(tty, session_id)
        # Hook-registered sessions have full hook coverage (PostToolUse, Stop, etc.)
        # so TTY polling is redundant and causes false-positive prompt detection
        # when Claude Code's own UI (e.g. "accept edits on (shift+tab to cycle)")
        # is misidentified as an interactive menu. TTY monitor is only useful for
        # pid-* sessions (discovered processes without hook control).
        if is_new:
            session = self._sessions.get(session_id, {})
            if session.get('tty') or session.get('tmux_target'):
                # Routing info available — register with terminal-manager and emit block
                asyncio.create_task(self._tm_register(session_id))
                asyncio.create_task(self._emit_session_block(session_id))
            else:
                # No TTY yet (e.g. launched without a terminal) — backfill as fallback
                asyncio.create_task(self._backfill_tty_and_emit(session_id, cwd))
        elif tty and session_id in self._sessions:
            # Existing session just got its TTY — update registration
            asyncio.create_task(self._tm_register(session_id))
        project = self._sessions.get(session_id, {}).get('project', 'Claude Code')
        asyncio.create_task(self.emit_block(str(uuid.uuid4()), 'session_event', {
            'event': 'started', 'project': project, 'cwd': cwd, 'ts': time.time()
        }, ttl=3600))

    async def _backfill_tty_and_emit(self, session_id: str, cwd: str):
        """Find the TTY for a freshly-started session and emit its block.

        Called on SessionStart so the session appears on iOS immediately —
        without waiting for the first PostToolUse to report the TTY.
        Retries a few times to give the process a moment to appear in ps."""
        for attempt in range(4):
            if session_id not in self._sessions:
                return
            if self._sessions[session_id].get('tty') or self._sessions[session_id].get('tmux_target'):
                break  # already have routing info (PostToolUse beat us here)
            tty = await self._find_tty_for_cwd(cwd, 'claude')
            if tty:
                self._sessions[session_id]['tty'] = tty
                self._save_sessions()
                print(f'[claudecode-controller] session_start TTY found: {session_id[:8]} -> {tty}', file=sys.stderr)
                asyncio.create_task(self._tm_register(session_id))
                break
            await asyncio.sleep(1)
        # Only emit if we found routing info. If we didn't, don't call _emit_session_block —
        # it would clear the block (no tty guard). PostToolUse will emit when it fires.
        session = self._sessions.get(session_id, {})
        if session.get('tty') or session.get('tmux_target'):
            await self._emit_session_block(session_id)

    async def _handle_pre_compact(self, msg):
        """PreCompact hook — surface compaction as live session activity."""
        session_id = msg.get('session_id', '')
        trigger = msg.get('trigger', 'auto')
        cwd = msg.get('cwd', '')
        if not session_id:
            return
        self._register_session(session_id, cwd)
        self._working_sessions.add(session_id)
        label = 'manual context' if trigger == 'manual' else 'conversation context'
        entry = {
            'tool': 'Compact',
            'preview': label,
            'ts': time.time(),
        }
        self._current_tools[session_id] = entry
        history = self._tool_histories.setdefault(session_id, [])
        history.append(entry)
        if len(history) > 20:
            del history[:-20]
        await self._emit_session_block(session_id)

    async def _handle_post_compact(self, msg):
        """PostCompact hook — finish live compaction state and persist summary."""
        session_id = msg.get('session_id', '')
        trigger = msg.get('trigger', 'auto')
        summary = msg.get('summary', '').strip()
        cwd = msg.get('cwd', '')
        if session_id:
            self._register_session(session_id, cwd)
            self._working_sessions.discard(session_id)
            self._current_tools.pop(session_id, None)
        project = self._sessions.get(session_id, {}).get('project', 'Claude Code')
        if not summary:
            if session_id:
                await self._emit_session_block(session_id)
            return
        if session_id and session_id in self._sessions:
            self._sessions[session_id]['last_message'] = 'Context summary ready'
            await self._emit_session_block(session_id, last_message='Context summary ready')
        block_id = f'claudecode-compact-{session_id[:16]}' if session_id else str(uuid.uuid4())
        await self.emit_block(block_id, 'compact_summary', {
            'session_id': session_id,
            'project': project,
            'trigger': trigger,
            'summary': summary[:1000],
            'ts': time.time(),
        }, ttl=86400)

    async def start_socket_server(self):
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        return await asyncio.start_unix_server(self.handle_socket_client, path=SOCKET_PATH)


# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

async def _tile_heartbeat(client):
    """Re-emit the tile every 5 minutes while the script runs.
    TTL=600 means the tile disappears within 10 minutes of the script stopping."""
    while True:
        await asyncio.sleep(300)
        await client._update_tile()


async def _session_heartbeat(client):
    """Re-emit all known session blocks every 5 minutes so idle sessions stay
    visible on iOS. TTL=3600 means a session block survives up to 1 hour of
    total inactivity (last heartbeat + TTL), so closing a terminal without
    a session_stop will clean up within ~65 minutes at worst.

    On each heartbeat, dead pid-* sessions are pruned and their blocks cleared."""
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
        # Deduplicate: one session per TTY — hook-registered (UUID) sessions beat
        # pid-discovered sessions; within the same type, newer (most-recently-seen) wins.
        seen_ttys: dict = {}
        for sid, info in sorted(client._sessions.items(),
                                key=lambda x: (x[0].startswith('pid-'), -x[1].get('last_seen', 0))):
            tty = client._normalize_tty(info.get('tty', ''))
            if not tty:
                continue
            if tty not in seen_ttys:
                seen_ttys[tty] = sid
            else:
                _log(f'[claudecode] heartbeat dedup: evicting {sid} — TTY {tty} owned by {seen_ttys[tty][:8]}')
                asyncio.create_task(client.clear_block(client._session_block_id(sid)))
                del client._sessions[sid]
        # Backfill TTY for sessions that don't have one yet
        backfilled = False
        for session_id, info in list(client._sessions.items()):
            if not info.get('tty') and info.get('cwd'):
                tty = await client._find_tty_for_cwd(info['cwd'], 'claude')
                if tty:
                    info['tty'] = tty
                    backfilled = True
        if backfilled:
            client._save_sessions()
        # Re-register all sessions with terminal-manager each cycle.
        # This recovers gracefully if terminal-manager restarted since the last heartbeat.
        for session_id, info in list(client._sessions.items()):
            if info.get('tty') or info.get('tmux_target'):
                asyncio.create_task(client._tm_register(session_id))
        client._write_status()
        for session_id in list(client._sessions.keys()):
            try:
                await client._emit_session_block(session_id)
            except Exception as e:
                print(f'[claudecode-controller] session heartbeat error for {session_id[:8]}: {e}', file=sys.stderr)
        try:
            await client._emit_start_session_block()
        except Exception as e:
            print(f'[claudecode-controller] start_session heartbeat error: {e}', file=sys.stderr)


async def run():
    client = MCPClient()
    server = await client.start_socket_server()

    # Start reading stdin BEFORE initialize() so the response can be received.
    stdin_task = asyncio.create_task(client.read_stdin())

    # Heartbeat runs unconditionally — sleeps 300s before first action so it
    # never races with initialization even if startup fails partway through.
    asyncio.create_task(_tile_heartbeat(client))
    asyncio.create_task(_session_heartbeat(client))

    try:
        await client.initialize()
        await client._update_tile()
    except Exception as e:
        print(f'[claudecode-controller] MCP initialize error: {e}', file=sys.stderr)

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
