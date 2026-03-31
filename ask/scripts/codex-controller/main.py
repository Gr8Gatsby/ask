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
                self._emit_session_block(session_id, last_message=info.get('last_message', ''))
            )

    async def emit_block(self, block_id, block_type, payload, ttl=None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        return await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id):
        return await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})

    async def _update_tile(self):
        if self._active_confirmations > 0:
            payload = {
                'label': 'Approval needed',
                'status_color': 'orange',
                'action_required': True,
            }
            if self._tile_body:
                payload['body'] = self._tile_body
        else:
            payload = {
                'label': 'Ready',
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
        return f'codex-session-{session_id[:8]}'

    @staticmethod
    def _project_label(cwd: str, session_id: str) -> str:
        if cwd:
            parts = cwd.rstrip('/').split('/')
            path_label = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
        else:
            path_label = 'Codex'
        return f'{path_label} [{session_id[:6]}]'

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
        self._sessions[session_id] = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
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
        print(f'[codex-controller] session stopped: {session_id}', file=sys.stderr)
        asyncio.create_task(self._emit_session_block(session_id, last_message=last_message))

    async def _emit_session_block(self, session_id: str, last_message: str = ''):
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

    async def _route_to_terminal(self, session_id: str, text: str):
        """Copy text to clipboard then paste into the terminal running this session."""
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
        repeat with w in every window
            repeat with t in every tab of w
                if title of t contains projectName then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    set didFocus to true
                    exit repeat
                end if
            end repeat
            if didFocus then exit repeat
        end repeat
    end tell
end if

if not didFocus and application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in every window
            repeat with t in every tab of w
                repeat with s in every session of t
                    if name of s contains projectName then
                        tell w to select t
                        activate
                        set didFocus to true
                        exit repeat
                    end if
                end repeat
                if didFocus then exit repeat
            end repeat
            if didFocus then exit repeat
        end repeat
    end tell
end if

delay 0.3
tell application "System Events"
    keystroke "v" using command down
    delay 0.1
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
