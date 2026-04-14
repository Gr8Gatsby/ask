#!/usr/bin/env python3
"""
Layer 5: Concurrency Stress Tests for codex-2.

Tests the daemon's behavior when multiple socket messages arrive simultaneously,
ensuring no cross-contamination between sessions and that the permission system
resolves correctly under concurrent load.
"""
import json
import os
import sys
import socket as socket_lib
import subprocess
import threading
import time
from typing import Optional

import pytest

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')


# ── Concurrency Harness ───────────────────────────────────────────────────────

class ConcurrencyHarness:
    """Harness with full block capture and support for targeted RPC responses.

    Additions beyond the base Harness:
      - captured_blocks: (block_type, payload, block_id) for every emit_block
      - captured_block_ids: set of block_ids for quick membership testing
      - rpc_id_for_block: block_id → RPC id (so we can respond to specific emits)
      - pending_permissions: block_id → threading.Event for coordinating threads
    """

    def __init__(self, tmp_dir: str, extra_env: dict = None):
        self.tmp_dir = tmp_dir
        self.settings_path = os.path.join(tmp_dir, 'settings.json')
        self.allowlist_path = os.path.join(tmp_dir, 'allowlist.json')
        self.active_blocks_path = os.path.join(tmp_dir, 'active-blocks.json')
        self.hooks_path = os.path.join(tmp_dir, 'hooks.json')
        self.sessions_path = os.path.join(tmp_dir, 'sessions.json')
        self._sock_id = str(id(self))[-6:]
        self.socket_path = f'/tmp/codex2-conc-{self._sock_id}.sock'
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        self._extra_env = extra_env or {}

        # Concurrency tracking
        self.captured_blocks: list = []        # (block_type, payload, block_id)
        self.captured_block_ids: set = set()   # block_id → seen
        # Events fired when a specific block_id's emit_block is seen
        self._block_events: dict = {}          # block_id → threading.Event
        # block_id → rpc_id (for targeted responses)
        self._block_rpc_id: dict = {}

    def start(self):
        env = os.environ.copy()
        env['ASK_SOCKET_PATH'] = self.socket_path
        env['ASK_CODEX2_SETTINGS_PATH'] = self.settings_path
        env['ASK_CODEX2_ALLOWLIST_PATH'] = self.allowlist_path
        env['ASK_CODEX2_ACTIVE_BLOCKS_PATH'] = self.active_blocks_path
        env['ASK_CODEX2_HOOKS_PATH'] = self.hooks_path
        env['ASK_CODEX2_SESSIONS_PATH'] = self.sessions_path
        env['ASK_CODEX2_SKIP_DISCOVERY'] = '1'
        env.update(self._extra_env)
        self.proc = subprocess.Popen(
            [sys.executable, SCRIPT],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        t = threading.Thread(target=self._read_stdout, daemon=True)
        t.start()
        self._wait_for_socket()
        return self

    def enable_auto_respond(self):
        self._auto_respond = True

    def _read_stdout(self):
        for raw in self.proc.stdout:
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                with self._lock:
                    self._stdout_lines.append(msg)
                    if (msg.get('method') == 'tools/call'
                            and msg.get('params', {}).get('name') == 'emit_block'):
                        args = msg['params']['arguments']
                        bt = args.get('blockType', '')
                        payload = args.get('payload', {})
                        bid = args.get('blockId', '')
                        rpc_id = msg.get('id')
                        self.captured_blocks.append((bt, payload, bid))
                        self.captured_block_ids.add(bid)
                        self._block_rpc_id[bid] = rpc_id
                        # Fire any waiting event for this block_id
                        ev = self._block_events.get(bid)
                        if ev:
                            ev.set()
                if msg.get('method') == 'tools/call' and 'id' in msg and self._auto_respond:
                    self._send_ok(msg['id'])
            except json.JSONDecodeError:
                pass

    def _send_ok(self, rpc_id):
        self.rpc_response(rpc_id, {'content': [{'type': 'text', 'text': 'ok'}]})

    def _wait_for_socket(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(self.socket_path):
                return
            time.sleep(0.05)
        if self.proc and self.proc.poll() is not None:
            err = self.proc.stderr.read(2000).decode(errors='replace')
            raise RuntimeError(f'codex-2 exited before socket appeared; stderr: {err!r}')
        raise RuntimeError(f'codex-2 socket did not appear at {self.socket_path}')

    def rpc_response(self, rpc_id, result=None):
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'result': result or {}}
        self.proc.stdin.write((json.dumps(msg) + '\n').encode())
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout=5.0) -> Optional[dict]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for msg in self._stdout_lines:
                    if predicate(msg):
                        return msg
            time.sleep(0.05)
        return None

    def handshake(self) -> bool:
        init = self.wait_for(
            lambda m: m.get('method') == 'initialize' and 'id' in m
        )
        if not init:
            return False
        self.enable_auto_respond()
        self.rpc_response(init['id'], {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'serverInfo': {'name': 'test', 'version': '0.1'},
        })
        emit = self.wait_for(
            lambda m: m.get('method') == 'tools/call'
            and m.get('params', {}).get('name') == 'emit_block',
            timeout=5.0,
        )
        return emit is not None

    def socket_send(self, payload: dict, wait_response=False) -> Optional[dict]:
        """Send a message to the Unix socket; optionally wait for a response."""
        sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        sock.settimeout(10)
        try:
            sock.connect(self.socket_path)
            sock.sendall(json.dumps(payload).encode())
            if not wait_response:
                sock.shutdown(socket_lib.SHUT_WR)
                return None
            sock.shutdown(socket_lib.SHUT_WR)
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            data = b''.join(chunks)
            return json.loads(data) if data else None
        finally:
            sock.close()

    def send_notification(self, data: dict):
        """Send a notifications/message to stdin."""
        with self._lock:
            pass  # acquire then release to serialize writes
        self.proc.stdin.write((json.dumps({
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {'data': data},
        }) + '\n').encode())
        self.proc.stdin.flush()

    def wait_for_block_id(self, block_id: str, timeout=5.0) -> bool:
        """Wait until the given block_id has been emitted. Returns True on success."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                if block_id in self.captured_block_ids:
                    return True
            time.sleep(0.05)
        return False

    def all_agent_session_ids(self) -> set:
        """Return all distinct session_ids from captured agent_session blocks."""
        with self._lock:
            return {
                p.get('session_id', '')
                for bt, p, bid in self.captured_blocks
                if bt == 'agent_session'
            }

    def wait_for_n_agent_sessions(self, n: int, timeout=10.0) -> set:
        """Wait until at least n distinct agent_session session_ids are captured."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            ids = self.all_agent_session_ids()
            if len(ids) >= n:
                return ids
            time.sleep(0.1)
        return self.all_agent_session_ids()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if os.path.exists(self.socket_path):
            try:
                os.unlink(self.socket_path)
            except Exception:
                pass


