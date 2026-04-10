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

BLOCK_ID = 'task-demo-trigger'


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
            'task_id': task_id,
            'title': title,
            'status': status,
        })

    async def append_message(self, task_id: str, role: str, text: str):
        parts = json.dumps([{'type': 'text', 'text': text}])
        return await self.call_tool('append_message', {
            'task_id': task_id,
            'role': role,
            'parts': parts,
        })

    async def put_artifact(self, task_id: str, artifact_id: str,
                           filename: str, mime_type: str,
                           description: str, file_path: str):
        return await self.call_tool('put_artifact', {
            'task_id': task_id,
            'artifact_id': artifact_id,
            'filename': filename,
            'mime_type': mime_type,
            'description': description,
            'file_path': file_path,
        })

    # ── Demo logic ────────────────────────────────────────────────────────────

    async def run_demo(self):
        task_id = f"demo-{uuid.uuid4().hex[:8]}"
        now_str = datetime.now().strftime('%Y-%m-%d %H:%M')
        _log(f'Starting demo, task_id={task_id}')

        try:
            # 1. Open the task
            await self.open_task(task_id, f"System Report — {now_str}")
            _log('open_task done')

            # 2. Simulated user prompt
            await self.append_message(task_id, 'user',
                'Run a quick system health check and produce a report.')

            # 3. Agent: starting
            await self.append_message(task_id, 'agent',
                'Starting system health check...')
            _log('initial messages posted')

            # 4. Collect real system data
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
            await self.append_message(task_id, 'agent', findings)
            _log('findings message posted')

            # 6. Write full report to a temp file
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
            await self.append_message(task_id, 'agent',
                'Report complete. The full system health report is attached above.')

            # 9. Mark completed
            await self.open_task(task_id, f"System Report — {now_str}", status='completed')
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
        _log('MCP initialized — emitting trigger block')

        # Emit a confirmation block so the user can tap "Run Demo" from iOS
        self._response_callbacks[BLOCK_ID] = self._on_trigger
        await self.emit_block(BLOCK_ID, 'confirmation', {
            'title': 'A2A Task Demo',
            'body': 'Tap Run Demo to exercise open_task, append_message, and put_artifact end-to-end.',
            'options': ['Run Demo'],
            'urgency': 'info',
        }, ttl=3600, inbox=True)
        _log('trigger block emitted')

    async def _on_trigger(self, value: str):
        _log(f'trigger tapped: {value!r}')
        await self.clear_block(BLOCK_ID)
        await self.run_demo()
        # Re-emit so it can be run again
        self._response_callbacks[BLOCK_ID] = self._on_trigger
        await self.emit_block(BLOCK_ID, 'confirmation', {
            'title': 'A2A Task Demo',
            'body': 'Demo complete! Tap Run Demo to run it again.',
            'options': ['Run Demo'],
            'urgency': 'info',
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

            # Incoming tool call from AskMac (block response)
            method = msg.get('method', '')
            if method == 'tools/call':
                params    = msg.get('params', {})
                tool_name = params.get('name')
                args      = params.get('arguments', {})

                if tool_name == 'respond_to_block':
                    block_id = args.get('blockId') or args.get('block_id')
                    value    = args.get('value', '')
                    cb = self._response_callbacks.get(block_id)
                    if cb:
                        self._write({
                            'jsonrpc': '2.0', 'id': msg_id,
                            'result': {'content': [{'type': 'text', 'text': 'ok'}]}
                        })
                        asyncio.ensure_future(cb(value))
                    else:
                        self._write({
                            'jsonrpc': '2.0', 'id': msg_id,
                            'result': {'content': [{'type': 'text', 'text': 'unknown block'}]}
                        })
                else:
                    self._write({
                        'jsonrpc': '2.0', 'id': msg_id,
                        'error': {'code': -32601, 'message': f'Unknown tool: {tool_name}'}
                    })


def _run(cmd: str) -> str:
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=5
        )
        return result.stdout
    except Exception:
        return ''


if __name__ == '__main__':
    asyncio.run(MCPClient().run())
