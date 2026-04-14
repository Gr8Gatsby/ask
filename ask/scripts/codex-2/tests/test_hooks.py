#!/usr/bin/env python3
"""
Hook subprocess tests for codex-2.

Pattern: start a mock Unix socket server in a thread, run the hook script as a
subprocess with ASK_SOCKET_PATH set and JSON on stdin, then assert exit code
and what the socket received.
"""
import json
import os
import socket as socket_lib
import subprocess
import sys
import tempfile
import threading
import time

import pytest
from typing import Optional

HOOKS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'hooks'
)

PRE_TOOL_USE   = os.path.join(HOOKS_DIR, 'pre_tool_use.py')
SESSION_START  = os.path.join(HOOKS_DIR, 'session_start.py')
POST_TOOL_USE  = os.path.join(HOOKS_DIR, 'post_tool_use.py')
SESSION_STOP   = os.path.join(HOOKS_DIR, 'session_stop.py')


# ── MockSocketServer ──────────────────────────────────────────────────────────

class MockSocketServer:
    """Listens on a Unix socket, captures one message, optionally replies."""

    def __init__(self, socket_path: str, reply=None):
        self._socket_path = socket_path
        self._reply = reply          # bytes or None
        self._received: Optional[dict] = None
        self._event = threading.Event()
        self._server_sock = None
        self._thread = None

    def start(self):
        self._server_sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        self._server_sock.bind(self._socket_path)
        self._server_sock.listen(5)
        self._server_sock.settimeout(5)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def _serve(self):
        try:
            conn, _ = self._server_sock.accept()
        except Exception:
            return
        try:
            chunks = []
            conn.settimeout(5)
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            raw = b''.join(chunks)
            if raw:
                self._received = json.loads(raw.decode())
            if self._reply is not None:
                conn.sendall(self._reply)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass
            self._event.set()

    def wait_for_message(self, timeout=3.0) -> dict:
        self._event.wait(timeout=timeout)
        return self._received

    def close(self):
        try:
            self._server_sock.close()
        except Exception:
            pass
        if os.path.exists(self._socket_path):
            try:
                os.unlink(self._socket_path)
            except Exception:
                pass


# ── Helper: run a hook script ─────────────────────────────────────────────────

def run_hook(script: str, stdin_data: dict, env_overrides: dict = None, timeout=10) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        [sys.executable, script],
        input=json.dumps(stdin_data).encode(),
        capture_output=True,
        env=env,
        timeout=timeout,
    )


# ── pre_tool_use tests ────────────────────────────────────────────────────────

def test_pre_tool_use_allow_response():
    """Server replies Allow → hook exits 0."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'ls -la'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}; stderr: {result.stderr.decode()}'
        assert msg is not None, 'Server should have received a message'
        assert msg.get('type') == 'permission_request'
        assert msg.get('preview') == 'ls -la'


def test_pre_tool_use_deny_response():
    """Server replies Deny → hook exits 2."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Deny'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'rm -rf /'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        server.wait_for_message()
        server.close()

        assert result.returncode == 2, f'Expected 2, got {result.returncode}'


def test_pre_tool_use_daemon_down():
    """No server running → hook exits 0 (allow fallback)."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'echo hello'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        assert result.returncode == 0, f'Expected 0 (allow fallback), got {result.returncode}'


def test_pre_tool_use_exact_allowlist_match():
    """Exact allowlist match → hook exits 0 without connecting to socket."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        allowlist_path = os.path.join(tmp, 'allowlist.json')

        with open(allowlist_path, 'w') as f:
            json.dump({'patterns': ['git status']}, f)

        # No server — if hook connects, it will fail with connection error
        # but since allowlist matches, it should exit 0 without connecting
        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'git status'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': allowlist_path,
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        assert result.returncode == 0, f'Expected 0 (allowlist match), got {result.returncode}'


def test_pre_tool_use_glob_allowlist_match():
    """Glob allowlist pattern matches → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        allowlist_path = os.path.join(tmp, 'allowlist.json')

        with open(allowlist_path, 'w') as f:
            json.dump({'patterns': ['npm run *']}, f)

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'npm run build'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': allowlist_path,
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        assert result.returncode == 0, f'Expected 0 (glob allowlist match), got {result.returncode}'


def test_pre_tool_use_glob_no_match():
    """Glob pattern doesn't match → hook connects to socket."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        allowlist_path = os.path.join(tmp, 'allowlist.json')

        with open(allowlist_path, 'w') as f:
            json.dump({'patterns': ['npm run *']}, f)

        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'pip install requests'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': allowlist_path,
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0
        assert msg is not None, 'Server should receive message (glob did not match)'
        assert msg.get('preview') == 'pip install requests'


def test_pre_tool_use_always_allow_exits_zero():
    """Server replies Always Allow → hook exits 0.

    NOTE: The allowlist write is handled by the daemon (not this hook script).
    The hook simply exits 0 when it receives 'Always Allow'.
    """
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Always Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'git status'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0 for Always Allow, got {result.returncode}'
        assert msg is not None
        assert msg.get('options') == ['Allow', 'Always Allow', 'Deny']


