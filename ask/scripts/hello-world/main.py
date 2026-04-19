#!/usr/bin/env python3
"""
hello-world — Ask daemon script
A simple Hello World demo that greets the user and waits for acknowledgement.
Communicates with AskMac via JSON-RPC 2.0 over stdio.
"""
import sys
import json
import asyncio

# CRITICAL: unbuffered stdout so JSON-RPC messages reach the daemon immediately.
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

CHECK_INTERVAL  = 60 * 60   # re-greet after dismiss (1 hour)
RESET_DELAY     = 30        # seconds to show "Hello back at ya!" before resetting
TEST_INTERVAL   = 10

# ---------------------------------------------------------------------------
# MCPClient — JSON-RPC 2.0 over stdio
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._id      = 0
        self._pending = {}
        self._cbs     = {}

    def _send(self, obj: dict):
        sys.stdout.write(json.dumps(obj) + '\n')

    async def _rpc(self, method: str, params: dict = None, timeout: float = 30) -> dict:
        self._id += 1
        rid = self._id
        loop = asyncio.get_running_loop()
        fut  = loop.create_future()
        self._pending[rid] = fut
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params:
            msg['params'] = params
        self._send(msg)
        return await asyncio.wait_for(fut, timeout=timeout)

    async def initialize(self, client_name: str = 'script'):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': client_name, 'version': '1.0'}
        }, timeout=15)
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print(f'[{client_name}] MCP initialized', file=sys.stderr)

    async def emit_block(self, block_id: str, block_type: str, payload: dict, ttl: int = None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id: str):
        try:
            await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}}, timeout=10)
        except Exception:
            pass

    def set_callback(self, block_id: str, coro_fn):
        self._cbs[block_id] = coro_fn

    async def read_loop(self):
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
            self._dispatch(msg)
        print('[mcp] stdin closed', file=sys.stderr)

    def _dispatch(self, msg: dict):
        rid = msg.get('id')
        if rid is not None and 'result' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return
        if rid is not None and 'error' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return
        if msg.get('method') == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value    = data.get('value', '')
                cb = self._cbs.pop(block_id, None)
                if cb:
                    asyncio.create_task(cb(value))


# ---------------------------------------------------------------------------
# Script logic
# ---------------------------------------------------------------------------

BLOCK_STATUS  = 'hello-world-status'
BLOCK_CONFIRM = 'hello-world-confirm'


async def greet(mcp: MCPClient) -> bool:
    """Show the greeting and wait for user response.
    Returns True if user said it back (reset after short delay), False if dismissed."""
    print('[hello-world] greeting…', file=sys.stderr)
    responded = asyncio.Event()
    said_it_back = False

    async def on_response(value: str):
        nonlocal said_it_back
        await mcp.clear_block(BLOCK_CONFIRM)
        if value == 'Say it back':
            said_it_back = True
            await mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': 'Hello back at ya! 👋',
                'icon':  'heart.fill',
                'color': 'green',
            }, ttl=RESET_DELAY)
        else:
            await mcp.clear_block(BLOCK_STATUS)
        responded.set()

    mcp.set_callback(BLOCK_CONFIRM, on_response)
    await mcp.emit_block(BLOCK_CONFIRM, 'confirmation', {
        'title':   'Hello, World! 👋',
        'body':    'Greetings from your Ask script.\nWhat would you like to do?',
        'options': ['Say it back', 'Dismiss'],
    }, ttl=86400)

    await responded.wait()
    return said_it_back


async def run(mcp: MCPClient, test_mode: bool):
    interval = TEST_INTERVAL if test_mode else CHECK_INTERVAL
    runs = 0

    while True:
        try:
            said_it_back = await greet(mcp)
        except Exception as e:
            print(f'[hello-world] error: {e}', file=sys.stderr)
            await asyncio.sleep(interval)
            continue

        runs += 1
        if test_mode and runs >= 1:
            print('[hello-world] test mode complete', file=sys.stderr)
            await asyncio.sleep(60)
            return

        if said_it_back:
            # Let "Hello back at ya!" show briefly, then reset to the greeting
            await asyncio.sleep(RESET_DELAY)
            await mcp.clear_block(BLOCK_STATUS)
        else:
            await asyncio.sleep(interval)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[hello-world] running in test mode', file=sys.stderr)

    mcp = MCPClient()

    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='hello-world')
    await run(mcp, test_mode=test_mode)

if __name__ == '__main__':
    asyncio.run(main())
