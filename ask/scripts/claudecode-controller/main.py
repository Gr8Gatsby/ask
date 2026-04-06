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
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SOCKET_PATH    = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claudecode-controller.sock'))
BLOCK_TILE     = 'claudecode-controller-tile'
SESSIONS_PATH  = os.environ.get('ASK_SESSIONS_PATH', os.path.expanduser('~/.ask/claudecode_sessions.json'))
STATUS_PATH    = os.path.expanduser('~/.ask/status/claudecode-controller.json')
LOG_PATH       = os.path.expanduser('~/.ask/logs/claudecode-controller.log')
SESSION_TTL    = 3600  # seconds — block TTL and session load cutoff


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
            'clientInfo': {'name': 'claudecode-controller', 'version': '1.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self._initialized = True
        print('[claudecode-controller] MCP initialized', file=sys.stderr)
        # Restore sessions from disk (pid-* sessions are NOT persisted, so none load here),
        # then scan for live claude processes to register fresh pid-* entries.
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
                tty = await self._find_tty_for_cwd(info['cwd'], 'claude')
                if tty:
                    info['tty'] = tty
                    backfilled = True
                    print(f'[claudecode-controller] startup TTY backfill: {session_id} -> {tty}', file=sys.stderr)
        if backfilled:
            self._save_sessions()
        self._write_status()
        for session_id, info in list(self._sessions.items()):
            asyncio.create_task(
                self._emit_session_block(session_id, last_message=info.get('last_message', ''), touch_last_seen=False)
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
        """Detect a numbered interactive menu in tmux pane output.
        Returns (body, options) or None if no prompt found."""
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

    async def _on_tmux_prompt_reply(self, tmux_target: str, options: list, value: str, block_id: str):
        """Send the user's selection to the tmux pane."""
        try:
            idx = options.index(value)  # 0-based
        except ValueError:
            return
        try:
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

    @staticmethod
    def _project_label(cwd: str, session_id: str) -> str:
        """Human-readable label: last 2 path parts + short session ID.
        pid-* sessions show the full pid (e.g. pid-2605) to avoid ambiguity."""
        if cwd:
            parts = cwd.rstrip('/').split('/')
            path_label = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
        else:
            path_label = 'Claude Code'
        short = session_id if session_id.startswith('pid-') else session_id[:6]
        return f'{path_label} [{short}]'

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
        """Load persisted sessions, discarding any older than SESSION_TTL."""
        try:
            with open(SESSIONS_PATH) as f:
                data = json.load(f)
            cutoff = time.time() - SESSION_TTL
            self._sessions = {
                sid: info for sid, info in data.items()
                if isinstance(info, dict) and info.get('last_seen', 0) >= cutoff
            }
            print(f'[claudecode-controller] restored {len(self._sessions)} session(s)', file=sys.stderr)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f'[claudecode-controller] session load failed: {e}', file=sys.stderr)

    async def _discover_active_processes(self):
        """Scan for running 'claude' processes via the list_terminal_sessions MCP tool."""
        if os.environ.get('ASK_SKIP_DISCOVERY'):
            return
        sessions = await self.list_terminal_sessions(filter='claude')
        for s in sessions:
            pid = s.get('pid')
            cwd = s.get('cwd', '')
            if pid and cwd:
                synthetic_id = f'pid-{pid}'
                if self._register_session(synthetic_id, cwd):
                    print(f'[claudecode-controller] discovered claude process pid={pid} cwd={cwd}', file=sys.stderr)

    @staticmethod
    def _pid_session_alive(session_id: str) -> bool:
        """Return True if the process behind a pid-{n} session still exists."""
        if not session_id.startswith('pid-'):
            return True
        try:
            pid = int(session_id[4:])
            os.kill(pid, 0)  # signal 0 = existence check, no-op if alive
            return True
        except (ValueError, ProcessLookupError):
            return False
        except PermissionError:
            return True  # process exists but we can't signal it

    def _prune_dead_pid_sessions(self):
        """Remove pid-* sessions whose process is no longer running."""
        dead = [sid for sid in list(self._sessions) if sid.startswith('pid-') and not self._pid_session_alive(sid)]
        for sid in dead:
            self._sessions.pop(sid, None)
            self._working_sessions.discard(sid)
            print(f'[claudecode-controller] pruned dead pid session {sid}', file=sys.stderr)
        return dead

    async def _prune_dead_real_sessions(self):
        """Remove hook-registered sessions whose CWD no longer has an active claude process.
        Only prunes when list_terminal_sessions returns at least one result — if it returns
        empty we can't tell 'no processes' from 'tool unavailable', so we skip pruning."""
        active = await self.list_terminal_sessions(filter='claude')
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
                print(f'[claudecode-controller] pruned dead session {session_id[:8]} ({cwd})', file=sys.stderr)
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

    def _register_session(self, session_id: str, cwd: str):
        """Register a session if new; return True if it was new."""
        if session_id in self._sessions:
            return False
        project = self._project_label(cwd, session_id)
        entry = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
        # If this session was launched via tmux, attach the window target for reply routing
        tmux_target = self._pending_tmux_targets.pop(cwd, None)
        if tmux_target:
            entry['tmux_target'] = tmux_target
        # When a hook-confirmed session registers, clear any pid-* placeholder for the same cwd
        if not session_id.startswith('pid-'):
            for sid in list(self._sessions.keys()):
                if sid.startswith('pid-') and self._sessions[sid].get('cwd') == cwd:
                    # Migrate tmux_target from pid placeholder so reply routing is preserved
                    if not entry.get('tmux_target') and self._sessions[sid].get('tmux_target'):
                        entry['tmux_target'] = self._sessions[sid]['tmux_target']
                    self._sessions.pop(sid)
                    self._recently_launched_cwds.discard(cwd)
                    asyncio.create_task(self.clear_block(self._session_block_id(sid)))
        self._sessions[session_id] = entry
        self._save_sessions()
        return True

    def _handle_session_active(self, msg):
        """Called by PostToolUse — registers the session and emits an initial block."""
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
        print(f'[claudecode-controller] session stopped: {session_id}', file=sys.stderr)
        asyncio.create_task(self._emit_session_block(session_id, last_message=last_message))
        project = self._sessions.get(session_id, {}).get('project', 'Claude Code')
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
        # pid-* sessions are background process discoveries; only surface ones the
        # user explicitly launched via Start Session (cwd is in _recently_launched_cwds).
        if session_id.startswith('pid-'):
            cwd = self._sessions.get(session_id, {}).get('cwd', '')
            if cwd not in self._recently_launched_cwds:
                return
        if not self._initialized:
            print(f'[claudecode-controller] skipping session block — not yet initialized', file=sys.stderr)
            return
        session = self._sessions.get(session_id, {})
        if not session.get('tty') and not session.get('tmux_target'):
            # Can't route replies without a TTY or tmux target — don't surface this session on iOS
            asyncio.create_task(self.clear_block(self._session_block_id(session_id)))
            return
        project = session.get('project', 'Claude Code')
        cwd = session.get('cwd', '')
        block_id = self._session_block_id(session_id)
        payload: dict = {
            'session_id': session_id,
            'project': project,
            'cwd': cwd,
            'agent_name': 'Claude',
            'brand_color': '#D97757',
            'placeholder': 'Reply to Claude…',
        }
        if last_message:
            payload['last_message'] = last_message
        payload['is_working'] = session_id in self._working_sessions
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
        """Send Ctrl+C to the terminal running this session, then remove it."""
        session = self._sessions.get(session_id, {})
        tty_short = session.get('tty', '')
        _log(f'[claudecode] close_session {session_id} tty={tty_short!r}')

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
                    _log(f'[claudecode] close_session osascript error: {err.decode().strip()}')
            except Exception as e:
                _log(f'[claudecode] close_session failed: {e}')

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
                print(f'[claudecode-controller] tmux send-keys failed: {e}', file=sys.stderr)
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
            print(f'[claudecode-controller] pbcopy failed: {e}', file=sys.stderr)
            return

        session = self._sessions.get(session_id, {})
        cwd = session.get('cwd', '')
        _log(f'[claudecode] route session={session_id} cwd={cwd!r}')

        # Use the TTY captured at session registration time if available.
        tty_short = session.get('tty')
        _log(f'[claudecode] stored tty={tty_short!r}')

        # Fall back to list_terminal_sessions, then ps+lsof.
        if not tty_short:
            try:
                terminal_sessions = await self.list_terminal_sessions(filter='claude')
                for s in terminal_sessions:
                    if s.get('cwd') == cwd:
                        tty_short = s.get('tty')
                        _log(f'[claudecode] tty from list_terminal_sessions: {tty_short!r}')
                        break
            except Exception:
                pass

        if not tty_short and cwd:
            tty_short = await self._find_tty_for_cwd(cwd, 'claude')
            _log(f'[claudecode] tty from ps+lsof: {tty_short!r}')

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
                    default='Deny',
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
            self.wait_for_block_response(block_id, timeout=None)
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
        payload = {'title': f'Allow {tool}?', 'body': preview, 'options': options}
        if session_id:
            payload['session_id'] = session_id
        # Capture TTY from the permission hook — ensures the session block is surfaced
        # even on the very first tool use before any PostToolUse has fired.
        tty = msg.get('tty')
        if tty and session_id and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._save_sessions()
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
        tty = msg.get('tty')
        if not session_id or not tool_name:
            return
        # Register session if new; refresh the block TTL on every tool use.
        # Rate-limit to once per 5 min — TTL is 1 hour so frequent refreshes are unnecessary.
        is_new = self._register_session(session_id, cwd)
        if tty and session_id in self._sessions and not self._sessions[session_id].get('tty'):
            self._sessions[session_id]['tty'] = tty
            self._save_sessions()  # persist TTY immediately so it survives restarts
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
        payload = {'title': title, 'body': body, 'options': options}
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
        """SessionStart hook — register the session early before any tool fires."""
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd)
        if is_new:
            asyncio.create_task(self._emit_session_block(session_id))
        project = self._sessions.get(session_id, {}).get('project', 'Claude Code')
        asyncio.create_task(self.emit_block(str(uuid.uuid4()), 'session_event', {
            'event': 'started', 'project': project, 'cwd': cwd, 'ts': time.time()
        }, ttl=3600))

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
        # Backfill TTY for sessions that don't have one yet
        for session_id, info in list(client._sessions.items()):
            if not info.get('tty') and info.get('cwd'):
                tty = await client._find_tty_for_cwd(info['cwd'], 'claude')
                if tty:
                    info['tty'] = tty
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
