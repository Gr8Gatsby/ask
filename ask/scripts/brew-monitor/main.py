#!/usr/bin/env python3
"""
brew-monitor — surfaces outdated Homebrew packages on iPhone.

Checks every CHECK_INTERVAL seconds. When packages are outdated, emits a
confirmation block. If the user taps "Upgrade All", runs `brew upgrade`
and reports the result. Tapping "Later" dismisses until the next check.
"""
import asyncio
import json
import os
import shutil
import subprocess
import sys
import traceback
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

BLOCK_UPDATES    = 'brew-monitor-updates'
BLOCK_STATUS     = 'brew-monitor-status'
BLOCK_UP_TO_DATE = 'brew-monitor-uptodate'
BLOCK_NEXT_SYNC  = 'brew-monitor-next-sync'
BLOCK_SYNC_NOW   = 'brew-monitor-sync-now'


# ---------------------------------------------------------------------------
# Minimal MCP client (same JSON-RPC 2.0 protocol as all Ask scripts)
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._next_id = 0
        self._pending_rpc = {}       # rpc_id  -> Future
        self._response_cbs = {}      # block_id -> async callable(value)
        self._pipe_broken  = False   # set True on BrokenPipeError; stop writing

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

    async def initialize(self):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'brew-monitor', 'version': '1.0'},
        })
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print('[brew-monitor] MCP initialized', file=sys.stderr)

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id):
        try:
            await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})
        except Exception:
            pass

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
        self._pending_outdated: list = []   # saved before upgrade so feed_item can list them

    async def run(self):
        while True:
            try:
                await self._check()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f'[brew-monitor] _check error: {type(e).__name__}: {e}', file=sys.stderr)
                traceback.print_exc(file=sys.stderr)
            # Wait for the interval OR a manual sync request, whichever comes first
            self._sync_event.clear()
            try:
                await asyncio.wait_for(self._sync_event.wait(), timeout=CHECK_INTERVAL)
                print('[brew-monitor] manual sync triggered', file=sys.stderr)
            except asyncio.TimeoutError:
                pass

    async def _check(self):
        print('[brew-monitor] checking for outdated packages…', file=sys.stderr)

        # Clear the countdown while checking so the status block takes its place
        await self.mcp.clear_block(BLOCK_NEXT_SYNC)

        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Checking for Homebrew updates…',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=60)

        outdated = get_outdated()
        await self.mcp.clear_block(BLOCK_STATUS)

        if not outdated:
            print('[brew-monitor] all packages up to date', file=sys.stderr)
            await self.mcp.clear_block(BLOCK_UPDATES)
            await self.mcp.emit_block(BLOCK_UP_TO_DATE, 'status', {
                'label': 'Homebrew up to date',
                'icon': 'checkmark.circle',
                'color': 'green',
            }, ttl=CHECK_INTERVAL)
            feed_id = f'brew-monitor-feed-{int(datetime.now(timezone.utc).timestamp())}'
            await self.mcp.emit_block(feed_id, 'feed_item', {
                'headline': 'Homebrew — all packages up to date',
                'statusColor': 'green',
            }, ttl=CHECK_INTERVAL + 300, inbox=True)
            print('[brew-monitor] emitted up-to-date block', file=sys.stderr)
        else:
            await self.mcp.clear_block(BLOCK_UP_TO_DATE)
            self._pending_outdated = outdated

            count = len(outdated)
            noun  = 'update' if count == 1 else 'updates'
            title = f'{count} Homebrew {noun} available'
            body  = '\n'.join(f'{name}  {inst} → {avail}' for name, inst, avail in outdated)

            print(f'[brew-monitor] {title}', file=sys.stderr)

            # Register callback BEFORE emitting so a slow CloudKit write can't orphan it
            self.mcp._response_cbs[BLOCK_UPDATES] = self._on_response

            await self.mcp.emit_block(BLOCK_UPDATES, 'confirmation', {
                'title': title,
                'body':  body,
                'options': ['Upgrade All', 'Later'],
            }, ttl=86400, inbox=True)

        # Emit countdown to next check
        next_sync = datetime.now(timezone.utc) + timedelta(seconds=CHECK_INTERVAL)
        next_sync_str = next_sync.strftime('%Y-%m-%dT%H:%M:%SZ')
        await self.mcp.emit_block(BLOCK_NEXT_SYNC, 'countdown', {
            'label': 'Next sync',
            'time':  next_sync_str,
        }, ttl=CHECK_INTERVAL + 300)
        print(f'[brew-monitor] next sync at {next_sync_str}', file=sys.stderr)

        # Emit sync-now button
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
        print('[brew-monitor] running brew upgrade…', file=sys.stderr)
        try:
            # TTL covers the longest realistic upgrade (3 hours for large packages)
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label':  'Upgrading Homebrew packages…',
                'detail': 'Starting…',
                'icon':   'arrow.down.circle',
                'color':  'blue',
            }, ttl=3 * 60 * 60)

            brew = find_brew() or 'brew'
            proc = await asyncio.create_subprocess_exec(
                brew, 'upgrade',
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )

            loop = asyncio.get_event_loop()
            last_update = loop.time()
            current_pkg = ''

            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                decoded = line.decode('utf-8', errors='replace').rstrip()
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
                        print(f'[brew-monitor] status update failed: {type(e).__name__}: {e}', file=sys.stderr)

            await proc.wait()
            print(f'[brew-monitor] brew upgrade exited {proc.returncode}', file=sys.stderr)

            if proc.returncode == 0:
                await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                    'label': 'Upgrades complete',
                    'icon':  'checkmark.circle',
                    'color': 'green',
                }, ttl=30)
                pkgs = self._pending_outdated
                count = len(pkgs)
                noun = 'package' if count == 1 else 'packages'
                headline = f'Homebrew — {count} {noun} upgraded' if count else 'Homebrew — packages upgraded'
                body = '\n'.join(f'{name}  {inst} → {avail}' for name, inst, avail in pkgs) if pkgs else None
                feed_id = f'brew-monitor-feed-{int(datetime.now(timezone.utc).timestamp())}'
                await self.mcp.emit_block(feed_id, 'feed_item', {
                    'headline': headline,
                    'body':     body,
                    'statusColor': 'green',
                }, ttl=86400 * 30, inbox=True)
                await asyncio.sleep(5)
            else:
                await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                    'label': 'Upgrade finished with errors',
                    'icon':  'exclamationmark.triangle',
                    'color': 'orange',
                }, ttl=60)
                feed_id = f'brew-monitor-feed-{int(datetime.now(timezone.utc).timestamp())}'
                await self.mcp.emit_block(feed_id, 'feed_item', {
                    'headline': 'Homebrew — upgrade failed',
                    'statusColor': 'red',
                }, ttl=86400 * 30, inbox=True)
                await asyncio.sleep(10)

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

    # Run both tasks; if stdin closes (normal when daemon restarts), keep monitor
    # running. Use return_exceptions so a stdin error doesn't cancel monitor.run().
    monitor_task = asyncio.create_task(monitor.run())
    done, pending = await asyncio.wait(
        {stdin_task, monitor_task},
        return_when=asyncio.FIRST_EXCEPTION,
    )

    # If either task raised, log it
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
