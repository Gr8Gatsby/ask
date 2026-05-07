#!/usr/bin/env python3
"""
gdocs-history — Ask daemon script
Parses Safari and Chrome history to surface Google Docs viewed in the last 30 days.
Communicates with AskMac via JSON-RPC 2.0 over stdio.
"""
import sys
import json
import asyncio
import sqlite3
import shutil
import tempfile
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

# CRITICAL: unbuffered stdout so JSON-RPC messages reach the daemon immediately.
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

CHECK_INTERVAL = 6 * 60 * 60   # re-scan every 6 hours
TEST_INTERVAL  = 10
DAYS_BACK      = 30

BLOCK_TILE   = 'gdocs-tile'
BLOCK_LIST   = 'gdocs-list'
BLOCK_STATUS = 'gdocs-status'

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
# History parsing
# ---------------------------------------------------------------------------

# Apple epoch: seconds since 2001-01-01 UTC
_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
# Chrome epoch: microseconds since 1601-01-01 UTC
_CHROME_EPOCH = datetime(1601, 1, 1, tzinfo=timezone.utc)

GDOC_URL_RE = re.compile(r'https://docs\.google\.com/document/d/([^/?#]+)')


def _doc_id_from_url(url: str) -> Optional[str]:
    m = GDOC_URL_RE.search(url)
    return m.group(1) if m else None


def _copy_db(src: Path) -> Optional[Path]:
    """Copy a SQLite DB (+ WAL/SHM if present) to a temp dir. Returns temp DB path."""
    if not src.exists():
        return None
    tmp_dir = Path(tempfile.mkdtemp(prefix='gdocs_'))
    dst = tmp_dir / src.name
    try:
        shutil.copy2(src, dst)
        for ext in ('-wal', '-shm'):
            companion = src.with_suffix('').parent / (src.name + ext)
            if companion.exists():
                shutil.copy2(companion, tmp_dir / (src.name + ext))
    except Exception as e:
        print(f'[gdocs-history] copy_db error for {src}: {e}', file=sys.stderr)
        return None
    return dst


def _query_db(db_path: Path, query: str, params=()) -> list[tuple]:
    try:
        con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=5)
        con.row_factory = sqlite3.Row
        rows = con.execute(query, params).fetchall()
        con.close()
        return rows
    except Exception as e:
        print(f'[gdocs-history] db query error: {e}', file=sys.stderr)
        return []


def scan_safari(cutoff: datetime) -> dict[str, tuple[str, datetime]]:
    """Returns {doc_id: (title, last_visited)} from Safari history."""
    db_src = Path.home() / 'Library/Safari/History.db'
    db = _copy_db(db_src)
    if not db:
        return {}

    # Apple visit_time is seconds since 2001-01-01 UTC
    cutoff_apple = (cutoff - _APPLE_EPOCH).total_seconds()

    rows = _query_db(db, """
        SELECT hi.url, hv.title, MAX(hv.visit_time) AS last_visit
        FROM history_visits hv
        JOIN history_items hi ON hv.history_item = hi.id
        WHERE hi.url LIKE '%docs.google.com/document/d/%'
          AND hv.visit_time >= ?
        GROUP BY hi.id
        ORDER BY last_visit DESC
    """, (cutoff_apple,))

    shutil.rmtree(db.parent, ignore_errors=True)

    docs: dict[str, tuple[str, datetime]] = {}
    for row in rows:
        doc_id = _doc_id_from_url(row['url'])
        if not doc_id:
            continue
        title = row['title'] or row['url']
        visited = _APPLE_EPOCH + timedelta(seconds=row['last_visit'])
        if doc_id not in docs or visited > docs[doc_id][1]:
            docs[doc_id] = (title, visited)
    return docs


def scan_chrome(cutoff: datetime) -> dict[str, tuple[str, datetime]]:
    """Returns {doc_id: (title, last_visited)} from Chrome history."""
    db_src = Path.home() / 'Library/Application Support/Google/Chrome/Default/History'
    db = _copy_db(db_src)
    if not db:
        return {}

    # Chrome uses microseconds since 1601-01-01
    cutoff_chrome = int((cutoff - _CHROME_EPOCH).total_seconds() * 1_000_000)

    rows = _query_db(db, """
        SELECT url, title, last_visit_time
        FROM urls
        WHERE url LIKE '%docs.google.com/document/d/%'
          AND last_visit_time >= ?
        ORDER BY last_visit_time DESC
    """, (cutoff_chrome,))

    shutil.rmtree(db.parent, ignore_errors=True)

    docs: dict[str, tuple[str, datetime]] = {}
    for row in rows:
        doc_id = _doc_id_from_url(row['url'])
        if not doc_id:
            continue
        title = row['title'] or row['url']
        visited = _CHROME_EPOCH + timedelta(microseconds=row['last_visit_time'])
        if doc_id not in docs or visited > docs[doc_id][1]:
            docs[doc_id] = (title, visited)
    return docs


