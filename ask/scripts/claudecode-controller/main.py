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
import uuid
from typing import Optional

# Force UTF-8 on stdout so emoji pass through cleanly to the Mac daemon
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')
BLOCK_TILE  = 'claudecode-controller-tile'


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}      # rpc_id  -> asyncio.Future (tool call responses)
        self._pending_blocks = {}     # block_id -> asyncio.Queue (blocking waiters)
        self._response_callbacks = {} # block_id -> async callable(value)
        self._active_chat_block_id = None
        self._chat_title: str = 'Send to Claude'
        self._chat_context: str = ''
        # (session_id, tool_name) -> [block_id, ...] — cleared when the tool runs
        self._tool_block_map = {}
        # Tile state
        self._active_confirmations = 0
        self._tile_body: Optional[str] = None

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
        print('[claudecode-controller] MCP initialized', file=sys.stderr)

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
    # Persistent chat block — lets the user send text to Claude at any time
    # ------------------------------------------------------------------

    async def start_chat_block(self, context='', title='Send to Claude'):
        """Emit a chat_prompt block. When the user replies, type it into Terminal and re-emit."""
        # Remove the callback for any previous chat block.
        if self._active_chat_block_id:
            self._response_callbacks.pop(self._active_chat_block_id, None)

        # Use a deterministic ID so re-emitting replaces the existing block in CloudKit
        # rather than creating a duplicate. The daemon's savePolicy:.allKeys handles the upsert.
        block_id = 'claudecode-chat'
        self._active_chat_block_id = block_id
        self._chat_title = title
        self._chat_context = context
        payload = {
            'title': title,
            'context': context,
            'placeholder': 'Type your message to Claude…',
        }
        try:
            await self.emit_block(block_id, 'chat_prompt', payload, ttl=600)
            self._response_callbacks[block_id] = self._on_chat_reply
        except Exception as e:
            print(f'[claudecode-controller] chat block emit failed: {e}', file=sys.stderr)

    async def _on_chat_reply(self, value):
        """Called when the user submits a reply from iOS."""
        self._active_chat_block_id = None
        if value:
            await self._type_in_terminal(value)
        # Re-emit so the input is always available
        await asyncio.sleep(0.5)
        await self.start_chat_block()

    async def _type_in_terminal(self, text):
        """Copy text to clipboard then paste into the frontmost Terminal window."""
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

        script = (
            'tell application "Terminal" to activate\n'
            'delay 0.3\n'
            'tell application "System Events"\n'
            '    keystroke "v" using command down\n'
            '    delay 0.1\n'
            '    keystroke return\n'
            'end tell'
        )
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, err = await asyncio.wait_for(proc.communicate(), timeout=5.0)
            if err:
                print(f'[claudecode-controller] osascript: {err.decode().strip()}', file=sys.stderr)
        except Exception as e:
            print(f'[claudecode-controller] _type_in_terminal failed: {e}', file=sys.stderr)

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

            elif msg_type == 'chat_prompt':
                context = msg.get('context', '')
                title = msg.get('title', 'Send to Claude')
                asyncio.create_task(self.start_chat_block(context=context, title=title))
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
        block_id = str(uuid.uuid4())
        tool = msg.get('tool', 'Unknown')
        session_id = msg.get('session_id', '')
        preview = msg.get('preview', '')
        options = msg.get('options', ['Allow', 'Deny'])
        payload = {'title': f'Allow {tool}?', 'body': preview, 'options': options}
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
        """Called by PostToolUse hook — unblocks any permission block waiting for this tool."""
        session_id = msg.get('session_id', '')
        tool_name = msg.get('tool_name', '')
        if not session_id or not tool_name:
            return
        key = (session_id, tool_name)
        block_ids = self._tool_block_map.pop(key, [])
        for block_id in block_ids:
            q = self._pending_blocks.get(block_id)
            if q:
                print(f'[claudecode-controller] tool {tool_name} ran — clearing block {block_id}', file=sys.stderr)
                await q.put('Allow')

    async def _build_question_block(self, msg):
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

    def _handle_session_stop(self, msg):
        session_id = msg.get('session_id', '')
        last_message = msg.get('last_message', '')
        print(f'[claudecode-controller] session stopped: {session_id}', file=sys.stderr)
        if last_message:
            asyncio.create_task(self._emit_claude_message(session_id, last_message))

    async def _emit_claude_message(self, session_id, text):
        """Emit the last Claude response as a claude_message block. Uses a deterministic
        ID so re-emitting on successive stops replaces the previous message in CloudKit."""
        block_id = 'claudecode-last-message'
        payload = {'text': text, 'session_id': session_id}
        try:
            await self.emit_block(block_id, 'claude_message', payload, ttl=1800)
        except Exception as e:
            print(f'[claudecode-controller] claude_message emit failed: {e}', file=sys.stderr)

    async def start_socket_server(self):
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        return await asyncio.start_unix_server(self.handle_socket_client, path=SOCKET_PATH)


# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

async def _tile_heartbeat(client):
    """Re-emit the tile and chat block every 5 minutes while the script runs.
    TTL=600 means both blocks disappear within 10 minutes of the script stopping."""
    while True:
        await asyncio.sleep(300)
        await client._update_tile()
        if client._active_chat_block_id:
            await client.start_chat_block(
                context=client._chat_context,
                title=client._chat_title,
            )


async def run():
    client = MCPClient()
    server = await client.start_socket_server()

    # Start reading stdin BEFORE initialize() so the response can be received.
    stdin_task = asyncio.create_task(client.read_stdin())

    # Heartbeat runs unconditionally — sleeps 300s before first action so it
    # never races with initialization even if startup fails partway through.
    asyncio.create_task(_tile_heartbeat(client))

    try:
        await client.initialize()
        await client._update_tile()
        # Always-available input block for sending messages to Claude
        await client.start_chat_block()
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
