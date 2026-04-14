#!/usr/bin/env python3
"""
Acceptance tests for codex-2: end-to-end permission flow.

Each test creates a real git repo, starts the codex-2 daemon with isolated
paths, fires the pre_tool_use.py hook as a real subprocess (the hook blocks
waiting for a response), verifies the daemon emits a confirmation block, sends
an Allow/Deny response via MCP notifications/message, and asserts the hook
exits with the correct code (0=Allow, 2=Deny).

This mirrors the real production flow exactly:
  Codex CLI → pre_tool_use.py → daemon socket → iPhone → MCP → hook exits
"""
import json
import os
import shutil
import subprocess
import sys
import socket as socket_lib
import threading
import time
import uuid
from typing import Optional

import pytest

SCRIPT      = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
HOOKS_DIR   = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'hooks')
PRE_TOOL_USE = os.path.join(HOOKS_DIR, 'pre_tool_use.py')


# ── Git repo helpers ──────────────────────────────────────────────────────────

def create_git_repo(parent: str) -> str:
    """Create a real git repo with a random name. Returns the path."""
    name = f'accept-test-{uuid.uuid4().hex[:8]}'
    path = os.path.join(parent, name)
    os.makedirs(path)
    subprocess.run(['git', 'init', path], capture_output=True, check=True)
    subprocess.run(
        ['git', '-C', path, 'commit', '--allow-empty', '-m', 'init'],
        capture_output=True,
        env={**os.environ, 'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@test.com',
             'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@test.com'},
    )
    return path


# ── Acceptance harness ────────────────────────────────────────────────────────