@pytest.fixture
def harness(tmp_path):
    h = ConcurrencyHarness(str(tmp_path))
    h.start()
    assert h.handshake(), 'MCP handshake failed'
    yield h
    h.stop()


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_10_simultaneous_session_active(harness):
    """10 concurrent session_active messages produce 10 distinct agent_session blocks."""
    n = 10
    session_ids = [f'tmux-codex:proj{i}.0' for i in range(n)]

    # Fire all 10 session_active messages simultaneously from separate threads
    threads = []
    for sid in session_ids:
        project = sid.split(':')[1].split('.')[0]
        t = threading.Thread(
            target=harness.socket_send,
            args=({'type': 'session_active',
                   'session_id': sid,
                   'cwd': f'/tmp/{project}',
                   'tmux_target': f'codex:{project}.0'},),
            daemon=True,
        )
        threads.append(t)

    # Start all threads as close together as possible
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10.0)

    # Wait for all 10 agent_session blocks
    seen_ids = harness.wait_for_n_agent_sessions(n, timeout=10.0)

    # Each session_id should have been emitted as an agent_session block
    missing = [sid for sid in session_ids if sid not in seen_ids]
    assert not missing, (
        f'{len(missing)} of {n} concurrent sessions did not produce agent_session blocks.\n'
        f'Missing: {missing}\nSeen: {sorted(seen_ids)}'
    )
    assert len(seen_ids) >= n, (
        f'Expected {n} distinct agent_session session_ids; got {len(seen_ids)}: {sorted(seen_ids)}'
    )


