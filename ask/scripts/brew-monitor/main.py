#!/usr/bin/env python3
"""
brew-monitor — surfaces outdated Homebrew packages on iPhone.

Checks every CHECK_INTERVAL seconds. When packages are outdated, emits a
confirmation block. If the user taps "Upgrade All", runs `brew upgrade`,
streams progress via A2A messages, and attaches a markdown report artifact.
"""
import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)


def find_brew() -> Optional[str]:
    """Return the full path to the brew executable, or None if not found."""
    candidates = [
        '/opt/homebrew/bin/brew',   # Apple Silicon
        '/usr/local/bin/brew',      # Intel
        '/home/linuxbrew/.linuxbrew/bin/brew',  # Linux
    ]
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return shutil.which('brew')


CHECK_INTERVAL = 4 * 60 * 60   # seconds between checks

BLOCK_TILE     = 'brew-monitor-tile'
BLOCK_UPDATES  = 'brew-monitor-updates'
BLOCK_STATUS   = 'brew-monitor-status'
BLOCK_NEXT_SYNC = 'brew-monitor-next-sync'
BLOCK_SYNC_NOW  = 'brew-monitor-sync-now'


# ---------------------------------------------------------------------------
# Minimal MCP client
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_rpc = {}       # rpc_id  -> Future
        self._response_cbs = {}      # block_id -> async callable(value)
        self._pipe_broken  = False

    # --- outbound ---

    def _next(self):
        self._next_id += 1
        return self._next_id

    def _send(self, obj):
        if self._pipe_broken:
            return
        try:
            sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
            sys.stdout.flush()
        except BrokenPipeError:
            print('[brew-monitor] stdout pipe broken — stopping writes', file=sys.stderr)
            self._pipe_broken = True
        except Exception as e:
            print(f'[brew-monitor] _send error: {e}', file=sys.stderr)

    async def _rpc(self, method, params=None, timeout=60.0):
        rpc_id = self._next()
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self._pending_rpc[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._send(msg)
        return await asyncio.wait_for(fut, timeout=timeout)

    async def call_tool(self, name: str, arguments: dict):
        return await self._rpc('tools/call', {'name': name, 'arguments': arguments})

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'brew-monitor', 'version': '2.5'},
        })
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print('[brew-monitor] MCP initialized', file=sys.stderr)

    # --- blocks ---

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self.call_tool('emit_block', args)

    async def clear_block(self, block_id):
        try:
            await self.call_tool('clear_block', {'blockId': block_id})
        except Exception:
            pass

    # --- A2A ---

    async def open_task(self, task_id: str, title: str, status: str = 'working'):
        await self.call_tool('open_task', {
            'taskId': task_id,
            'title': title,
            'status': status,
        })

    async def append_message(self, task_id: str, role: str, text: str):
        await self.call_tool('append_message', {
            'taskId': task_id,
            'role': role,
            'parts': [{'type': 'text', 'text': text}],
        })

    async def put_artifact(self, task_id: str, artifact_id: str,
                           filename: str, mime_type: str,
                           description: str, file_path: str):
        await self.call_tool('put_artifact', {
            'taskId': task_id,
            'artifactId': artifact_id,
            'filename': filename,
            'mimeType': mime_type,
            'description': description,
            'filePath': file_path,
        })

    # --- inbound ---

    async def read_stdin(self):
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        try:
            async for raw in reader:
                try:
                    line = raw.decode('utf-8', errors='replace').strip()
                    if not line:
                        continue
                    await self._dispatch(json.loads(line))
                except Exception:
                    pass
        except Exception as e:
            print(f'[brew-monitor] stdin reader error: {type(e).__name__}: {e}', file=sys.stderr)

    async def _dispatch(self, msg):
        rpc_id = msg.get('id')

        if rpc_id is not None and 'result' in msg:
            fut = self._pending_rpc.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return

        if rpc_id is not None and 'error' in msg:
            fut = self._pending_rpc.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return

        if msg.get('method') == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value    = data.get('value', '')
                cb = self._response_cbs.pop(block_id, None)
                if cb:
                    asyncio.create_task(cb(value))


