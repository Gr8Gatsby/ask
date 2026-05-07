#!/usr/bin/env python3
"""
web-traffic — Parses browser history to show websites visited daily.
Collects URLs from Safari, Chrome variants, and Firefox; pipes them
through a Zig binary for fast domain aggregation; surfaces results on iOS.
"""
import sys
import json
import asyncio
import subprocess
import sqlite3
import os
import shutil
import tempfile
from datetime import datetime, date
from pathlib import Path

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SCRIPT_DIR     = Path(__file__).parent
PARSER_BIN     = SCRIPT_DIR / 'web-traffic-parser'
CHECK_INTERVAL = 20 * 60   # refresh every 20 minutes
TEST_INTERVAL  = 60

BLOCK_TILE   = 'web-traffic-tile'
BLOCK_SITES  = 'web-traffic-sites'
BLOCK_STATUS = 'web-traffic-status'

# Epoch offsets
APPLE_EPOCH_OFFSET  = 978307200           # secs: Unix epoch → CoreData epoch (2001-01-01)
CHROME_EPOCH_OFFSET = 11644473600_000_000 # µs: 1601-01-01 → Unix epoch

# Chromium-family browsers to try (relative to ~/Library/Application Support)
CHROME_VARIANTS = [
    'Google/Chrome/Default',
    'Google/Chrome Beta/Default',
    'Google/Chrome Canary/Default',
    'Chromium/Default',
    'Brave Browser/Default',
    'Microsoft Edge/Default',
    'Arc/User Data/Default',
    'Vivaldi/Default',
    'Opera/Default',
]

# ---------------------------------------------------------------------------
# MCPClient
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
        rid  = self._id
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
            'clientInfo': {'name': client_name, 'version': '1.0'},
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

    async def read_loop(self):
        loop = asyncio.get_running_loop()
        buf  = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, buf.readline)
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
# Browser history collection
# ---------------------------------------------------------------------------

def _today_unix() -> float:
    d = date.today()
    return float(datetime(d.year, d.month, d.day).timestamp())


def _copy_and_query(db_path: Path, sql: str, params: tuple) -> list[str]:
    """Copy a potentially-locked SQLite DB to tmp, query it, return URL strings."""
    with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as tmp:
        shutil.copy2(db_path, tmp.name)
        tmp_path = tmp.name
    try:
        conn = sqlite3.connect(f'file:{tmp_path}?mode=ro', uri=True)
        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [r[0] for r in rows if r[0]]
    finally:
        os.unlink(tmp_path)


def query_safari(today_unix: float) -> list[str]:
    db = Path.home() / 'Library/Safari/History.db'
    if not db.exists():
        return []
    today_cf = today_unix - APPLE_EPOCH_OFFSET  # CoreData epoch
    try:
        return _copy_and_query(db,
            '''SELECT hi.url
               FROM history_visits hv
               JOIN history_items hi ON hv.history_item = hi.id
               WHERE hv.visit_time >= ?''',
            (today_cf,))
    except Exception as e:
        print(f'[web-traffic] safari: {e}', file=sys.stderr)
        return []


def query_chrome(db_path: Path, today_unix: float) -> list[str]:
    if not db_path.exists():
        return []
    today_chrome = int(today_unix * 1_000_000) + CHROME_EPOCH_OFFSET
    try:
        return _copy_and_query(db_path,
            '''SELECT u.url
               FROM visits v
               JOIN urls u ON v.url = u.id
               WHERE v.visit_time >= ?''',
            (today_chrome,))
    except Exception as e:
        print(f'[web-traffic] chrome ({db_path.parent.parent.name}): {e}', file=sys.stderr)
        return []


def query_firefox(today_unix: float) -> list[str]:
    profiles = Path.home() / 'Library/Application Support/Firefox/Profiles'
    if not profiles.exists():
        return []
    today_us = int(today_unix * 1_000_000)
    urls: list[str] = []
    for profile in profiles.iterdir():
        db = profile / 'places.sqlite'
        if not db.exists():
            continue
        try:
            urls += _copy_and_query(db,
                '''SELECT p.url
                   FROM moz_historyvisits v
                   JOIN moz_places p ON v.place_id = p.id
                   WHERE v.visit_date >= ?''',
                (today_us,))
        except Exception as e:
            print(f'[web-traffic] firefox ({profile.name}): {e}', file=sys.stderr)
    return urls


def collect_urls() -> list[str]:
    today  = _today_unix()
    urls: list[str] = []
    urls  += query_safari(today)
    app    = Path.home() / 'Library/Application Support'
    for variant in CHROME_VARIANTS:
        urls += query_chrome(app / variant / 'History', today)
    urls  += query_firefox(today)
    # Only keep http/https — filters out chrome-extension://, about:, etc.
    return [u for u in urls if u.startswith(('http://', 'https://'))]


