#!/usr/bin/env python3
"""
task-demo — End-to-end demo of the A2A task protocol.

When the 'run_demo' tool is called from the iOS app:
  1. Opens a task via open_task
  2. Posts a user message and several agent messages via append_message
  3. Collects real system info and writes a report file
  4. Uploads the report via put_artifact
  5. Marks the task completed

This script is purely a test harness — it has no dependencies beyond stdlib.
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


class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}

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

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'task-demo', 'version': '1.0.0'}
        })
        self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        # Run the demo immediately after handshake
        asyncio.ensure_future(self.run_demo())

    async def call_tool(self, name: str, arguments: dict = None):
        return await self._rpc('tools/call', {
            'name': name,
            'arguments': arguments or {}
        })

    # ── A2A helpers ──────────────────────────────────────────────────────────

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

    async def complete_task(self, task_id: str):
        return await self.call_tool('open_task', {
            'task_id': task_id,
            'title': '',        # title ignored on update
            'status': 'completed',
        })

    # ── Demo logic ────────────────────────────────────────────────────────────

    async def run_demo(self):
        task_id = f"demo-{uuid.uuid4().hex[:8]}"
        now_str = datetime.now().strftime('%Y-%m-%d %H:%M')

        # 1. Open the task
        await self.open_task(task_id, f"System Report — {now_str}")

        # 2. Simulated user prompt
        await self.append_message(task_id, 'user',
            'Run a quick system health check and produce a report.')

        # 3. Agent: starting
        await self.append_message(task_id, 'agent',
            'Starting system health check...')

        # 4. Collect real system data
        hostname = platform.node()
        os_info = f"{platform.system()} {platform.release()} ({platform.machine()})"
        python_ver = platform.python_version()
        uptime_raw = _run('uptime') or 'unavailable'
        disk_raw   = _run('df -h /') or 'unavailable'
        mem_raw    = _run('vm_stat') or 'unavailable'

        # 5. Agent: findings as markdown
        findings = f"""\
**Host:** `{hostname}`
**OS:** {os_info}
**Python:** {python_ver}

**Uptime:**
```
{uptime_raw.strip()}
```

**Disk (`/`):**
```
{disk_raw.strip()}
```"""
        await self.append_message(task_id, 'agent', findings)

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
            f"Generated by task-demo script at {now_str}",
        ]
        report_text = '\n'.join(report_lines)

        tmp = tempfile.NamedTemporaryFile(
            mode='w', suffix='.md', delete=False, encoding='utf-8'
        )
        tmp.write(report_text)
        tmp.close()

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

        # 8. Agent: done
        await self.append_message(task_id, 'agent',
            'Report complete. The full system health report is attached above.')

        # 9. Mark completed
        await self.complete_task(task_id)

    # ── Main event loop ───────────────────────────────────────────────────────

    async def run(self):
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
        )

        # Initialize concurrently with the reader so responses can be processed
        asyncio.ensure_future(self.initialize())

        async for line in reader:
            line = line.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Resolve pending RPC calls
            msg_id = msg.get('id')
            if msg_id and msg_id in self._pending_calls:
                fut = self._pending_calls.pop(msg_id)
                if not fut.done():
                    if 'error' in msg:
                        fut.set_exception(RuntimeError(str(msg['error'])))
                    else:
                        fut.set_result(msg.get('result'))
                continue

            # Incoming tool call from AskMac
            if msg.get('method') == 'tools/call':
                tool_name = msg.get('params', {}).get('name')
                rpc_id    = msg.get('id')
                if tool_name == 'run_demo':
                    # Acknowledge immediately, run demo in background
                    self._write({
                        'jsonrpc': '2.0', 'id': rpc_id,
                        'result': {'content': [{'type': 'text', 'text': 'Demo started.'}]}
                    })
                    asyncio.ensure_future(self.run_demo())
                else:
                    self._write({
                        'jsonrpc': '2.0', 'id': rpc_id,
                        'error': {'code': -32601, 'message': f'Unknown tool: {tool_name}'}
                    })


def _run(cmd: str) -> str:
    """Run a shell command and return stdout, or empty string on error."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=5
        )
        return result.stdout
    except Exception:
        return ''


if __name__ == '__main__':
    asyncio.run(MCPClient().run())
