#!/usr/bin/env python3
"""
Hook subprocess tests for claudecode-controller.

Pattern: start a mock Unix socket server in a thread, run the hook script as a
subprocess with ASK_SOCKET_PATH set and JSON on stdin, assert exit code, socket
message received, and stdout (for permission_request.py which writes a JSON
decision to stdout).
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

PERMISSION_REQUEST = os.path.join(HOOKS_DIR, 'permission_request.py')
PRE_TOOL_USE       = os.path.join(HOOKS_DIR, 'pre_tool_use.py')
SESSION_START      = os.path.join(HOOKS_DIR, 'session_start.py')


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


# ── Helper ────────────────────────────────────────────────────────────────────

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


def _parse_stdout_decision(result: subprocess.CompletedProcess) -> Optional[dict]:
    """Parse the hookSpecificOutput JSON from hook stdout."""
    out = result.stdout.decode().strip()
    if not out:
        return None
    return json.loads(out)


# ── permission_request tests ──────────────────────────────────────────────────

def test_permission_no_suggestions_options():
    """No permission_suggestions → options are ['Yes', 'No']."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Yes'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'ls'},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert msg is not None
        assert msg.get('options') == ['Yes', 'No'], \
            f"Expected ['Yes', 'No'], got {msg.get('options')}"


def test_permission_with_suggestions_options():
    """With one allow suggestion → options include 'Allow', always-allow label, 'Deny'."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Read',
            'session_id': 'sess-1',
            'tool_input': {'file_path': '~/path/to/file.txt'},
            'permission_suggestions': [{
                'behavior': 'allow',
                'rules': [{'toolName': 'Read', 'ruleContent': '~/path'}],
            }],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert msg is not None
        options = msg.get('options', [])
        assert options[0] == 'Allow', f'First option should be Allow, got {options}'
        assert options[-1] == 'Deny', f'Last option should be Deny, got {options}'
        assert any('Always allow' in o for o in options), \
            f'Expected an always-allow label in options; got {options}'


def test_permission_allow_decision():
    """Server replies Allow → stdout decision has behavior=allow, exits 0."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'echo hi'},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'
        parsed = _parse_stdout_decision(result)
        assert parsed is not None, 'Expected JSON on stdout'
        decision = parsed['hookSpecificOutput']['decision']
        assert decision['behavior'] == 'allow'


def test_permission_deny_decision():
    """Server replies Deny → stdout decision has behavior=deny, exits 2."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Deny'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'rm -rf /'},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        server.wait_for_message()
        server.close()

        assert result.returncode == 2, f'Expected 2, got {result.returncode}'
        parsed = _parse_stdout_decision(result)
        assert parsed is not None, 'Expected JSON on stdout'
        decision = parsed['hookSpecificOutput']['decision']
        assert decision['behavior'] == 'deny'
        assert 'message' in decision


def test_permission_yes_decision():
    """Server replies Yes → stdout decision has behavior=allow, exits 0."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Yes'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'ls'},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        server.wait_for_message()
        server.close()

        assert result.returncode == 0
        parsed = _parse_stdout_decision(result)
        assert parsed is not None
        assert parsed['hookSpecificOutput']['decision']['behavior'] == 'allow'


def test_permission_always_allow_with_suggestion():
    """Reply matching a suggestion label → decision has behavior=allow with updatedPermissions."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')

        suggestion = {
            'behavior': 'allow',
            'rules': [{'toolName': 'Read', 'ruleContent': '~/path'}],
        }
        # The label that will be constructed by the hook
        label = 'Always allow Read(~/path)'
        reply = json.dumps({'value': label}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        result = run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Read',
            'session_id': 'sess-1',
            'tool_input': {'file_path': '~/path/to/file.txt'},
            'permission_suggestions': [suggestion],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'
        parsed = _parse_stdout_decision(result)
        assert parsed is not None
        decision = parsed['hookSpecificOutput']['decision']
        assert decision['behavior'] == 'allow'
        assert 'updatedPermissions' in decision, \
            f'Expected updatedPermissions in decision; got {decision}'


def test_permission_daemon_down():
    """Daemon not running → exits 0, stdout is empty (fallback to console prompt)."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': 'ls'},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        assert result.returncode == 0, f'Expected 0 (daemon down fallback), got {result.returncode}'
        out = result.stdout.decode().strip()
        assert out == '', f'Expected empty stdout when daemon down, got: {out!r}'


def test_permission_preview_truncated_at_500():
    """600-char command → socket message preview is exactly 500 chars."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        reply = json.dumps({'value': 'Allow'}).encode()
        server = MockSocketServer(sock_path, reply=reply).start()

        long_command = 'z' * 600

        run_hook(PERMISSION_REQUEST, {
            'tool_name': 'Bash',
            'session_id': 'sess-1',
            'tool_input': {'command': long_command},
            'permission_suggestions': [],
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert msg is not None
        assert len(msg.get('preview', '')) == 500, \
            f"Preview should be 500 chars, got {len(msg.get('preview', ''))}"


# ── pre_tool_use tests ────────────────────────────────────────────────────────

def test_claudecode_pre_tool_use_bash():
    """Bash tool → socket message has preview from command, exits 0."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(PRE_TOOL_USE, {
            'session_id': 'sess-1',
            'tool_name': 'Bash',
            'tool_input': {'command': 'git log --oneline'},
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'
        assert msg is not None, 'Server should have received a message'
        assert msg.get('type') == 'pre_tool_use'
        assert msg.get('preview') == 'git log --oneline'
        assert msg.get('tool') == 'Bash'
        assert msg.get('session_id') == 'sess-1'


def test_claudecode_pre_tool_use_bash_truncated():
    """600-char command → preview is 500 chars."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        long_command = 'a' * 600

        run_hook(PRE_TOOL_USE, {
            'session_id': 'sess-1',
            'tool_name': 'Bash',
            'tool_input': {'command': long_command},
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert msg is not None
        assert len(msg.get('preview', '')) == 500, \
            f"Preview should be 500 chars, got {len(msg.get('preview', ''))}"


def test_claudecode_pre_tool_use_daemon_down():
    """Daemon not running → exits 0 silently."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(PRE_TOOL_USE, {
            'session_id': 'sess-1',
            'tool_name': 'Bash',
            'tool_input': {'command': 'ls'},
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        assert result.returncode == 0, f'Expected 0 (daemon down), got {result.returncode}'


def test_claudecode_pre_tool_use_empty_session():
    """No session_id → exits 0 without connecting."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'nonexistent.sock')

        result = run_hook(PRE_TOOL_USE, {
            'session_id': '',
            'tool_name': 'Bash',
            'tool_input': {'command': 'ls'},
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        assert result.returncode == 0, f'Expected 0, got {result.returncode}'


def test_claudecode_pre_tool_use_non_bash_tools():
    """Non-Bash tools like Read use file_path as preview."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, 'test.sock')
        server = MockSocketServer(sock_path).start()

        result = run_hook(PRE_TOOL_USE, {
            'session_id': 'sess-1',
            'tool_name': 'Read',
            'tool_input': {'file_path': '/tmp/example.py'},
        }, env_overrides={'ASK_SOCKET_PATH': sock_path})

        msg = server.wait_for_message()
        server.close()

        assert result.returncode == 0
        assert msg is not None
        assert msg.get('preview') == '/tmp/example.py'
        assert msg.get('tool') == 'Read'


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
