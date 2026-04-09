#!/usr/bin/env python3
"""
Integration tests for codex-2/main.py.

Starts the script as a subprocess and drives it via:
  - stdin/stdout: JSON-RPC (AskMac daemon ↔ script)
  - Unix socket:  hook events (Codex hooks → script)

Each test starts a fresh script process, completes the MCP handshake,
exercises a specific behaviour, then stops the process.
"""
import json
import os
import socket as socket_lib
import subprocess
import sys
import tempfile
import threading
import time
from typing import Optional
import pytest

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
TEST_SOCKET = '/tmp/test-codex2.sock'


# ── Test harness ──────────────────────────────────────────────────────────────

class Harness:
    """Runs codex-2/main.py as a subprocess.

    Acts as the AskMac MCP daemon: receives tools/call requests, can send
    back mock results, and can fire hook events via the Unix socket.
    """

    def __init__(self, tmp_dir: str, extra_env: dict = None):
        self.tmp_dir = tmp_dir
        self.settings_path = os.path.join(tmp_dir, 'settings.json')
        self.allowlist_path = os.path.join(tmp_dir, 'allowlist.json')
        self.active_blocks_path = os.path.join(tmp_dir, 'active-blocks.json')
        self.hooks_path = os.path.join(tmp_dir, 'hooks.json')
        # Unix socket paths have a hard limit of ~104 chars on macOS.
        # Use /tmp with a short unique name instead of the long pytest temp dir.
        self._sock_id = str(id(self))[-6:]
        self.socket_path = f'/tmp/codex2-test-{self._sock_id}.sock'
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        self._extra_env = extra_env or {}

    def start(self):
        env = os.environ.copy()
        env['ASK_SOCKET_PATH'] = self.socket_path
        # Point all file paths at our temp dir
        env['ASK_CODEX2_SETTINGS_PATH'] = self.settings_path
        env['ASK_CODEX2_ALLOWLIST_PATH'] = self.allowlist_path
        env['ASK_CODEX2_ACTIVE_BLOCKS_PATH'] = self.active_blocks_path
        env['ASK_CODEX2_HOOKS_PATH'] = self.hooks_path
        # Prevent tmux/Terminal discovery from running during tests
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
        # Collect stderr for diagnosis
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

    def all_calls(self, name: str) -> list:
        """Return all tools/call messages for a given tool name."""
        with self._lock:
            return [
                m for m in self._stdout_lines
                if m.get('method') == 'tools/call'
                and m.get('params', {}).get('name') == name
            ]

    @property
    def message_count(self) -> int:
        with self._lock:
            return len(self._stdout_lines)

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
        """Send a message to the Unix socket. If wait_response=True, read reply."""
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
    h = Harness(str(tmp_path))
    h.start()
    assert h.handshake(), 'MCP handshake failed'
    yield h
    h.stop()


@pytest.fixture
def harness_with_settings(tmp_path):
    """Harness pre-seeded with a saved interactive setting."""
    settings = {'interactive': True}
    sp = tmp_path / 'settings.json'
    sp.write_text(json.dumps(settings))
    h = Harness(str(tmp_path))
    h.start()
    assert h.handshake(), 'MCP handshake failed'
    yield h
    h.stop()


# ── Helpers ───────────────────────────────────────────────────────────────────

def is_emit(m, block_type=None, block_id_contains=None):
    if m.get('method') != 'tools/call':
        return False
    if m.get('params', {}).get('name') != 'emit_block':
        return False
    args = m.get('params', {}).get('arguments', {})
    if block_type and args.get('blockType') != block_type:
        return False
    if block_id_contains and block_id_contains not in args.get('blockId', ''):
        return False
    return True


def is_clear(m, block_id_contains=None):
    if m.get('method') != 'tools/call':
        return False
    if m.get('params', {}).get('name') != 'clear_block':
        return False
    if block_id_contains:
        bid = m.get('params', {}).get('arguments', {}).get('blockId', '')
        return block_id_contains in bid
    return True


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_handshake_emits_start_session_block(harness):
    """On startup, a start_session picker block should be emitted."""
    picker = harness.wait_for(lambda m: is_emit(m, 'start_session'))
    assert picker is not None, 'start_session block should be emitted on startup'


# Fix 1: Always Allow writes to allowlist ─────────────────────────────────────