# ---------------------------------------------------------------------------
# Zig parser
# ---------------------------------------------------------------------------

def run_parser(urls: list[str]) -> list[dict]:
    """Pipe URLs (one per line) through the Zig binary; returns [{domain, count}]."""
    if not PARSER_BIN.exists():
        print('[web-traffic] parser binary missing — run build.sh', file=sys.stderr)
        return []
    if not os.access(PARSER_BIN, os.X_OK):
        print('[web-traffic] parser binary not executable', file=sys.stderr)
        return []
    if not urls:
        return []
    try:
        result = subprocess.run(
            [str(PARSER_BIN)],
            input='\n'.join(urls).encode(),
            capture_output=True,
            timeout=15,
        )
        if result.returncode != 0:
            print(f'[web-traffic] parser stderr: {result.stderr.decode()[:200]}', file=sys.stderr)
            return []
        return json.loads(result.stdout.decode())
    except Exception as e:
        print(f'[web-traffic] parser failed: {e}', file=sys.stderr)
        return []


# ---------------------------------------------------------------------------
# Block emission
# ---------------------------------------------------------------------------

async def emit_tile(mcp: MCPClient, total_sites: int, total_visits: int):
    if total_sites == 0:
        label, color = 'No visits today', 'gray'
        body         = None
    else:
        label = f'{total_sites} site{"s" if total_sites != 1 else ""} today'
        color = 'blue'
        body  = f'{total_visits} total visit{"s" if total_visits != 1 else ""}'
    await mcp.emit_block(BLOCK_TILE, 'tile', {
        'label':        label,
        'status_color': color,
        'body':         body,
    }, ttl=CHECK_INTERVAL + 120)


async def emit_sites(mcp: MCPClient, domain_counts: list[dict]):
    today_str = date.today().strftime('%b %-d')
    top       = domain_counts[:20]

    if not top:
        await mcp.emit_block(BLOCK_SITES, 'status', {
            'label': 'No web activity today',
            'icon':  'globe',
            'color': 'gray',
        }, ttl=CHECK_INTERVAL + 120)
        return

    pairs = []
    for dc in top:
        n     = dc['count']
        pairs.append({'key': dc['domain'], 'value': f'{n} visit{"s" if n != 1 else ""}'})

    await mcp.emit_block(BLOCK_SITES, 'info_card', {
        'title': f'Top Sites — {today_str}',
        'pairs': pairs,
    }, ttl=CHECK_INTERVAL + 120)


# ---------------------------------------------------------------------------
# Check loop
# ---------------------------------------------------------------------------

async def check(mcp: MCPClient):
    print('[web-traffic] scanning browser history…', file=sys.stderr)
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label': 'Scanning history…',
        'icon':  'arrow.clockwise',
        'color': 'blue',
    }, ttl=60)

    urls          = collect_urls()
    domain_counts = run_parser(urls)

    await mcp.clear_block(BLOCK_STATUS)

    total_sites  = len(domain_counts)
    total_visits = sum(dc['count'] for dc in domain_counts)
    print(f'[web-traffic] {total_sites} sites, {total_visits} visits today', file=sys.stderr)

    await emit_tile(mcp, total_sites, total_visits)
    await emit_sites(mcp, domain_counts)


async def _heartbeat(mcp: MCPClient):
    while True:
        await asyncio.sleep(CHECK_INTERVAL)
        try:
            await check(mcp)
        except Exception as e:
            print(f'[web-traffic] heartbeat error: {e}', file=sys.stderr)


async def run(mcp: MCPClient, test_mode: bool):
    asyncio.create_task(_heartbeat(mcp))

    try:
        await check(mcp)
    except Exception as e:
        print(f'[web-traffic] initial check error: {e}', file=sys.stderr)

    if test_mode:
        print('[web-traffic] test mode complete', file=sys.stderr)
        await asyncio.sleep(TEST_INTERVAL)
        return

    # Run forever — AskMac manages our process lifetime
    while True:
        await asyncio.sleep(3600)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[web-traffic] running in test mode', file=sys.stderr)

    mcp = MCPClient()
    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='web-traffic')
    await run(mcp, test_mode=test_mode)


def _install_parent_watchdog():
    """Exit if our parent (AskMac) goes away — prevents zombie scripts that
    retain AskMac's TCC identity and trigger ghost prompts."""
    import threading, time
    def _watch():
        while True:
            time.sleep(5)
            if os.getppid() == 1:
                print('[web-traffic] parent (AskMac) gone — exiting', file=sys.stderr, flush=True)
                os._exit(0)
    threading.Thread(target=_watch, daemon=True).start()


if __name__ == '__main__':
    _install_parent_watchdog()
    asyncio.run(main())