# ---------------------------------------------------------------------------
# Homebrew helpers
# ---------------------------------------------------------------------------

def _clean_version(v):
    """Normalise version: handle list-or-string, strip cask build suffix."""
    if isinstance(v, list):
        v = v[0] if v else '?'
    return str(v).split(',')[0]


def get_outdated():
    """Return sorted list of (name, installed, available) for all outdated packages."""
    brew = find_brew()
    if not brew:
        print('[brew-monitor] brew not found', file=sys.stderr)
        return []
    try:
        result = subprocess.run(
            [brew, 'outdated', '--json=v2'],
            capture_output=True, text=True, timeout=60,
        )
        data = json.loads(result.stdout)
    except Exception as e:
        print(f'[brew-monitor] brew outdated failed: {e}', file=sys.stderr)
        return []

    items = []
    for f in data.get('formulae', []):
        installed = _clean_version(f.get('installed_versions', '?'))
        available = _clean_version(f.get('current_version', '?'))
        items.append((f['name'], installed, available))

    for c in data.get('casks', []):
        installed = _clean_version(c.get('installed_versions', '?'))
        available = _clean_version(c.get('current_version', '?'))
        items.append((c['name'], installed, available))

    return sorted(items, key=lambda x: x[0].lower())


# ---------------------------------------------------------------------------
# Monitor logic
# ---------------------------------------------------------------------------