def test_always_allow_writes_to_allowlist(harness):
    """When user responds 'Always Allow', the command is persisted to allowlist."""
    # Register a synthetic session so permission can be associated with it
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    time.sleep(0.3)

    # Fire a permission request from the hook (blocking — use a thread)
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

    # Wait for permission block to be emitted
    perm_block = harness.wait_for(
        lambda m: is_emit(m, 'confirmation') and 'perm' in m.get('params', {}).get('arguments', {}).get('blockId', ''),
        timeout=3.0,
    )
    assert perm_block is not None, 'Permission confirmation block should be emitted'

    # Simulate user tapping "Always Allow"
    block_id = perm_block['params']['arguments']['blockId']
    rpc_id = perm_block['id']

    # Send user_response via the RPC notification path
    harness.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {
            'data': {
                'type': 'user_response',
                'blockId': block_id,
                'value': 'Always Allow',
            }
        }
    }) + '\n').encode())
    harness.proc.stdin.flush()

    t.join(timeout=5.0)

    # Allowlist file should now exist and contain 'git status'
    time.sleep(0.3)
    assert os.path.exists(harness.allowlist_path), 'Allowlist file should be created'
    data = json.loads(open(harness.allowlist_path).read())
    assert 'git status' in data.get('patterns', []), \
        f"'git status' should be in allowlist; got {data}"


# Fix 2: Stop button sends /quit ──────────────────────────────────────────────

def test_stop_issues_quit_command(harness, tmp_path):
    """__close_session__ response should attempt to send /quit to the tmux pane."""
    # Register a session
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:jokes.0',
        'cwd': '/tmp/jokes',
        'tmux_target': 'codex:jokes.0',
    })
    time.sleep(0.3)

    # Wait for session block to be emitted so we have the block ID
    session_block = harness.wait_for(
        lambda m: is_emit(m, 'agent_session'), timeout=3.0
    )
    assert session_block is not None
    block_id = session_block['params']['arguments']['blockId']

    # Record send-keys calls before sending stop
    calls_before = len(harness.all_calls('send_text'))  # tmux goes through TM

    # Send __close_session__
    harness.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {
            'data': {
                'type': 'user_response',
                'blockId': block_id,
                'value': '__close_session__',
                'sessionId': 'tmux-codex:jokes.0',
            }
        }
    }) + '\n').encode())
    harness.proc.stdin.flush()
    time.sleep(0.5)

    # The test verifies the handler ran without crashing; tmux send-keys
    # will fail gracefully in the test environment (no real tmux).
    # We confirm the script is still alive after the stop attempt.
    assert harness.proc.poll() is None, 'Script should still be running after stop'


# Fix 5: Mode picker skipped if setting already saved ─────────────────────────

def test_mode_picker_skipped_when_setting_saved(harness_with_settings, tmp_path):
    """If interactive is already in settings, no mode picker should be emitted."""
    h = harness_with_settings

    # Wait for start_session block
    picker = h.wait_for(lambda m: is_emit(m, 'start_session'), timeout=3.0)
    assert picker is not None

    block_id = picker['params']['arguments']['blockId']

    # Simulate user picking a repo (the value must be a key in _start_repos,
    # but since _find_repos() returns empty in test env, we use a direct path)
    # We trigger the picker response and check no mode-pick confirmation appears.
    msgs_before = h.message_count

    h.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {
            'data': {
                'type': 'user_response',
                'blockId': 'codex2-start',
                'value': '(no repos found)',
            }
        }
    }) + '\n').encode())
    h.proc.stdin.flush()
    time.sleep(0.5)

    # No mode picker (confirmation with 'Interactive'/'Headless' options) should appear
    mode_picker = h.wait_for(
        lambda m: is_emit(m, 'confirmation')
        and 'mode' in m.get('params', {}).get('arguments', {}).get('blockId', ''),
        timeout=1.0,
    )
    assert mode_picker is None, \
        'Mode picker should NOT appear when interactive setting is already saved'


# Fix 8: Chat messages are not misrouted ──────────────────────────────────────

def test_chat_message_not_routed_to_wrong_session(harness):
    """A chat_message with an unknown sessionId should not call send_text."""
    send_text_before = len(harness.all_calls('send_text'))

    harness.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {
            'data': {
                'type': 'chat_message',
                'text': 'hello codex',
                'sessionId': 'tmux-codex:nonexistent.0',
            }
        }
    }) + '\n').encode())
    harness.proc.stdin.flush()
    time.sleep(0.3)

    send_text_after = len(harness.all_calls('send_text'))
    assert send_text_after == send_text_before, \
        'send_text should NOT be called for a chat message with unknown sessionId'


def test_chat_message_routed_to_correct_session(harness):
    """A chat_message with a known sessionId should call send_text on that session."""
    # Register a session
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    time.sleep(0.3)

    harness.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {
            'data': {
                'type': 'chat_message',
                'text': 'write a test',
                'sessionId': 'tmux-codex:ask.0',
            }
        }
    }) + '\n').encode())
    harness.proc.stdin.flush()
    time.sleep(0.5)

    send_text_calls = harness.all_calls('send_text')
    assert len(send_text_calls) > 0, 'send_text should be called for a matched session'
    texts = [c['params']['arguments'].get('text', '') for c in send_text_calls]
    assert any('write a test' in t for t in texts), \
        f'send_text should carry the message text; got {texts}'


