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
import os
import time
import uuid
from typing import Optional

# Force UTF-8 on stdout so emoji pass through cleanly to the Mac daemon
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SOCKET_PATH    = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claudecode-controller.sock'))
BLOCK_TILE     = 'claudecode-controller-tile'
SESSIONS_PATH  = os.path.expanduser('~/.ask/claudecode_sessions.json')
SESSION_TTL    = 3600  # seconds — matches block TTL


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}      # rpc_id  -> asyncio.Future (tool call responses)
        self._pending_blocks = {}     # block_id -> asyncio.Queue (blocking waiters)
        self._response_callbacks = {} # block_id -> async callable(value)
        # session_id -> {'cwd': str, 'project': str}
        self._sessions: dict = {}
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
            'clientInfo': {'name': 'claudecode-controller', 'version': '1.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self._initialized = True
        print('[claudecode-controller] MCP initialized', file=sys.stderr)
        # Restore sessions from disk, then scan for live claude processes
        self._load_sessions()
        self._discover_active_processes()
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
        """Re-emit the tile block reflecting current state."""
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

        # Daemon notification — check for user_response
        method = msg.get('method', '')
        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
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
    # Per-session blocks — one claude_session block per active Claude session
    # ------------------------------------------------------------------

    def _session_block_id(self, session_id: str) -> str:
        return f'claudecode-session-{session_id[:8]}'

    @staticmethod
    def _project_label(cwd: str, session_id: str) -> str:
        """Human-readable label: last 2 path parts + short session ID."""
        if cwd:
            parts = cwd.rstrip('/').split('/')
            path_label = '/'.join(parts[-2:]) if len(parts) >= 2 else parts[-1]
        else:
            path_label = 'Claude Code'
        return f'{path_label} [{session_id[:6]}]'

    def _save_sessions(self):
        """Persist _sessions to disk so restarts can re-emit known sessions."""
        try:
            os.makedirs(os.path.dirname(SESSIONS_PATH), exist_ok=True)
            with open(SESSIONS_PATH, 'w') as f:
                json.dump(self._sessions, f)
        except Exception as e:
            print(f'[claudecode-controller] session save failed: {e}', file=sys.stderr)

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

    def _discover_active_processes(self):
        """Scan for running 'claude' processes and register their cwds as sessions.
        Uses lsof to find the working directory of each claude process."""
        import subprocess
        try:
            # Find PIDs of running claude CLI processes
            ps = subprocess.run(
                ['pgrep', '-f', r'node.*claude'],
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
                    # lsof -Fn output: lines starting with 'n' are the name (path)
                    cwd = next(
                        (line[1:] for line in lsof.stdout.splitlines() if line.startswith('n')),
                        ''
                    )
                    if cwd and cwd not in ('/', '/private'):
                        # Use pid as a stable-enough stand-in for session_id when unknown
                        synthetic_id = f'pid-{pid}'
                        if self._register_session(synthetic_id, cwd):
                            print(f'[claudecode-controller] discovered claude process pid={pid} cwd={cwd}', file=sys.stderr)
                except Exception:
                    pass
        except Exception as e:
            print(f'[claudecode-controller] process discovery failed: {e}', file=sys.stderr)

    def _register_session(self, session_id: str, cwd: str):
        """Register a session if new; return True if it was new."""
        if session_id in self._sessions:
            return False
        project = self._project_label(cwd, session_id)
        self._sessions[session_id] = {'cwd': cwd, 'project': project, 'last_seen': time.time()}
        self._save_sessions()
        return True

    def _handle_session_active(self, msg):
        """Called by PostToolUse — registers the session and emits an initial block."""
        session_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '') or msg.get('tool_cwd', '')
        if not session_id:
            return
        is_new = self._register_session(session_id, cwd)
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
        print(f'[claudecode-controller] session stopped: {session_id}', file=sys.stderr)
        asyncio.create_task(self._emit_session_block(session_id, last_message=last_message))

    async def _emit_session_block(self, session_id: str, last_message: str = ''):
        """Emit (or re-emit) the claude_session block for this session."""
        if not self._initialized:
            print(f'[claudecode-controller] skipping session block — not yet initialized', file=sys.stderr)
            return
        session = self._sessions.get(session_id, {})
        project = session.get('project', 'Claude Code')
        cwd = session.get('cwd', '')
        block_id = self._session_block_id(session_id)
        payload: dict = {
            'session_id': session_id,
            'project': project,
            'cwd': cwd,
            'placeholder': 'Reply to Claude…',
        }
        if last_message:
            payload['last_message'] = last_message
        # Register reply callback (re-registered after each use in _on_session_reply)
        self._response_callbacks[block_id] = lambda v: self._on_session_reply(session_id, v)
        try:
            if session_id in self._sessions:
                self._sessions[session_id]['last_seen'] = time.time()
                if last_message:
                    self._sessions[session_id]['last_message'] = last_message
            self._save_sessions()
            await self.emit_block(block_id, 'claude_session', payload)  # no TTL — lives until explicitly cleared
        except Exception as e:
            print(f'[claudecode-controller] claude_session emit failed: {e}', file=sys.stderr)

    async def _on_session_reply(self, session_id: str, value: str):
        """Called when the user sends a reply from iOS for a specific session."""
        block_id = self._session_block_id(session_id)
        # Re-register immediately so the user can reply again
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
            print(f'[claudecode-controller] pbcopy failed: {e}', file=sys.stderr)
            return

        session = self._sessions.get(session_id, {})
        project = session.get('project', '')
        safe_project = project.replace('\\', '\\\\').replace('"', '\\"')

        # Try to focus the Terminal/iTerm2 window whose title contains the project name,
        # then paste. Falls back to whatever window is frontmost.
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
                if name of current session of t contains projectName then
                    tell w to select t
                    activate
                    set didFocus to true
                    exit repeat
                end if
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
                print(f'[claudecode-controller] osascript: {err.decode().strip()}', file=sys.stderr)
        except Exception as e:
            print(f'[claudecode-controller] _route_to_terminal failed: {e}', file=sys.stderr)

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
            """Resolves when the hook's full socket connection closes."""
            transport = writer.transport
            while not transport.is_closing():
                await asyncio.sleep(0.3)

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
        payload = {'title': f'Allow {tool}?', 'body': preview, 'options': options}
        if session_id:
            payload['session_id'] = session_id
        try:
            await self.emit_block(block_id, 'confirmation', payload, ttl=300)
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
        if not session_id or not tool_name:
            return
        # Register session if new; refresh the block TTL on every tool use.
        # Rate-limit to once per 5 min — TTL is 1 hour so frequent refreshes are unnecessary.
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
            await self.emit_block(block_id, 'confirmation', payload, ttl=300)
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
    a session_stop will clean up within ~65 minutes at worst."""
    while True:
        await asyncio.sleep(300)
        if not client._initialized:
            continue
        for session_id in list(client._sessions.keys()):
            try:
                await client._emit_session_block(session_id)
            except Exception as e:
                print(f'[claudecode-controller] session heartbeat error for {session_id[:8]}: {e}', file=sys.stderr)


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