class BrewMonitor:
    def __init__(self, mcp: MCPClient):
        self.mcp = mcp
        self._sync_event = asyncio.Event()
        self._pending_outdated: list = []

    async def run(self):
        while True:
            try:
                await self._check()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f'[brew-monitor] _check error: {type(e).__name__}: {e}', file=sys.stderr)
                traceback.print_exc(file=sys.stderr)
            self._sync_event.clear()
            try:
                await asyncio.wait_for(self._sync_event.wait(), timeout=CHECK_INTERVAL)
                print('[brew-monitor] manual sync triggered', file=sys.stderr)
            except asyncio.TimeoutError:
                pass

    async def _check(self):
        print('[brew-monitor] checking for outdated packages…', file=sys.stderr)

        await self.mcp.clear_block(BLOCK_NEXT_SYNC)
        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Checking for Homebrew updates…',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=60)

        outdated = get_outdated()
        await self.mcp.clear_block(BLOCK_STATUS)

        now_str = datetime.now().strftime('%H:%M')

        if not outdated:
            print('[brew-monitor] all packages up to date', file=sys.stderr)
            await self.mcp.clear_block(BLOCK_UPDATES)
            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': 'All up to date',
                'body': f'Checked {now_str}',
                'status_color': 'green',
                'action_required': False,
            })
        else:
            self._pending_outdated = outdated
            count = len(outdated)
            noun  = 'update' if count == 1 else 'updates'
            title = f'{count} Homebrew {noun} available'
            body  = '\n'.join(f'{name}  {inst} → {avail}' for name, inst, avail in outdated)

            print(f'[brew-monitor] {title}', file=sys.stderr)

            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': title,
                'body': f'Checked {now_str}',
                'status_color': 'yellow',
                'action_required': True,
            })

            self.mcp._response_cbs[BLOCK_UPDATES] = self._on_response
            await self.mcp.emit_block(BLOCK_UPDATES, 'confirmation', {
                'title': title,
                'body':  body,
                'options': ['Upgrade All', 'Later'],
            }, ttl=86400, inbox=True)

        # Countdown to next check
        next_sync = datetime.now(timezone.utc) + timedelta(seconds=CHECK_INTERVAL)
        next_sync_str = next_sync.strftime('%Y-%m-%dT%H:%M:%SZ')
        await self.mcp.emit_block(BLOCK_NEXT_SYNC, 'countdown', {
            'label': 'Next sync',
            'time':  next_sync_str,
        }, ttl=CHECK_INTERVAL + 300)

        await self._emit_sync_now()

    async def _emit_sync_now(self):
        self.mcp._response_cbs[BLOCK_SYNC_NOW] = self._on_sync_now
        await self.mcp.emit_block(BLOCK_SYNC_NOW, 'confirmation', {
            'title':   'Homebrew',
            'body':    'Trigger an immediate package check.',
            'options': ['Sync Now'],
        }, ttl=CHECK_INTERVAL + 300)

    async def _on_sync_now(self, _value):
        self._sync_event.set()

    async def _on_response(self, value):
        try:
            await self.mcp.clear_block(BLOCK_UPDATES)
            if value != 'Upgrade All':
                return
            await self._upgrade()
            await self._check()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            print(f'[brew-monitor] _on_response error: {type(e).__name__}: {e}', file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    async def _upgrade(self):
        pkgs = self._pending_outdated
        task_id = f'brew-upgrade-{uuid.uuid4().hex[:8]}'
        now_dt  = datetime.now()
        now_str = now_dt.strftime('%Y-%m-%d %H:%M')

        print(f'[brew-monitor] running brew upgrade… task_id={task_id}', file=sys.stderr)

        try:
            # Open task
            await self.mcp.open_task(task_id, f'Homebrew upgrade · {now_str}')

            # User prompt message
            await self.mcp.append_message(task_id, 'user',
                'Upgrade all outdated Homebrew packages.')

            # Agent: list what will be upgraded
            count = len(pkgs)
            noun  = 'package' if count == 1 else 'packages'
            pkg_table = '\n'.join(f'- **{name}** {inst} → {avail}' for name, inst, avail in pkgs)
            await self.mcp.append_message(task_id, 'assistant',
                f'Upgrading {count} {noun}:\n\n{pkg_table}')

            # Update tile
            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': f'Upgrading {count} {noun}…',
                'body':  'Running brew upgrade',
                'status_color': 'blue',
                'action_required': False,
            })
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label':  'Upgrading Homebrew packages…',
                'detail': 'Starting…',
                'icon':   'arrow.down.circle',
                'color':  'blue',
            }, ttl=3 * 60 * 60)

            # Run brew upgrade, stream output
            brew = find_brew() or 'brew'
            proc = await asyncio.create_subprocess_exec(
                brew, 'upgrade',
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )

            output_lines = []
            loop = asyncio.get_event_loop()
            last_update = loop.time()
            current_pkg = ''

            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                decoded = line.decode('utf-8', errors='replace').rstrip()
                output_lines.append(decoded)
                print(f'[brew-upgrade] {decoded}', file=sys.stderr)

                if decoded.startswith('==> Upgrading '):
                    current_pkg = decoded[len('==> Upgrading '):]
                elif decoded.startswith('==> Installing '):
                    current_pkg = decoded[len('==> Installing '):]

                now = loop.time()
                if current_pkg and (now - last_update) >= 3.0:
                    last_update = now
                    try:
                        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                            'label':  'Upgrading Homebrew packages…',
                            'detail': f'Installing {current_pkg}',
                            'icon':   'arrow.down.circle',
                            'color':  'blue',
                        }, ttl=3 * 60 * 60)
                    except Exception as e:
                        print(f'[brew-monitor] status update failed: {e}', file=sys.stderr)

            await proc.wait()
            rc = proc.returncode
            print(f'[brew-monitor] brew upgrade exited {rc}', file=sys.stderr)

            # Write markdown report
            full_output = '\n'.join(output_lines)
            table_rows = '\n'.join(
                f'| {name} | {inst} | {avail} |' for name, inst, avail in pkgs
            )
            report = '\n'.join([
                f'# Homebrew Upgrade Report — {now_str}',
                '',
                f'## {count} {noun} upgraded' if rc == 0 else f'## Upgrade failed ({count} {noun} attempted)',
                '',
                '| Package | From | To |',
                '|---------|------|----|',
                table_rows,
                '',
                '## Output',
                '```',
                full_output,
                '```',
                '',
                '---',
                f'Generated by brew-monitor at {now_str}',
            ])

            tmp = tempfile.NamedTemporaryFile(
                mode='w', suffix='.md', delete=False, encoding='utf-8'
            )
            tmp.write(report)
            tmp.close()

            filename = f'brew-upgrade-{now_dt.strftime("%Y%m%d-%H%M")}.md'
            artifact_id = f'brew-report-{uuid.uuid4().hex[:8]}'

            if rc == 0:
                result_text = f'Upgrade complete. {count} {noun} updated successfully.'
                await self.mcp.append_message(task_id, 'assistant', result_text)
                await self.mcp.put_artifact(
                    task_id=task_id,
                    artifact_id=artifact_id,
                    filename=filename,
                    mime_type='text/plain',
                    description=f'Full upgrade log — {count} {noun}',
                    file_path=tmp.name,
                )
                await self.mcp.open_task(task_id, f'Homebrew upgrade · {now_str}', status='completed')

                tile_label = f'{count} {noun} upgraded'
                tile_color = 'green'
                await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                    'label': 'Upgrades complete',
                    'icon':  'checkmark.circle',
                    'color': 'green',
                }, ttl=30)
                await asyncio.sleep(5)
            else:
                await self.mcp.append_message(task_id, 'assistant',
                    f'Upgrade finished with errors (exit code {rc}). See the attached report for details.')
                await self.mcp.put_artifact(
                    task_id=task_id,
                    artifact_id=artifact_id,
                    filename=filename,
                    mime_type='text/plain',
                    description='Upgrade log (errors)',
                    file_path=tmp.name,
                )
                await self.mcp.open_task(task_id, f'Homebrew upgrade · {now_str}', status='failed')

                tile_label = 'Upgrade failed'
                tile_color = 'red'
                await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                    'label': 'Upgrade finished with errors',
                    'icon':  'exclamationmark.triangle',
                    'color': 'orange',
                }, ttl=60)
                await asyncio.sleep(10)

            os.unlink(tmp.name)

            finish_str = datetime.now().strftime('%H:%M')
            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': tile_label,
                'body':  f'Finished {finish_str}',
                'status_color': tile_color,
                'action_required': False,
            })

        except asyncio.CancelledError:
            print('[brew-monitor] upgrade cancelled', file=sys.stderr)
            raise
        except Exception as e:
            print(f'[brew-monitor] upgrade error: {type(e).__name__}: {e}', file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
        finally:
            await self.mcp.clear_block(BLOCK_STATUS)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    mcp     = MCPClient()
    monitor = BrewMonitor(mcp)

    stdin_task = asyncio.create_task(mcp.read_stdin())

    try:
        await mcp.initialize()
    except Exception as e:
        print(f'[brew-monitor] init error: {type(e).__name__}: {e}', file=sys.stderr)
        return

    # Persistent tile on startup
    await mcp.emit_block(BLOCK_TILE, 'tile', {
        'label': 'Homebrew',
        'body':  'Checking for updates…',
        'status_color': 'gray',
        'action_required': False,
    })

    monitor_task = asyncio.create_task(monitor.run())
    done, pending = await asyncio.wait(
        {stdin_task, monitor_task},
        return_when=asyncio.FIRST_EXCEPTION,
    )

    for task in done:
        if task.exception():
            print(f'[brew-monitor] task error: {task.exception()}', file=sys.stderr)
            traceback.print_exception(type(task.exception()), task.exception(),
                                      task.exception().__traceback__, file=sys.stderr)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
