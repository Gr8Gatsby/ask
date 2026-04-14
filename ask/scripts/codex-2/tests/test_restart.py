#!/usr/bin/env python3
"""
Layer 4: Daemon Restart End-to-End tests for codex-2.

Tests the full crash-restart flow: sessions persisted to disk survive a SIGKILL
and are restored when a new daemon instance starts.

Session persistence uses the ASK_CODEX2_SESSIONS_PATH env var so tests write to
a temp file rather than the production path.
"""
import json
import os
import sys
import socket as socket_lib
import subprocess
import threading
import time
import datetime
from typing import Optional

import pytest

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
# SESSION_TTL from main.py — 300 seconds
SESSION_TTL = 300


# ── Restart-capable Harness ───────────────────────────────────────────────────

class RestartHarness:
    """Harness with shared file paths across restart cycles.

    All file paths (sessions, settings, etc.) are shared so the second daemon
    instance picks up state written by the first.

    Also captures all emit_block calls so tests can assert on block content.
    """

    def __init__(self, tmp_dir: str, socket_path: str, extra_env: dict = None):
        self.tmp_dir = tmp_dir
        self.settings_path = os.path.join(tmp_dir, 'settings.json')
        self.allowlist_path = os.path.join(tmp_dir, 'allowlist.json')
        self.active_blocks_path = os.path.join(tmp_dir, 'active-blocks.json')
        self.hooks_path = os.path.join(tmp_dir, 'hooks.json')
        self.sessions_path = os.path.join(tmp_dir, 'sessions.json')
        self.socket_path = socket_path
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        self._extra_env = extra_env or {}
        self.captured_blocks: list = []  # (block_type, payload, block_id)

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
                        self.captured_blocks.append((
                            args.get('blockType', ''),
                            args.get('payload', {}),
                            args.get('blockId', ''),
                        ))
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
        sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        sock.settimeout(5)
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

    def wait_for_agent_session(self, session_id_contains: str = '', timeout=5.0):
        """Wait for an agent_session captured block matching session_id_contains."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for bt, payload, bid in self.captured_blocks:
                    if bt == 'agent_session':
                        if not session_id_contains or session_id_contains in payload.get('session_id', ''):
                            return (bt, payload, bid)
            time.sleep(0.05)
        return None

    def kill(self):
        """Kill the daemon with SIGKILL (simulates crash)."""
        if self.proc:
            self.proc.kill()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass

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


def _make_socket_path(tmp_dir: str) -> str:
    """Create a short /tmp-based socket path (macOS has 104-char limit)."""
    uid = str(abs(hash(tmp_dir)))[-6:]
    return f'/tmp/codex2-restart-{uid}.sock'


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_restart_restores_session(tmp_path):
    """After a SIGKILL, a new daemon instance restores the previous session."""
    socket_path = _make_socket_path(str(tmp_path))
    session_id = 'tmux-codex:ask.0'

    # ── First daemon instance ──────────────────────────────────────────────────
    h1 = RestartHarness(str(tmp_path), socket_path)
    h1.start()
    assert h1.handshake(), 'First daemon MCP handshake failed'

    # Register a session
    h1.socket_send({
        'type': 'session_active',
        'session_id': session_id,
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })

    # Confirm daemon emitted an agent_session block for it
    entry = h1.wait_for_agent_session('ask', timeout=5.0)
    assert entry is not None, 'First daemon should emit agent_session block'

    # Kill with SIGKILL (simulate crash, not clean shutdown)
    h1.kill()

    # Remove the stale socket file so the second daemon can bind
    if os.path.exists(socket_path):
        os.unlink(socket_path)

    # ── Second daemon instance ────────────────────────────────────────────────
    h2 = RestartHarness(str(tmp_path), socket_path)
    h2.start()
    assert h2.handshake(), 'Second daemon MCP handshake failed'

    # The second daemon should restore the session from sessions.json and
    # emit an agent_session block for it within 5 seconds
    restored = h2.wait_for_agent_session('ask', timeout=7.0)
    assert restored is not None, (
        'Second daemon should restore and emit agent_session for the previous session'
    )

    h2.stop()


def test_restart_expired_session_not_restored(tmp_path):
    """A session with last_seen older than SESSION_TTL is not restored on restart."""
    socket_path = _make_socket_path(str(tmp_path))

    # Write a sessions.json with a stale last_seen timestamp
    stale_time = datetime.datetime.now().timestamp() - (SESSION_TTL + 60)
    sessions = {
        'tmux-codex:old.0': {
            'cwd': '/tmp/old',
            'tty': '',
            'tmux_target': 'codex:old.0',
            'pid': 0,
            'is_working': False,
            'is_headless': True,
            'last_seen': stale_time,
        }
    }
    sessions_path = os.path.join(str(tmp_path), 'sessions.json')
    with open(sessions_path, 'w') as f:
        json.dump(sessions, f)

    h = RestartHarness(str(tmp_path), socket_path)
    h.start()
    assert h.handshake(), 'MCP handshake failed'

    # Give daemon time to process startup (restore sessions + emit blocks)
    time.sleep(1.5)

    # No agent_session block should be emitted for the stale session
    with h._lock:
        agent_sessions = [
            (bt, p, bid) for bt, p, bid in h.captured_blocks
            if bt == 'agent_session' and 'old' in p.get('session_id', '')
        ]
    assert len(agent_sessions) == 0, (
        f'Stale session (last_seen > SESSION_TTL) should NOT be restored; '
        f'got: {agent_sessions}'
    )

    h.stop()


def test_restart_multiple_sessions(tmp_path):
    """All 3 active sessions are restored after a daemon restart."""
    socket_path = _make_socket_path(str(tmp_path))

    session_ids = [
        ('tmux-codex:alpha.0', '/tmp/alpha', 'codex:alpha.0'),
        ('tmux-codex:beta.0', '/tmp/beta', 'codex:beta.0'),
        ('tmux-codex:gamma.0', '/tmp/gamma', 'codex:gamma.0'),
    ]

    # ── First daemon ──────────────────────────────────────────────────────────
    h1 = RestartHarness(str(tmp_path), socket_path)
    h1.start()
    assert h1.handshake(), 'First daemon MCP handshake failed'

    for sid, cwd, target in session_ids:
        h1.socket_send({
            'type': 'session_active',
            'session_id': sid,
            'cwd': cwd,
            'tmux_target': target,
        })

    # Wait for all 3 agent_session blocks to be emitted
    deadline = time.time() + 7.0
    while time.time() < deadline:
        with h1._lock:
            seen = {
                p.get('session_id', '')
                for bt, p, bid in h1.captured_blocks
                if bt == 'agent_session'
            }
        if all(sid in seen for sid, _, _ in session_ids):
            break
        time.sleep(0.1)

    h1.kill()
    if os.path.exists(socket_path):
        os.unlink(socket_path)

    # ── Second daemon ──────────────────────────────────────────────────────────
    h2 = RestartHarness(str(tmp_path), socket_path)
    h2.start()
    assert h2.handshake(), 'Second daemon MCP handshake failed'

    # Wait for all 3 sessions to be re-emitted
    deadline = time.time() + 10.0
    while time.time() < deadline:
        with h2._lock:
            restored = {
                p.get('session_id', '')
                for bt, p, bid in h2.captured_blocks
                if bt == 'agent_session'
            }
        if all(sid in restored for sid, _, _ in session_ids):
            break
        time.sleep(0.1)

    with h2._lock:
        restored = {
            p.get('session_id', '')
            for bt, p, bid in h2.captured_blocks
            if bt == 'agent_session'
        }
    missing = [sid for sid, _, _ in session_ids if sid not in restored]
    assert not missing, (
        f'After restart, these sessions were not restored: {missing}\n'
        f'Restored: {sorted(restored)}'
    )

    h2.stop()


def test_restart_preserves_last_message(tmp_path):
    """A session's last_message is preserved across a daemon restart."""
    socket_path = _make_socket_path(str(tmp_path))
    session_id = 'tmux-codex:ask.0'
    last_msg = 'Build complete: 42 tests passed'

    # ── First daemon ──────────────────────────────────────────────────────────
    h1 = RestartHarness(str(tmp_path), socket_path)
    h1.start()
    assert h1.handshake(), 'First daemon MCP handshake failed'

    # Register session with a last_message
    h1.socket_send({
        'type': 'session_active',
        'session_id': session_id,
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
        'last_message': last_msg,
    })

    # Confirm agent_session was emitted
    entry = h1.wait_for_agent_session('ask', timeout=5.0)
    assert entry is not None, 'First daemon should emit agent_session'

    # Give session data a moment to be saved to disk
    time.sleep(0.3)

    h1.kill()
    if os.path.exists(socket_path):
        os.unlink(socket_path)

    # ── Second daemon ──────────────────────────────────────────────────────────
    h2 = RestartHarness(str(tmp_path), socket_path)
    h2.start()
    assert h2.handshake(), 'Second daemon MCP handshake failed'

    # Wait for the session's agent_session block with last_message
    restored_with_msg = None
    deadline = time.time() + 7.0
    while time.time() < deadline:
        with h2._lock:
            for bt, payload, bid in h2.captured_blocks:
                if (bt == 'agent_session'
                        and 'ask' in payload.get('session_id', '')
                        and payload.get('last_message') == last_msg):
                    restored_with_msg = (bt, payload, bid)
                    break
        if restored_with_msg:
            break
        time.sleep(0.05)

    assert restored_with_msg is not None, (
        f'After restart, agent_session block should include last_message={last_msg!r}; '
        f'captured: {[(bt, p.get("last_message"), p.get("session_id")) for bt, p, _ in h2.captured_blocks if bt == "agent_session"]}'
    )

    h2.stop()


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
