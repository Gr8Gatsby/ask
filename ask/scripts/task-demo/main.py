#!/usr/bin/env python3
"""
task-demo — End-to-end demo of the A2A task protocol.

On startup, emits a confirmation block in the iOS app.
When the user taps "Run Demo", it:
  1. Opens a task via open_task
  2. Posts a user message and several agent messages via append_message
  3. Collects real system info and writes a report file
  4. Uploads the report via put_artifact
  5. Marks the task completed
"""

import sys
import json
import asyncio
import uuid
import os
import platform
import subprocess
import tempfile
from datetime import datetime

# Force UTF-8 stdout so emoji pass through cleanly
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

TRIGGER_BLOCK_ID = 'task-demo-trigger'
TILE_BLOCK_ID    = 'task-demo-tile'
STATUS_BLOCK_ID  = 'task-demo-status'


def _log(msg: str):
    print(f'[task-demo] {msg}', file=sys.stderr, flush=True)


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}
        self._response_callbacks = {}  # block_id -> callable(value)

    # ── MCP transport ─────────────────────────────────────────────────────────

    def _id(self):
        self._next_id += 1
        return self._next_id

    def _write(self, obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method, params=None, timeout: float = 15.0):
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

    async def call_tool(self, name: str, arguments: dict = None):
        return await self._rpc('tools/call', {'name': name, 'arguments': arguments or {}})

    # ── Block helpers ─────────────────────────────────────────────────────────

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        return await self.call_tool('emit_block', args)

    async def clear_block(self, block_id):
        return await self.call_tool('clear_block', {'blockId': block_id})

    # ── A2A helpers ───────────────────────────────────────────────────────────

    async def open_task(self, task_id: str, title: str, status: str = 'working'):
        return await self.call_tool('open_task', {
            'taskId': task_id,
            'title': title,
            'status': status,
        })

    async def append_message(self, task_id: str, role: str, text: str):
        # parts must be a native list (not a JSON string) — AskMac expects [[String: Any]]
        return await self.call_tool('append_message', {
            'taskId': task_id,
            'role': role,
            'parts': [{'type': 'text', 'text': text}],
        })

    async def put_artifact(self, task_id: str, artifact_id: str,
                           filename: str, mime_type: str,
                           description: str, file_path: str):
        return await self.call_tool('put_artifact', {
            'taskId': task_id,
            'artifactId': artifact_id,
            'filename': filename,
            'mimeType': mime_type,
            'description': description,
            'filePath': file_path,
        })

    # ── Tile helpers ──────────────────────────────────────────────────────────

    async def set_tile(self, label: str, detail: str = '', color: str = 'gray'):
        """Update the persistent home-screen tile."""
        await self.emit_block(TILE_BLOCK_ID, 'tile', {
            'label': label,
            'body': detail,
            'status_color': color,
            'action_required': False,
        })

    async def set_status(self, label: str, detail: str = '', color: str = 'blue'):
        """Show a status block in the script detail view."""
        await self.emit_block(STATUS_BLOCK_ID, 'status', {
            'label': label,
            'detail': detail,
            'color': color,
        })

    async def clear_status(self):
        await self.clear_block(STATUS_BLOCK_ID)

    # ── Demo logic ────────────────────────────────────────────────────────────

    async def run_demo(self):
        task_id = f"demo-{uuid.uuid4().hex[:8]}"
        now_str = datetime.now().strftime('%Y-%m-%d %H:%M')
        _log(f'Starting demo, task_id={task_id}')

        try:
            # 1. Open the task + update tile to show we're working
            await self.open_task(task_id, f"System Report — {now_str}")
            await self.set_tile('Running health check…', 'Collecting system info', 'blue')
            await self.set_status('Collecting system info', color='blue')
            _log('open_task done')

            # 2. Simulated user prompt
            await self.append_message(task_id, 'user',
                'Run a quick system health check and produce a report.')

            # 3. Agent: starting
            await self.append_message(task_id, 'assistant',
                'Starting system health check...')
            _log('initial messages posted')

            # 4. Collect real system data
            await self.set_status('Running system checks…', color='blue')
            hostname  = platform.node()
            os_info   = f"{platform.system()} {platform.release()} ({platform.machine()})"
            python_ver = platform.python_version()
            uptime_raw = _run('uptime') or 'unavailable'
            disk_raw   = _run('df -h /') or 'unavailable'
            mem_raw    = _run('vm_stat') or 'unavailable'

            # 5. Agent: findings as markdown
            findings = (
                f"**Host:** `{hostname}`\n"
                f"**OS:** {os_info}\n"
                f"**Python:** {python_ver}\n\n"
                f"**Uptime:**\n```\n{uptime_raw.strip()}\n```\n\n"
                f"**Disk (`/`):**\n```\n{disk_raw.strip()}\n```"
            )
            await self.append_message(task_id, 'assistant', findings)
            _log('findings message posted')

            # 6. Write full report to a temp file
            await self.set_status('Writing report…', color='blue')
            report_lines = [
                f"# System Report — {now_str}",
                f"",
                f"**Host:** {hostname}",
                f"**OS:** {os_info}",
                f"**Python:** {python_ver}",
                f"",
                f"## Uptime",
                f"```",
                uptime_raw.strip(),
                f"```",
                f"",
                f"## Disk Usage",
                f"```",
                disk_raw.strip(),
                f"```",
                f"",
                f"## VM Stats",
                f"```",
                mem_raw.strip(),
                f"```",
                f"",
                f"---",
                f"Generated by task-demo at {now_str}",
            ]
            report_text = '\n'.join(report_lines)

            tmp = tempfile.NamedTemporaryFile(
                mode='w', suffix='.md', delete=False, encoding='utf-8'
            )
            tmp.write(report_text)
            tmp.close()
            _log(f'report written to {tmp.name}')

            # 7. Upload artifact
            artifact_id = f"report-{uuid.uuid4().hex[:8]}"
            await self.put_artifact(
                task_id=task_id,
                artifact_id=artifact_id,
                filename=f"system-report-{datetime.now().strftime('%Y%m%d-%H%M')}.md",
                mime_type='text/plain',
                description='Full system health report',
                file_path=tmp.name,
            )
            os.unlink(tmp.name)
            _log('artifact uploaded')

            # 8. Agent: done
            await self.append_message(task_id, 'assistant',
                'Report complete. The full system health report is attached above.')

            # 9. Mark completed + update tile to idle state
            await self.call_tool('open_task', {
                'taskId': task_id,
                'title': f"System Report — {now_str}",
                'status': 'completed',
            })
            await self.clear_status()
            last_run = datetime.now().strftime('%H:%M')
            await self.set_tile('Ready', f'Last run: {last_run}', 'green')
            _log('task completed')

        except Exception as e:
            _log(f'ERROR in run_demo: {e}')
            import traceback
            traceback.print_exc(file=sys.stderr)

    # ── Startup ───────────────────────────────────────────────────────────────

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'task-demo', 'version': '1.1.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        _log('MCP initialized — emitting blocks')

        # Persistent tile — always visible on the home screen
        await self.set_tile('Ready', 'Tap Run Demo to start', 'gray')

        # Confirmation block in the inbox so the user can trigger the demo
        self._response_callbacks[TRIGGER_BLOCK_ID] = self._on_trigger
        await self.emit_block(TRIGGER_BLOCK_ID, 'confirmation', {
            'title': 'A2A Task Demo',
            'body': 'Tap Run Demo to exercise open_task, append_message, and put_artifact end-to-end.',
            'options': ['Run Demo'],
            'urgency': 'warning',
        }, ttl=3600, inbox=True)
        _log('blocks emitted')

    async def _on_trigger(self, value: str):
        _log(f'trigger tapped: {value!r}')
        await self.clear_block(TRIGGER_BLOCK_ID)
        await self.run_demo()
        # Re-emit trigger so it can be run again
        await asyncio.sleep(1)
        self._response_callbacks[TRIGGER_BLOCK_ID] = self._on_trigger
        await self.emit_block(TRIGGER_BLOCK_ID, 'confirmation', {
            'title': 'A2A Task Demo',
            'body': 'Demo complete! Tap Run Demo to run it again.',
            'options': ['Run Demo'],
            'urgency': 'warning',
        }, ttl=3600, inbox=True)

    # ── Main event loop ───────────────────────────────────────────────────────

    async def run(self):
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
        )

        asyncio.ensure_future(self.initialize())

        async for raw in reader:
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_id = msg.get('id')

            # Resolve pending RPC futures
            if msg_id and msg_id in self._pending_calls:
                fut = self._pending_calls.pop(msg_id)
                if not fut.done():
                    if 'error' in msg:
                        fut.set_exception(RuntimeError(str(msg['error'])))
                    else:
                        fut.set_result(msg.get('result'))
                continue

            # Block responses arrive as notifications/message with type=user_response
            method = msg.get('method', '')
            if method == 'notifications/message':
                data     = msg.get('params', {}).get('data', {})
                msg_type = data.get('type')
                if msg_type == 'user_response':
                    block_id = data.get('blockId', '')
                    value    = data.get('value', '')
                    _log(f'user_response block_id={block_id!r} value={value!r}')
                    cb = self._response_callbacks.pop(block_id, None)
                    if cb:
                        asyncio.ensure_future(cb(value))
                    else:
                        _log(f'no callback registered for block_id={block_id!r}')


def _run(cmd: str) -> str:
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=5
        )
        return result.stdout
    except Exception:
        return ''


def _install_parent_watchdog():
    """Exit if our parent (AskMac) goes away."""
    import threading, time
    def _watch():
        while True:
            time.sleep(5)
            if os.getppid() == 1:
                print('[task-demo] parent (AskMac) gone — exiting', file=sys.stderr, flush=True)
                os._exit(0)
    threading.Thread(target=_watch, daemon=True).start()


if __name__ == '__main__':
    _install_parent_watchdog()
    asyncio.run(MCPClient().run())