def test_simultaneous_permission_requests_no_cross_contamination(harness):
    """3 concurrent permission_requests resolve to correct values (no cross-contamination).

    We register 3 sessions, fire 3 concurrent permission_request messages (each
    blocks on the socket waiting for a response), then reply to each from the
    main thread and verify each session got the right value.
    """
    sessions = [
        ('tmux-codex:alpha.0', 'Allow'),
        ('tmux-codex:beta.0', 'Deny'),
        ('tmux-codex:gamma.0', 'Always Allow'),
    ]

    # Register all 3 sessions
    for sid, _ in sessions:
        project = sid.split(':')[1].split('.')[0]
        harness.socket_send({
            'type': 'session_active',
            'session_id': sid,
            'cwd': f'/tmp/{project}',
            'tmux_target': f'codex:{project}.0',
        })
    time.sleep(0.5)  # Give daemon time to register all sessions

    # Storage for permission results returned from each blocking socket call
    results = {}  # session_id → returned value
    result_lock = threading.Lock()

    def fire_permission(session_id, expected_value):
        resp = harness.socket_send({
            'type': 'permission_request',
            'tool': 'Bash',
            'preview': f'git status in {session_id}',
            'options': ['Allow', 'Deny', 'Always Allow'],
            'session_id': session_id,
        }, wait_response=True)
        with result_lock:
            results[session_id] = resp.get('value', '') if resp else ''

    # Start all 3 permission threads simultaneously
    threads = []
    for sid, expected in sessions:
        t = threading.Thread(target=fire_permission, args=(sid, expected), daemon=True)
        threads.append((t, sid, expected))

    for t, _, _ in threads:
        t.start()

    # Wait for confirmation blocks for all 3 sessions to appear
    # The block_id pattern is: codex2-perm-{sanitized_session_id[:16]}-Bash
    def _perm_block_id(session_id: str) -> str:
        import re
        sanitized = re.sub(r'[^a-zA-Z0-9_\-]', '-', session_id[:16])
        return f'codex2-perm-{sanitized}-Bash'

    expected_block_ids = {sid: _perm_block_id(sid) for sid, _ in sessions}

    # Wait for all 3 confirmation blocks
    deadline = time.time() + 8.0
    while time.time() < deadline:
        with harness._lock:
            seen_perm_bids = {
                bid for _, _, bid in harness.captured_blocks
                if 'perm' in bid
            }
        if all(bid in seen_perm_bids for bid in expected_block_ids.values()):
            break
        time.sleep(0.05)

    # Verify all 3 confirmation blocks appeared
    with harness._lock:
        seen_perm_bids = {bid for _, _, bid in harness.captured_blocks if 'perm' in bid}
    missing_blocks = [
        sid for sid, bid in expected_block_ids.items()
        if bid not in seen_perm_bids
    ]
    assert not missing_blocks, (
        f'Permission blocks not emitted for: {missing_blocks}\n'
        f'Seen block ids with perm: {sorted(seen_perm_bids)}'
    )

    # Reply to each permission with its specific value — different for each session
    for sid, expected_value in sessions:
        block_id = expected_block_ids[sid]
        harness.send_notification({
            'type': 'user_response',
            'blockId': block_id,
            'value': expected_value,
        })
        time.sleep(0.05)  # brief gap to avoid stdin interleaving

    # Join all threads
    for t, _, _ in threads:
        t.join(timeout=8.0)

    # Verify each session received the correct response
    for sid, expected_value in sessions:
        actual = results.get(sid, '(not received)')
        assert actual == expected_value, (
            f'Session {sid}: expected value={expected_value!r}, got {actual!r}\n'
            f'All results: {results}'
        )


def test_rapid_tool_fire_clears_permission(harness):
    """A tool_executed arriving while permission is pending resolves it as 'executed'."""
    session_id = 'tmux-codex:ask.0'

    # Register a session
    harness.socket_send({
        'type': 'session_active',
        'session_id': session_id,
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    time.sleep(0.3)

    # Storage for the permission result
    perm_result = {}
    perm_result_event = threading.Event()

    def fire_permission():
        resp = harness.socket_send({
            'type': 'permission_request',
            'tool': 'Bash',
            'preview': 'npm test',
            'options': ['Allow', 'Deny'],
            'session_id': session_id,
        }, wait_response=True)
        perm_result['value'] = resp.get('value', '') if resp else ''
        perm_result_event.set()

    t = threading.Thread(target=fire_permission, daemon=True)
    t.start()

    # Wait for the confirmation block to be emitted
    import re
    sanitized = re.sub(r'[^a-zA-Z0-9_\-]', '-', session_id[:16])
    perm_block_id = f'codex2-perm-{sanitized}-Bash'

    perm_emitted = harness.wait_for_block_id(perm_block_id, timeout=5.0)
    assert perm_emitted, 'Permission confirmation block should be emitted'

    # From a separate thread, immediately send tool_executed for the same tool
    def fire_tool_executed():
        harness.socket_send({
            'type': 'tool_executed',
            'tool_name': 'Bash',
            'session_id': session_id,
        })

    te_thread = threading.Thread(target=fire_tool_executed, daemon=True)
    te_thread.start()
    te_thread.join(timeout=3.0)

    # Wait for the permission future to be resolved by tool_executed
    perm_result_event.wait(timeout=5.0)

    assert perm_result_event.is_set(), \
        'Permission request should be resolved by tool_executed, not still pending'
    actual_value = perm_result.get('value', '')
    assert actual_value == 'executed', (
        f'Permission should resolve to "executed" when tool_executed fires first; '
        f'got {actual_value!r}'
    )

    t.join(timeout=3.0)


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
