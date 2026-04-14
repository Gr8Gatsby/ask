#!/usr/bin/env python3
"""
Layer 2: Payload Schema Validation tests for codex-2.

Intercepts every emit_block call the daemon makes and validates the payload
against the iOS block schemas defined in payload_schemas.py.
"""
import json
import os
import sys
import tempfile
import threading
import time
import subprocess
import socket as socket_lib
from typing import Optional

import pytest

# ── Import shared schema module ───────────────────────────────────────────────
sys.path.insert(0, os.path.dirname(__file__))
from payload_schemas import validate_payload, SCHEMAS

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')


# ── Instrumented Harness ──────────────────────────────────────────────────────

class InstrumentedHarness:
    """Harness that captures every emit_block call and validates its payload.

    Extends the base Harness pattern with:
      - captured_blocks: list of (block_type, payload_dict, block_id) tuples
        for every emit_block tools/call received
      - schema_errors: list of AssertionError messages from failed validations
    """

    def __init__(self, tmp_dir: str, extra_env: dict = None):
        self.tmp_dir = tmp_dir
        self.settings_path = os.path.join(tmp_dir, 'settings.json')
        self.allowlist_path = os.path.join(tmp_dir, 'allowlist.json')
        self.active_blocks_path = os.path.join(tmp_dir, 'active-blocks.json')
        self.hooks_path = os.path.join(tmp_dir, 'hooks.json')
        self.sessions_path = os.path.join(tmp_dir, 'sessions.json')
        self._sock_id = str(id(self))[-6:]
        self.socket_path = f'/tmp/codex2-schema-{self._sock_id}.sock'
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        self._extra_env = extra_env or {}

        # Layer 2 additions:
        self.captured_blocks: list = []   # (block_type, payload_dict, block_id)
        self.schema_errors: list = []     # AssertionError messages

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
                    # Intercept emit_block calls and capture + validate
                    if (msg.get('method') == 'tools/call'
                            and msg.get('params', {}).get('name') == 'emit_block'):
                        args = msg['params']['arguments']
                        block_type = args.get('blockType', '')
                        payload = args.get('payload', {})
                        block_id = args.get('blockId', '')
                        self.captured_blocks.append((block_type, payload, block_id))
                        # Validate against schema if one exists
                        if block_type in SCHEMAS:
                            try:
                                validate_payload(block_type, payload)
                            except AssertionError as e:
                                self.schema_errors.append(str(e))
                # Auto-respond to any tools/call that has an id
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

    def wait_for(self, predicate, timeout=3.0) -> Optional[dict]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for msg in self._stdout_lines:
                    if predicate(msg):
                        return msg
            time.sleep(0.05)
        return None

    def wait_for_block_type(self, block_type: str, timeout=5.0):
        """Wait until at least one captured_blocks entry has the given block_type."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for bt, payload, bid in self.captured_blocks:
                    if bt == block_type:
                        return (bt, payload, bid)
            time.sleep(0.05)
        return None

    def captured_by_type(self, block_type: str) -> list:
        """Return all captured (block_type, payload, block_id) for the given type."""
        with self._lock:
            return [(bt, p, bid) for bt, p, bid in self.captured_blocks if bt == block_type]

    def all_calls(self, name: str) -> list:
        with self._lock:
            return [
                m for m in self._stdout_lines
                if m.get('method') == 'tools/call'
                and m.get('params', {}).get('name') == name
            ]

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
        # Wait for the initial tile/start_session emit to confirm script is up
        tile = self.wait_for(
            lambda m: m.get('method') == 'tools/call'
            and m.get('params', {}).get('name') == 'emit_block',
            timeout=5.0,
        )
        return tile is not None

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

    def send_notification(self, data: dict):
        """Send a notifications/message to stdin."""
        self.proc.stdin.write((json.dumps({
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {'data': data},
        }) + '\n').encode())
        self.proc.stdin.flush()

    def stop(self):
        if self.proc:
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
    h = InstrumentedHarness(str(tmp_path))
    h.start()
    assert h.handshake(), 'MCP handshake failed'
    yield h
    h.stop()


# ── Schema validation assertion helper ───────────────────────────────────────

def assert_no_schema_errors(harness: InstrumentedHarness):
    """Fail the test if any schema violations were recorded."""
    if harness.schema_errors:
        raise AssertionError(
            f'{len(harness.schema_errors)} schema error(s):\n' +
            '\n'.join(f'  - {e}' for e in harness.schema_errors)
        )


# ── Layer 2 Tests ─────────────────────────────────────────────────────────────

def test_tile_payload_valid(harness):
    """The initial 'tile' block emitted at startup has a valid payload."""
    entry = harness.wait_for_block_type('tile', timeout=5.0)
    assert entry is not None, 'Expected a tile block to be emitted on startup'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)
    assert_no_schema_errors(harness)


def test_start_session_payload_valid(harness):
    """The 'start_session' block emitted at startup has a valid payload."""
    entry = harness.wait_for_block_type('start_session', timeout=5.0)
    assert entry is not None, 'Expected a start_session block to be emitted on startup'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)
    # repos must be a list
    assert isinstance(payload['repos'], list), \
        f"'repos' should be a list; got {type(payload['repos'])}"
    assert_no_schema_errors(harness)


def test_agent_session_payload_valid(harness):
    """The 'agent_session' block emitted on session_active has a valid payload."""
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    entry = harness.wait_for_block_type('agent_session', timeout=5.0)
    assert entry is not None, 'Expected an agent_session block after session_active'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)
    assert payload['session_id'], "agent_session.session_id must be non-empty"
    assert payload['project'], "agent_session.project must be non-empty"
    assert_no_schema_errors(harness)


def test_confirmation_payload_valid(harness):
    """The 'confirmation' block emitted on permission_request has a valid payload."""
    # Register a session first so the permission can be associated with it
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    time.sleep(0.3)

    result_holder = {}

    def fire_permission():
        result_holder['response'] = harness.socket_send({
            'type': 'permission_request',
            'tool': 'Bash',
            'preview': 'git status',
            'options': ['Allow', 'Always Allow', 'Deny'],
            'session_id': 'tmux-codex:ask.0',
        }, wait_response=True)

    t = threading.Thread(target=fire_permission, daemon=True)
    t.start()

    # Wait for the confirmation block to appear
    entry = None
    deadline = time.time() + 5.0
    while time.time() < deadline:
        with harness._lock:
            for bt, payload, bid in harness.captured_blocks:
                if bt == 'confirmation' and 'perm' in bid:
                    entry = (bt, payload, bid)
                    break
        if entry:
            break
        time.sleep(0.05)

    assert entry is not None, 'Expected a confirmation block for permission_request'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)
    assert isinstance(payload['options'], list), "confirmation.options must be a list"
    assert len(payload['options']) > 0, "confirmation.options must not be empty"

    # Resolve the permission so the background thread can exit
    harness.send_notification({
        'type': 'user_response',
        'blockId': block_id,
        'value': 'Deny',
    })
    t.join(timeout=5.0)
    assert_no_schema_errors(harness)


def test_alert_payload_valid(harness):
    """The 'alert' block emitted on notification has a valid payload."""
    harness.socket_send({
        'type': 'notification',
        'title': 'Test Alert',
        'body': 'Something happened',
    })
    entry = harness.wait_for_block_type('alert', timeout=5.0)
    assert entry is not None, 'Expected an alert block after notification'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)
    assert_no_schema_errors(harness)


def test_info_card_payload_valid(harness):
    """The 'info_card' block emitted on __view_log__ uses 'pairs', not 'body'."""
    # Register a session
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    # Wait for agent_session block so we have a block_id with the session prefix
    agent_entry = harness.wait_for_block_type('agent_session', timeout=5.0)
    assert agent_entry is not None, 'Expected agent_session block first'
    _, _, session_block_id = agent_entry

    # Send __view_log__ response — the daemon will try tmux capture (will fail
    # gracefully in the test env) and still emit an info_card
    harness.send_notification({
        'type': 'user_response',
        'blockId': session_block_id,
        'value': '__view_log__',
    })

    # Wait for info_card block
    entry = None
    deadline = time.time() + 5.0
    while time.time() < deadline:
        with harness._lock:
            for bt, payload, bid in harness.captured_blocks:
                if bt == 'info_card':
                    entry = (bt, payload, bid)
                    break
        if entry:
            break
        time.sleep(0.05)

    assert entry is not None, 'Expected an info_card block after __view_log__'
    block_type, payload, block_id = entry
    validate_payload(block_type, payload)

    # Specifically verify 'pairs' is present (not 'body') — this is the
    # schema difference between info_card and alert
    assert 'pairs' in payload, \
        f"info_card payload must have 'pairs', not 'body'; got keys: {list(payload.keys())}"
    assert 'body' not in payload, \
        f"info_card should not have 'body' field; use 'pairs' instead"
    assert isinstance(payload['pairs'], list), \
        f"info_card.pairs must be a list; got {type(payload['pairs'])}"
    assert_no_schema_errors(harness)


def test_all_startup_blocks_pass_schema_validation(harness):
    """All blocks emitted during startup are schema-valid."""
    # Give daemon time to emit all startup blocks
    time.sleep(1.0)
    assert_no_schema_errors(harness)
    # Confirm we saw at least tile and start_session
    with harness._lock:
        types_seen = {bt for bt, _, _ in harness.captured_blocks}
    assert 'tile' in types_seen, 'Expected tile block at startup'
    assert 'start_session' in types_seen, 'Expected start_session block at startup'


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