class AcceptanceHarness:
    """Runs codex-2 daemon with isolated paths; captures emit_block calls."""

    def __init__(self, tmp_dir: str):
        self.tmp_dir = tmp_dir
        uid = uuid.uuid4().hex[:6]
        self.socket_path      = f'/tmp/acc-codex-{uid}.sock'
        self.allowlist_path   = os.path.join(tmp_dir, 'allowlist.json')
        self.active_blocks_path = os.path.join(tmp_dir, 'active-blocks.json')
        self.sessions_path    = os.path.join(tmp_dir, 'sessions.json')
        self.hooks_path       = os.path.join(tmp_dir, 'hooks.json')
        self.settings_path    = os.path.join(tmp_dir, 'settings.json')
        self.pmode_path       = os.path.join(tmp_dir, 'pmode.json')
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        # [(block_type, payload, block_id, rpc_id), ...]
        self.captured_blocks: list = []

    def start(self):
        env = os.environ.copy()
        env.update({
            'ASK_SOCKET_PATH':                self.socket_path,
            'ASK_CODEX2_SETTINGS_PATH':       self.settings_path,
            'ASK_CODEX2_ALLOWLIST_PATH':      self.allowlist_path,
            'ASK_CODEX2_ACTIVE_BLOCKS_PATH':  self.active_blocks_path,
            'ASK_CODEX2_HOOKS_PATH':          self.hooks_path,
            'ASK_CODEX2_SESSIONS_PATH':       self.sessions_path,
            'ASK_CODEX2_SKIP_DISCOVERY':      '1',
        })
        self.proc = subprocess.Popen(
            [sys.executable, SCRIPT],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        threading.Thread(target=self._read_stdout, daemon=True).start()
        self._wait_for_socket()
        return self

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
                            msg.get('id'),
                        ))
                if msg.get('method') == 'tools/call' and 'id' in msg and self._auto_respond:
                    self._send_ok(msg['id'])
            except json.JSONDecodeError:
                pass

    def _send_ok(self, rpc_id):
        self._write_rpc({'jsonrpc': '2.0', 'id': rpc_id,
                         'result': {'content': [{'type': 'text', 'text': 'ok'}]}})

    def _write_rpc(self, msg: dict):
        self.proc.stdin.write((json.dumps(msg) + '\n').encode())
        self.proc.stdin.flush()

    def _wait_for_socket(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(self.socket_path):
                return
            time.sleep(0.05)
        if self.proc and self.proc.poll() is not None:
            err = self.proc.stderr.read(2000).decode(errors='replace')
            raise RuntimeError(f'Daemon exited before socket appeared; stderr: {err!r}')
        raise RuntimeError(f'Socket did not appear: {self.socket_path}')

    def handshake(self) -> bool:
        init = self._wait_for(lambda m: m.get('method') == 'initialize' and 'id' in m)
        if not init:
            return False
        self._auto_respond = True
        self._write_rpc({'jsonrpc': '2.0', 'id': init['id'], 'result': {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'serverInfo': {'name': 'test', 'version': '0.1'},
        }})
        # Wait for first emit_block to confirm daemon is fully initialised
        emit = self._wait_for(
            lambda m: m.get('method') == 'tools/call'
            and m.get('params', {}).get('name') == 'emit_block',
            timeout=5.0,
        )
        return emit is not None

    def _wait_for(self, predicate, timeout=5.0) -> Optional[dict]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for msg in self._stdout_lines:
                    if predicate(msg):
                        return msg
            time.sleep(0.05)
        return None

    def wait_for_confirmation_block(self, timeout=5.0):
        """Return first captured confirmation block, or None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for entry in self.captured_blocks:
                    if entry[0] == 'confirmation':
                        return entry
            time.sleep(0.05)
        return None

    def send_user_response(self, block_id: str, value: str):
        """Simulate the iOS app responding to a permission confirmation block."""
        self._write_rpc({
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {
                'data': {
                    'type': 'user_response',
                    'blockId': block_id,
                    'value': value,
                }
            },
        })

    def socket_send(self, payload: dict):
        """Send a one-shot message to the daemon's Unix socket."""
        sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        sock.settimeout(5)
        try:
            sock.connect(self.socket_path)
            sock.sendall(json.dumps(payload).encode())
        finally:
            sock.close()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        for p in [self.socket_path]:
            if os.path.exists(p):
                try:
                    os.unlink(p)
                except Exception:
                    pass


# ── Hook runner ───────────────────────────────────────────────────────────────

def run_hook_async(hook_path: str, stdin_data: dict,
                   env_overrides: dict, cwd: str = None) -> tuple:
    """Start a hook subprocess in a daemon thread; return (result_dict, thread).

    result_dict is populated when the subprocess exits.
    The hook blocks on the daemon socket until the daemon sends a response,
    so call this before sending the user_response.
    """
    result = {}

    def _run():
        env = os.environ.copy()
        env.update(env_overrides)
        r = subprocess.run(
            [sys.executable, hook_path],
            input=json.dumps(stdin_data).encode(),
            capture_output=True,
            env=env,
            cwd=cwd,
            timeout=15,
        )
        result['returncode'] = r.returncode
        result['stdout']     = r.stdout.decode()
        result['stderr']     = r.stderr.decode()

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return result, t


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_allow_permission_hook_exits_0(tmp_path):
    """Allow response → hook exits 0.

    Full production-mirroring flow:
      git repo → hook fires → daemon socket → confirmation block emitted →
      iOS responds Allow → MCP user_response → hook exits 0
    """
    repo = create_git_repo(str(tmp_path))
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PRE_TOOL_USE,
            stdin_data={
                'tool': 'Bash',
                'session_id': 'tmux-codex:test.0',
                'tool_input': {'command': 'ls -la'},
            },
            env_overrides={
                'ASK_SOCKET_PATH':                  h.socket_path,
                'ASK_CODEX2_ALLOWLIST_PATH':        h.allowlist_path,
                'ASK_CODEX2_PERMISSION_MODE_PATH':  h.pmode_path,
            },
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, (
            f'Daemon did not emit a confirmation block; captured: {h.captured_blocks}'
        )
        block_type, payload, block_id, _ = entry

        assert payload.get('options') == ['Allow', 'Always Allow', 'Deny'], \
            f'Unexpected options in confirmation block: {payload.get("options")}'
        assert 'ls -la' in payload.get('body', ''), \
            f'Preview not in block body: {payload.get("body")}'

        h.send_user_response(block_id, 'Allow')

        thread.join(timeout=5.0)
        assert not thread.is_alive(), 'Hook subprocess did not exit within timeout'
        assert result.get('returncode') == 0, (
            f'Expected exit 0 (Allow); got {result.get("returncode")}; '
            f'stderr: {result.get("stderr", "")}'
        )
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_deny_permission_hook_exits_2(tmp_path):
    """Deny response → hook exits 2."""
    repo = create_git_repo(str(tmp_path))
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PRE_TOOL_USE,
            stdin_data={
                'tool': 'Bash',
                'session_id': 'tmux-codex:test.0',
                'tool_input': {'command': 'rm -rf /important'},
            },
            env_overrides={
                'ASK_SOCKET_PATH':                  h.socket_path,
                'ASK_CODEX2_ALLOWLIST_PATH':        h.allowlist_path,
                'ASK_CODEX2_PERMISSION_MODE_PATH':  h.pmode_path,
            },
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, 'Daemon did not emit a confirmation block'
        _, _, block_id, _ = entry

        h.send_user_response(block_id, 'Deny')

        thread.join(timeout=5.0)
        assert not thread.is_alive(), 'Hook subprocess did not exit within timeout'
        assert result.get('returncode') == 2, (
            f'Expected exit 2 (Deny); got {result.get("returncode")}; '
            f'stderr: {result.get("stderr", "")}'
        )
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_session_id_appears_in_confirmation_block(tmp_path):
    """A pre-registered session's ID appears in the confirmation block payload."""
    repo     = create_git_repo(str(tmp_path))
    session_id = 'tmux-codex:myrepo.0'
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        # Register session so daemon can resolve the session_id from the hook
        h.socket_send({
            'type': 'session_active',
            'session_id': session_id,
            'cwd': repo,
            'tmux_target': 'codex:myrepo.0',
        })
        time.sleep(0.3)

        result, thread = run_hook_async(
            PRE_TOOL_USE,
            stdin_data={
                'tool': 'Bash',
                'session_id': session_id,
                'tool_input': {'command': 'git status'},
            },
            env_overrides={
                'ASK_SOCKET_PATH':                  h.socket_path,
                'ASK_CODEX2_ALLOWLIST_PATH':        h.allowlist_path,
                'ASK_CODEX2_PERMISSION_MODE_PATH':  h.pmode_path,
            },
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, 'Daemon did not emit a confirmation block'
        _, payload, block_id, _ = entry

        assert session_id in payload.get('session_id', ''), (
            f'Expected session_id={session_id!r} in block payload; '
            f'got session_id={payload.get("session_id")!r}'
        )

        h.send_user_response(block_id, 'Allow')
        thread.join(timeout=5.0)
        assert result.get('returncode') == 0
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_allowlist_bypasses_daemon(tmp_path):
    """A command matching the allowlist exits 0 without asking the daemon."""
    repo = create_git_repo(str(tmp_path))
    allowlist_path = os.path.join(str(tmp_path), 'allowlist.json')
    with open(allowlist_path, 'w') as f:
        json.dump({'patterns': ['git status']}, f)

    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        # Run hook synchronously — it should exit immediately without waiting
        env = os.environ.copy()
        env.update({
            'ASK_SOCKET_PATH':                  h.socket_path,
            'ASK_CODEX2_ALLOWLIST_PATH':        allowlist_path,
            'ASK_CODEX2_PERMISSION_MODE_PATH':  h.pmode_path,
        })
        r = subprocess.run(
            [sys.executable, PRE_TOOL_USE],
            input=json.dumps({
                'tool': 'Bash',
                'session_id': 'tmux-codex:test.0',
                'tool_input': {'command': 'git status'},
            }).encode(),
            capture_output=True,
            env=env,
            cwd=repo,
            timeout=5,
        )
        assert r.returncode == 0, \
            f'Expected exit 0 for allowlisted command; got {r.returncode}'

        # Daemon should NOT have emitted any confirmation blocks
        time.sleep(0.3)
        with h._lock:
            confirm_blocks = [b for b in h.captured_blocks if b[0] == 'confirmation']
        assert not confirm_blocks, (
            f'No confirmation block should be emitted for allowlisted command; '
            f'got {confirm_blocks}'
        )
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_glob_allowlist_bypasses_daemon(tmp_path):
    """A glob pattern in the allowlist matches commands and skips the daemon."""
    repo = create_git_repo(str(tmp_path))
    allowlist_path = os.path.join(str(tmp_path), 'allowlist.json')
    with open(allowlist_path, 'w') as f:
        json.dump({'patterns': ['git *']}, f)

    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        env = os.environ.copy()
        env.update({
            'ASK_SOCKET_PATH':                  h.socket_path,
            'ASK_CODEX2_ALLOWLIST_PATH':        allowlist_path,
            'ASK_CODEX2_PERMISSION_MODE_PATH':  h.pmode_path,
        })
        r = subprocess.run(
            [sys.executable, PRE_TOOL_USE],
            input=json.dumps({
                'tool': 'Bash',
                'session_id': 'tmux-codex:test.0',
                'tool_input': {'command': 'git log --oneline'},
            }).encode(),
            capture_output=True,
            env=env,
            cwd=repo,
            timeout=5,
        )
        assert r.returncode == 0, \
            f'Expected exit 0 for glob-matched command; got {r.returncode}'
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