def test_pre_tool_use_preview_truncated_at_500():
    """Command that is 600 chars → socket receives preview of exactly 500 chars."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        long_command = 'x' * 600

        run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': long_command},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        msg = server.wait_for_message()
        server.close()

        assert msg is not None
        assert len(msg.get('preview', '')) == 500, \
            f"Preview should be 500 chars, got {len(msg.get('preview', ''))}"


def test_pre_tool_use_permission_mode_full_auto():
    """permission_mode=full-auto in stdin → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'permission_mode': 'full-auto',
            'tool_input': {'command': 'rm -rf /'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': os.path.join(tmp, 'pmode.json'),
        })

        # Hook should exit 0 immediately without attempting socket connection
        assert result.returncode == 0, f'Expected 0 for full-auto mode, got {result.returncode}'


def test_pre_tool_use_permission_mode_file_full_auto():
    """permission_mode file set to full-auto → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')
        pmode_path = os.path.join(tmp, 'pmode.json')

        with open(pmode_path, 'w') as f:
            json.dump({'mode': 'full-auto'}, f)

        result = run_hook(PRE_TOOL_USE, {
            'tool': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'rm -rf /'},
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
            'ASK_CODEX2_ALLOWLIST_PATH': os.path.join(tmp, 'allowlist.json'),
            'ASK_CODEX2_PERMISSION_MODE_PATH': pmode_path,
        })

        assert result.returncode == 0, f'Expected 0 for full-auto mode file, got {result.returncode}'


# ── session_start tests ───────────────────────────────────────────────────────

def test_session_start_sends_session_active():
    """Hook sends type=session_active with session_id, cwd, tty, tmux_target."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(SESSION_START, {
            'session_id': 'test-session-abc',
            'cwd': '/tmp/myproject',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}; stderr: {result.stderr.decode()}'
        assert msg is not None, 'Server should have received a message'
        assert msg.get('type') == 'session_active'
        assert msg.get('session_id') == 'test-session-abc'
        assert msg.get('cwd') == '/tmp/myproject'
        assert 'tty' in msg
        assert 'tmux_target' in msg


def test_session_start_daemon_down():
    """No server running → hook exits 0 silently."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(SESSION_START, {
            'session_id': 'test-session-abc',
            'cwd': '/tmp/myproject',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'


def test_session_start_empty_session_id():
    """Empty session_id → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(SESSION_START, {
            'session_id': '',
            'cwd': '/tmp/myproject',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'
        # No socket file was created, confirming no connection was attempted


# ── post_tool_use tests ───────────────────────────────────────────────────────

def test_post_tool_use_sends_tool_executed():
    """Hook sends type=tool_executed with session_id, tool_name, last_message."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(POST_TOOL_USE, {
            'session_id': 'sess-42',
            'tool': 'Bash',
            'cwd': '/tmp/proj',
            'last_assistant_message': 'Done running the command.',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}; stderr: {result.stderr.decode()}'
        assert msg is not None, 'Server should have received a message'
        assert msg.get('type') == 'tool_executed'
        assert msg.get('session_id') == 'sess-42'
        assert msg.get('tool_name') == 'Bash'
        assert msg.get('last_message') == 'Done running the command.'


def test_post_tool_use_daemon_down():
    """No server running → hook exits 0 silently."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(POST_TOOL_USE, {
            'session_id': 'sess-42',
            'tool': 'Bash',
            'cwd': '/tmp/proj',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        assert result.returncode == 0, f'Expected 0 (daemon down), got {result.returncode}'


def test_post_tool_use_missing_session_exits_cleanly():
    """Missing session_id → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(POST_TOOL_USE, {
            'session_id': '',
            'tool': 'Bash',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        assert result.returncode == 0


# ── session_stop tests ────────────────────────────────────────────────────────

def test_session_stop_sends_session_active_idle():
    """Hook sends type=session_active with is_working=False."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(SESSION_STOP, {
            'session_id': 'sess-99',
            'cwd': '/tmp/proj',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}; stderr: {result.stderr.decode()}'
        assert msg is not None, 'Server should have received a message'
        assert msg.get('type') == 'session_active'
        assert msg.get('session_id') == 'sess-99'
        assert msg.get('is_working') is False


def test_session_stop_includes_last_message():
    """last_assistant_message in stdin → last_message in socket payload."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(SESSION_STOP, {
            'session_id': 'sess-99',
            'cwd': '/tmp/proj',
            'last_assistant_message': 'Task completed successfully.',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0
        assert msg is not None
        assert msg.get('last_message') == 'Task completed successfully.'


def test_session_stop_empty_session_exits_cleanly():
    """Empty session_id → hook exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(SESSION_STOP, {
            'session_id': '',
            'cwd': '/tmp/proj',
        }, env_overrides={
            'ASK_SOCKET_PATH': sock_path,
        })

        assert result.returncode == 0


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