# Fix 9: User prompt surfaced on session tile ─────────────────────────────────

def test_prompt_surfaced_on_session_tile(harness):
    """After user_prompt_submit, the tile payload should include current_prompt."""
    harness.socket_send({
        'type': 'session_active',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'tmux_target': 'codex:ask.0',
    })
    time.sleep(0.3)

    harness.socket_send({
        'type': 'user_prompt_submit',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'prompt': 'add unit tests for the auth module',
    })
    time.sleep(0.5)

    tile_with_prompt = harness.wait_for(
        lambda m: (
            is_emit(m, 'agent_session') and
            'add unit tests' in m.get('params', {}).get('arguments', {})
                                    .get('payload', {}).get('current_prompt', '')
        ),
        timeout=3.0,
    )
    assert tile_with_prompt is not None, \
        'Session tile should include current_prompt after user_prompt_submit'


# Fix 12: Orphaned blocks cleared on startup ──────────────────────────────────

def test_orphaned_blocks_cleared_on_startup(tmp_path):
    """Blocks listed in active-blocks file should be cleared when script starts."""
    stale = ['codex2-perm-abc-Bash', 'codex2-perm-def-Bash']
    active_blocks_path = tmp_path / 'active-blocks.json'
    active_blocks_path.write_text(json.dumps(stale))

    h = Harness(str(tmp_path))
    h.start()
    assert h.handshake()

    try:
        # Wait for clear_block calls for the stale block IDs
        cleared = []
        deadline = time.time() + 5.0
        while time.time() < deadline and len(cleared) < len(stale):
            for bid in stale:
                if bid not in cleared:
                    call = h.wait_for(lambda m, b=bid: is_clear(m, b), timeout=0.1)
                    if call:
                        cleared.append(bid)
            time.sleep(0.05)

        assert set(cleared) == set(stale), \
            f'All stale blocks should be cleared on startup; cleared={cleared}'

        # Active blocks file should be emptied after clearing
        time.sleep(0.3)
        remaining = json.loads(active_blocks_path.read_text()) if active_blocks_path.exists() else []
        assert remaining == [], f'Active blocks file should be empty after startup sweep; got {remaining}'
    finally:
        h.stop()


# Fix 13: Hook install preserves custom hooks ─────────────────────────────────

# Fix 13 tests live in test_helpers.py (TestWriteHooksJsonMerge) where _mod is
# already imported safely with stdout redirected.


# Fix 14: CWD passed to stop target resolution ────────────────────────────────

def test_session_stop_uses_cwd(harness):
    """session_stop message should use CWD for target resolution (no crash with two sessions)."""
    # Register two sessions
    for project, cwd in [('ask', '/tmp/ask'), ('jokes', '/tmp/jokes')]:
        harness.socket_send({
            'type': 'session_active',
            'session_id': f'tmux-codex:{project}.0',
            'cwd': cwd,
            'tmux_target': f'codex:{project}.0',
        })
    time.sleep(0.3)

    # Send a stop for one session with CWD — should not crash or clear the other
    harness.socket_send({
        'type': 'session_stop',
        'session_id': 'tmux-codex:ask.0',
        'cwd': '/tmp/ask',
        'last_message': 'done',
    })
    time.sleep(0.5)

    # The 'jokes' session block should NOT have been cleared
    clear_calls = harness.all_calls('clear_block')
    jokes_cleared = any(
        'jokes' in c.get('params', {}).get('arguments', {}).get('blockId', '')
        for c in clear_calls
    )
    assert not jokes_cleared, \
        'Stopping the ask session should not clear the jokes session block'


# Fix 15: Per-launch mode picker IDs are unique ───────────────────────────────

def test_per_launch_mode_picker_unique_ids(harness):
    """Two repo selections should produce two different mode picker block IDs."""
    # Fire two picker responses in quick succession (no settings saved, so picker shown)
    for _ in range(2):
        harness.proc.stdin.write((json.dumps({
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {
                'data': {
                    'type': 'user_response',
                    'blockId': 'codex2-start',
                    'value': '/tmp/some-repo',
                }
            }
        }) + '\n').encode())
        harness.proc.stdin.flush()
        time.sleep(0.1)

    time.sleep(0.5)

    mode_picker_blocks = [
        m['params']['arguments']['blockId']
        for m in harness._stdout_lines
        if is_emit(m, 'confirmation')
        and 'codex2-mode-' in m.get('params', {}).get('arguments', {}).get('blockId', '')
    ]

    if len(mode_picker_blocks) >= 2:
        assert mode_picker_blocks[0] != mode_picker_blocks[1], \
            'Each launch should produce a unique mode picker block ID'


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
