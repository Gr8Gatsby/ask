#!/usr/bin/env python3
"""
Acceptance tests for claudecode-controller: end-to-end permission flow.

Each test creates a real git repo, starts the claudecode-controller daemon with
isolated paths, fires the permission_request.py hook as a real subprocess (the
hook blocks waiting for a response), verifies the daemon emits a confirmation
block, sends an Allow/Deny response via MCP notifications/message, and asserts
the hook exits with the correct code (0=Allow, 2=Deny).

This mirrors the real production flow exactly:
  Claude Code → permission_request.py → daemon socket → confirmation block →
  iPhone → MCP → hook decision → hook exits
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

SCRIPT           = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
HOOKS_DIR        = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'hooks')
PERMISSION_HOOK  = os.path.join(HOOKS_DIR, 'permission_request.py')
SESSION_START_HOOK = os.path.join(HOOKS_DIR, 'session_start.py')


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
    """Runs claudecode-controller daemon with isolated paths; captures emit_block calls."""

    def __init__(self, tmp_dir: str):
        self.tmp_dir = tmp_dir
        uid = uuid.uuid4().hex[:6]
        self.socket_path   = f'/tmp/acc-claude-{uid}.sock'
        self.sessions_path = os.path.join(tmp_dir, 'sessions.json')
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        # [(block_type, payload, block_id, rpc_id), ...]
        self.captured_blocks: list = []

    def start(self):
        env = os.environ.copy()
        env.update({
            'ASK_SOCKET_PATH':  self.socket_path,
            'ASK_SESSIONS_PATH': self.sessions_path,
            'ASK_SKIP_DISCOVERY': '1',
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
        # Wait for tile emit — confirms _initialized = True
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

    def socket_send_oneway(self, payload: dict):
        """Send a one-shot message to the daemon's Unix socket (no response expected)."""
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
        for p in [self.socket_path, self.sessions_path]:
            if os.path.exists(p):
                try:
                    os.unlink(p)
                except Exception:
                    pass


# ── Hook runner ───────────────────────────────────────────────────────────────