def get_recent_docs() -> list[tuple[str, datetime]]:
    """
    Returns list of (title, last_visited) for unique Google Docs,
    sorted newest-first, deduped by doc ID across browsers.
    """
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=DAYS_BACK)

    safari = scan_safari(cutoff)
    chrome = scan_chrome(cutoff)

    merged: dict[str, tuple[str, datetime]] = {}
    for doc_id, (title, visited) in {**safari, **chrome}.items():
        if doc_id not in merged or visited > merged[doc_id][1]:
            merged[doc_id] = (title, visited)

    return sorted(merged.values(), key=lambda x: x[1], reverse=True)


# ---------------------------------------------------------------------------
# Block emitters
# ---------------------------------------------------------------------------

async def emit_tile(mcp: MCPClient, count: int):
    label = f'{count} Google Doc{"s" if count != 1 else ""} this month'
    await mcp.emit_block(BLOCK_TILE, 'tile', {
        'label':        label,
        'status_color': 'blue' if count > 0 else 'green',
        'body':         'Tap to view list',
    }, ttl=600)


async def emit_list(mcp: MCPClient, docs: list[tuple[str, datetime]]):
    now = datetime.now(tz=timezone.utc)

    def fmt_date(dt: datetime) -> str:
        dt_local = dt.astimezone()
        delta = now - dt
        if delta.days == 0:
            return 'Today'
        elif delta.days == 1:
            return 'Yesterday'
        elif delta.days < 7:
            return dt_local.strftime('%A')       # "Monday"
        elif dt_local.year == now.astimezone().year:
            return dt_local.strftime('%b %-d')   # "Jan 5"
        else:
            return dt_local.strftime('%b %-d %Y')

    # info_card pairs: title (truncated) → last viewed date
    MAX_DOCS = 25
    shown = docs[:MAX_DOCS]
    pairs = [
        {
            'key':   (t[:38] + '…') if len(t) > 39 else t,
            'value': fmt_date(d),
        }
        for t, d in shown
    ]

    suffix = f' (showing {MAX_DOCS})' if len(docs) > MAX_DOCS else ''
    await mcp.emit_block(BLOCK_LIST, 'info_card', {
        'title': f'Google Docs — last {DAYS_BACK} days{suffix}',
        'pairs': pairs,
    }, ttl=CHECK_INTERVAL)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

async def _tile_heartbeat(mcp: MCPClient):
    """Re-emits the tile every 5 min so it stays visible on the home screen."""
    while True:
        await asyncio.sleep(300)
        try:
            docs = await asyncio.get_running_loop().run_in_executor(None, get_recent_docs)
            await emit_tile(mcp, len(docs))
        except Exception as e:
            print(f'[gdocs-history] heartbeat error: {e}', file=sys.stderr)


async def check(mcp: MCPClient):
    print('[gdocs-history] scanning browser history…', file=sys.stderr)

    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label': 'Scanning history…',
        'icon':  'arrow.clockwise',
        'color': 'blue',
    }, ttl=60)

    # Run blocking DB work off the event loop
    loop = asyncio.get_running_loop()
    docs = await loop.run_in_executor(None, get_recent_docs)

    now_str = datetime.now().strftime('%-I:%M %p')
    print(f'[gdocs-history] found {len(docs)} docs', file=sys.stderr)

    await mcp.clear_block(BLOCK_STATUS)
    await emit_tile(mcp, len(docs))

    if docs:
        await emit_list(mcp, docs)
    else:
        await mcp.emit_block(BLOCK_LIST, 'info_card', {
            'title': f'Google Docs — last {DAYS_BACK} days',
            'pairs': [{'key': 'No documents found', 'value': ''}],
        }, ttl=CHECK_INTERVAL)

    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label':  f'{len(docs)} doc{"s" if len(docs) != 1 else ""} in last {DAYS_BACK} days',
        'detail': f'Last scanned {now_str}',
        'icon':   'doc.text.magnifyingglass',
        'color':  'blue' if len(docs) > 0 else 'green',
    }, ttl=CHECK_INTERVAL)


async def run(mcp: MCPClient, test_mode: bool):
    interval = TEST_INTERVAL if test_mode else CHECK_INTERVAL
    runs = 0

    asyncio.create_task(_tile_heartbeat(mcp))

    while True:
        try:
            await check(mcp)
        except Exception as e:
            print(f'[gdocs-history] check error: {e}', file=sys.stderr)

        runs += 1
        if test_mode and runs >= 1:
            print('[gdocs-history] test mode complete', file=sys.stderr)
            await asyncio.sleep(60)
            return

        await asyncio.sleep(interval)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[gdocs-history] running in test mode', file=sys.stderr)

    mcp = MCPClient()

    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='gdocs-history')
    await run(mcp, test_mode=test_mode)

def _install_parent_watchdog():
    """Exit if our parent (AskMac) goes away — prevents zombie scripts that
    retain AskMac's TCC identity and trigger ghost prompts."""
    import threading, time
    def _watch():
        while True:
            time.sleep(5)
            if os.getppid() == 1:
                print('[gdocs-history] parent (AskMac) gone — exiting', file=sys.stderr, flush=True)
                os._exit(0)
    threading.Thread(target=_watch, daemon=True).start()


if __name__ == '__main__':
    _install_parent_watchdog()
    asyncio.run(main())
