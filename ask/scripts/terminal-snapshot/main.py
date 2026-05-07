#!/usr/bin/env python3
"""
terminal-snapshot — capture any tmux pane from your iPhone.

On startup: lists all active tmux panes and shows a picker.
On selection: captures text + PNG screenshot and emits them as blocks.
Refreshes the pane list every 30 seconds.
"""
import asyncio
import datetime
import json
import os
import sys

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

LOG_PATH = os.path.expanduser('~/.ask/logs/terminal-snapshot.log')

TILE_ID    = 'terminal-snapshot-tile'
PICKER_ID  = 'terminal-snapshot-picker'
IMAGE_ID   = 'terminal-snapshot-image'
TEXT_ID    = 'terminal-snapshot-text'


def _log(msg: str, level: str = 'INFO'):
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [{level}] {msg}"
    print(line, file=sys.stderr, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


class TerminalSnapshot:
    def __init__(self):
        self._id_counter = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._panes: list[str] = []
        self._last_target: str = ''

    # ------------------------------------------------------------------
    # MCP transport
    # ------------------------------------------------------------------

    def _write(self, msg: dict):
        sys.stdout.write(json.dumps(msg) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method: str, params: dict, timeout: float = 10.0) -> dict:
        self._id_counter += 1
        rpc_id = self._id_counter
        fut = asyncio.get_running_loop().create_future()
        self._pending[rpc_id] = fut
        self._write({'jsonrpc': '2.0', 'id': rpc_id, 'method': method, 'params': params})
        try:
            return await asyncio.wait_for(asyncio.shield(fut), timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(rpc_id, None)
            raise

    async def _call_tool(self, name: str, args: dict, timeout: float = 30.0) -> dict:
        result = await self._rpc('tools/call', {'name': name, 'arguments': args}, timeout=timeout)
        if isinstance(result, dict) and 'error' in result:
            raise RuntimeError(result['error'])
        return result

    # ------------------------------------------------------------------
    # Block helpers
    # ------------------------------------------------------------------

    async def _put_block(self, block_id: str, block_type: str, payload: dict,
                         inbox: bool = False, ttl: int = None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        try:
            await self._call_tool('emit_block', args)
            _log(f'emit_block OK: {block_id} ({block_type})')
        except Exception as e:
            _log(f'emit_block FAILED: {block_id} ({block_type}): {e}', 'ERROR')

    async def _clear_block(self, block_id: str):
        try:
            await self._call_tool('clear_block', {'blockId': block_id}, timeout=5.0)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Pane list
    # ------------------------------------------------------------------

    async def _refresh_panes(self) -> list[str]:
        try:
            result = await self._call_tool('list_sessions', {}, timeout=10.0)
            sessions = result.get('sessions', [])
            panes = sorted({s['tmux_target'] for s in sessions if s.get('tmux_target')})
            self._panes = panes
            return panes
        except Exception as e:
            _log(f'list_sessions failed: {e}', 'WARN')
            return self._panes

    async def _emit_tile(self, panes: list[str]):
        n = len(panes)
        body = f'{n} active pane{"s" if n != 1 else ""}' if n else 'No active panes'
        await self._put_block(TILE_ID, 'tile', {'label': 'Terminal Snapshot', 'body': body})

    async def _emit_picker(self, panes: list[str]):
        if not panes:
            await self._put_block(PICKER_ID, 'status', {
                'label': 'No tmux panes found',
                'detail': 'Start a session to see panes here',
            })
            return
        await self._put_block(PICKER_ID, 'quick_reply', {
            'title': 'Select a pane to snapshot',
            'options': panes,
        })

    # ------------------------------------------------------------------
    # Snapshot
    # ------------------------------------------------------------------

    async def _do_snapshot(self, target: str):
        _log(f'snapshot target={target!r}')
        self._last_target = target

        await self._put_block(IMAGE_ID, 'status', {
            'label': f'Capturing {target}…',
            'color': 'blue',
        })

        try:
            result = await self._call_tool('screenshot', {
                'target': target,
                'format': 'auto',
            }, timeout=30.0)
        except Exception as e:
            _log(f'screenshot failed: {e}', 'WARN')
            await self._put_block(IMAGE_ID, 'status', {
                'label': 'Capture failed',
                'detail': str(e)[:200],
                'color': 'red',
            })
            return

        text  = result.get('text', '').strip()
        image = result.get('image')

        if image and image.get('data'):
            await self._put_block(IMAGE_ID, 'image', {
                'title': target,
                'data': image['data'],
                'format': image.get('format', 'png'),
                'encoding': image.get('encoding', 'base64'),
            }, ttl=600)
        else:
            await self._put_block(IMAGE_ID, 'status', {
                'label': f'{target} — text only',
                'detail': 'Screenshot unavailable (no tmux client attached)',
                'color': 'blue',
            })

        if text:
            lines = [l for l in text.splitlines() if l.strip()][-40:]
            await self._put_block(TEXT_ID, 'detail', {
                'title': f'{target} — terminal output',
                'body': '\n'.join(lines),
                'actions': ['Refresh'],
            }, ttl=600)

        # Re-show picker so user can capture another pane
        await self._emit_picker(self._panes)

    # ------------------------------------------------------------------
    # RPC dispatch
    # ------------------------------------------------------------------

    async def _handle_rpc_line(self, line: str):
        try:
            msg = json.loads(line)
        except Exception:
            return

        rpc_id = msg.get('id')

        # Response to a pending outgoing call
        if rpc_id is not None and rpc_id in self._pending:
            fut = self._pending.pop(rpc_id)
            if not fut.done():
                error = msg.get('error')
                if error:
                    fut.set_exception(RuntimeError(str(error)))
                else:
                    res = msg.get('result', {})
                    if isinstance(res, dict):
                        content = res.get('content', [])
                        if content and content[0].get('type') == 'text':
                            try:
                                fut.set_result(json.loads(content[0]['text']))
                                return
                            except Exception:
                                pass
                    fut.set_result(res)
            return

        method = msg.get('method', '')

        if method == 'tools/call':
            asyncio.create_task(self._dispatch_tool(rpc_id, msg.get('params', {})))
            return

        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            msg_type = data.get('type', '')
            if msg_type == 'user_response':
                asyncio.create_task(
                    self._handle_response(data.get('blockId', ''), data.get('value', ''))
                )

    async def _dispatch_tool(self, rpc_id, params: dict):
        name = params.get('name', '')
        args = params.get('arguments', {})
        try:
            if name == 'snapshot':
                target = args.get('target', '')
                if not target:
                    result = {'error': 'target is required'}
                else:
                    await self._do_snapshot(target)
                    result = {'ok': True, 'target': target}
            else:
                result = {'error': f'Unknown tool: {name}'}
        except Exception as e:
            result = {'error': str(e)}
        self._write({
            'jsonrpc': '2.0', 'id': rpc_id,
            'result': {'content': [{'type': 'text', 'text': json.dumps(result)}]},
        })

    async def _handle_response(self, block_id: str, value: str):
        if block_id == PICKER_ID and value in self._panes:
            await self._do_snapshot(value)
        elif block_id == TEXT_ID and value == 'Refresh' and self._last_target:
            await self._do_snapshot(self._last_target)

    # ------------------------------------------------------------------
    # Stdin loop + heartbeat
    # ------------------------------------------------------------------

    async def _read_stdin(self):
        loop = asyncio.get_running_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            asyncio.create_task(self._handle_rpc_line(line))

    async def _heartbeat(self):
        while True:
            await asyncio.sleep(30)
            old = set(self._panes)
            panes = await self._refresh_panes()
            if set(panes) != old:
                await self._emit_tile(panes)
                await self._emit_picker(panes)

    # ------------------------------------------------------------------
    # Entry point
    # ------------------------------------------------------------------

    async def run(self):
        _log('starting up')
        stdin_task = asyncio.create_task(self._read_stdin())

        _log('sending initialize')
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'clientInfo': {'name': 'terminal-snapshot', 'version': '1.0.0'},
            'capabilities': {},
        })
        _log('initialize OK')
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {}})

        panes = await self._refresh_panes()
        _log(f'panes: {panes}')
        await self._emit_tile(panes)
        _log('tile emitted')
        await self._emit_picker(panes)
        _log('picker emitted')

        asyncio.create_task(self._heartbeat())
        await stdin_task


def _install_parent_watchdog():
    """Exit if our parent (AskMac) goes away — see claude-3/main.py for context."""
    import threading, time
    def _watch():
        while True:
            time.sleep(5)
            if os.getppid() == 1:
                _log('parent (AskMac) gone — exiting', 'WARN')
                os._exit(0)
    threading.Thread(target=_watch, daemon=True).start()


if __name__ == '__main__':
    _install_parent_watchdog()
    asyncio.run(TerminalSnapshot().run())