def run_hook_async(hook_path: str, stdin_data: dict,
                   env_overrides: dict, cwd: str = None) -> tuple:
    """Start a hook subprocess in a daemon thread; return (result_dict, thread).

    The hook blocks on the daemon socket until a response arrives.
    Call this before sending the user_response.
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
    """Allow response → permission_request.py hook exits 0.

    Full production-mirroring flow:
      git repo → permission_request.py fires → daemon socket →
      confirmation block emitted → iOS responds Allow →
      MCP user_response → hook outputs allow decision → exits 0
    """
    repo       = create_git_repo(str(tmp_path))
    session_id = str(uuid.uuid4())
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PERMISSION_HOOK,
            stdin_data={
                'tool_name': 'Bash',
                'session_id': session_id,
                'tool_input': {'command': 'ls -la'},
                'permission_suggestions': [],
            },
            env_overrides={'ASK_SOCKET_PATH': h.socket_path},
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, (
            f'Daemon did not emit a confirmation block; captured: {h.captured_blocks}'
        )
        block_type, payload, block_id, _ = entry

        # No suggestions → options are ['Yes', 'No']
        assert payload.get('options') == ['Yes', 'No'], \
            f'Unexpected options: {payload.get("options")}'
        assert 'ls -la' in payload.get('body', ''), \
            f'Preview not in block body: {payload.get("body")}'

        h.send_user_response(block_id, 'Yes')

        thread.join(timeout=5.0)
        assert not thread.is_alive(), 'Hook subprocess did not exit within timeout'
        assert result.get('returncode') == 0, (
            f'Expected exit 0 (Allow); got {result.get("returncode")}; '
            f'stdout: {result.get("stdout", "")}; '
            f'stderr: {result.get("stderr", "")}'
        )

        # Verify hook output contains the allow decision JSON
        stdout = result.get('stdout', '')
        decision = json.loads(stdout)
        assert decision['hookSpecificOutput']['decision']['behavior'] == 'allow'
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_deny_permission_hook_exits_2(tmp_path):
    """Deny response → permission_request.py hook exits 2 with deny decision."""
    repo       = create_git_repo(str(tmp_path))
    session_id = str(uuid.uuid4())
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PERMISSION_HOOK,
            stdin_data={
                'tool_name': 'Bash',
                'session_id': session_id,
                'tool_input': {'command': 'rm -rf /important'},
                'permission_suggestions': [],
            },
            env_overrides={'ASK_SOCKET_PATH': h.socket_path},
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, 'Daemon did not emit a confirmation block'
        _, _, block_id, _ = entry

        h.send_user_response(block_id, 'No')

        thread.join(timeout=5.0)
        assert not thread.is_alive(), 'Hook subprocess did not exit within timeout'
        assert result.get('returncode') == 2, (
            f'Expected exit 2 (Deny); got {result.get("returncode")}; '
            f'stderr: {result.get("stderr", "")}'
        )
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_always_allow_suggestion_appears_in_options(tmp_path):
    """permission_suggestions produce labelled always-allow options in the block."""
    repo       = create_git_repo(str(tmp_path))
    session_id = str(uuid.uuid4())
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PERMISSION_HOOK,
            stdin_data={
                'tool_name': 'Read',
                'session_id': session_id,
                'tool_input': {'file_path': '/tmp/notes.txt'},
                'permission_suggestions': [{
                    'behavior': 'allow',
                    'rules': [{'toolName': 'Read', 'ruleContent': '/tmp'}],
                }],
            },
            env_overrides={'ASK_SOCKET_PATH': h.socket_path},
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, 'Daemon did not emit a confirmation block'
        _, payload, block_id, _ = entry

        options = payload.get('options', [])
        assert 'Allow' in options, f'Expected Allow in options; got {options}'
        assert 'Deny' in options, f'Expected Deny in options; got {options}'
        always_allow_opts = [o for o in options if 'Always allow' in o]
        assert always_allow_opts, f'Expected always-allow option; got {options}'

        # Clean up: send Allow so hook exits
        h.send_user_response(block_id, 'Allow')
        thread.join(timeout=5.0)
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_allow_confirmation_block_has_session_id(tmp_path):
    """Confirmation block includes the session_id from the hook."""
    repo       = create_git_repo(str(tmp_path))
    session_id = str(uuid.uuid4())
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        result, thread = run_hook_async(
            PERMISSION_HOOK,
            stdin_data={
                'tool_name': 'Write',
                'session_id': session_id,
                'tool_input': {'file_path': '/tmp/output.txt'},
                'permission_suggestions': [],
            },
            env_overrides={'ASK_SOCKET_PATH': h.socket_path},
            cwd=repo,
        )

        entry = h.wait_for_confirmation_block(timeout=5.0)
        assert entry is not None, 'Daemon did not emit a confirmation block'
        _, payload, block_id, _ = entry

        assert payload.get('session_id') == session_id, (
            f'Expected session_id={session_id!r} in payload; '
            f'got {payload.get("session_id")!r}'
        )

        h.send_user_response(block_id, 'Yes')
        thread.join(timeout=5.0)
        assert result.get('returncode') == 0
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


def test_session_start_hook_registers_session(tmp_path):
    """session_start.py hook fires and daemon emits an agent_session block."""
    repo       = create_git_repo(str(tmp_path))
    session_id = str(uuid.uuid4())
    h = AcceptanceHarness(str(tmp_path))
    try:
        h.start()
        assert h.handshake(), 'MCP handshake failed'

        # Run session_start hook (fires on every Claude Code session start)
        env = os.environ.copy()
        env['ASK_SOCKET_PATH'] = h.socket_path
        subprocess.run(
            [sys.executable, SESSION_START_HOOK],
            input=json.dumps({'session_id': session_id}).encode(),
            capture_output=True,
            env=env,
            cwd=repo,
            timeout=5,
        )

        # Daemon should emit an agent_session block for this session
        deadline = time.time() + 5.0
        found = None
        while time.time() < deadline:
            with h._lock:
                for bt, payload, bid, _ in h.captured_blocks:
                    if bt == 'agent_session':
                        found = (bt, payload, bid)
                        break
            if found:
                break
            time.sleep(0.05)

        assert found is not None, (
            f'Daemon should emit agent_session block after session_start hook; '
            f'captured blocks: {[(b[0], b[2]) for b in h.captured_blocks]}'
        )
    finally:
        h.stop()
        shutil.rmtree(repo, ignore_errors=True)


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
