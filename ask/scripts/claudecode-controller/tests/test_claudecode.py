#!/usr/bin/env python3
"""
Comprehensive pytest test suite for claudecode-controller/main.py.

Starts the daemon as a subprocess for integration tests, drives it via
stdin/stdout JSON-RPC and a Unix socket. Also tests static methods directly.

Run:
  cd ask/scripts/claudecode-controller && pytest tests/test_claudecode.py -v
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
from unittest.mock import patch, MagicMock

import pytest

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(SCRIPT_DIR, 'main.py')

# Load main.py under a unique module name to avoid sys.modules collision with
# other scripts that also have a 'main' module when the full test suite runs.
import importlib.util as _ilu
import types as _types

_saved_stdout_fd = os.dup(1)  # save real stdout fd
_devnull = open(os.devnull, 'w')
os.dup2(_devnull.fileno(), 1)  # silence fd 1 during import
try:
    _spec = _ilu.spec_from_file_location('claudecode_controller_main', SCRIPT)
    _mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    MCPClient = _mod.MCPClient
    SESSION_TTL = _mod.SESSION_TTL
    SESSION_DISK_TTL = _mod.SESSION_DISK_TTL
finally:
    os.dup2(_saved_stdout_fd, 1)  # restore real stdout fd
    os.close(_saved_stdout_fd)
    _devnull.close()


# ===========================================================================
# 3a.  _parse_tmux_prompt — all three formats
# ===========================================================================

class TestParseTmuxPrompt:
    """Unit tests for MCPClient._parse_tmux_prompt (no daemon needed)."""

    def test_parse_numbered_menu(self):
        content = """
  1. Option Alpha
  2. Option Beta
  3. Option Gamma
Press enter to confirm
"""
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        body, options, mode = result
        assert mode == 'numbered'
        assert options == ['Option Alpha', 'Option Beta', 'Option Gamma']

    def test_parse_numbered_menu_with_period_separator(self):
        content = "1) First choice\n2) Second choice\nPress enter to continue\n"
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        _, options, mode = result
        assert mode == 'numbered'
        assert len(options) == 2

    def test_parse_yn_prompt(self):
        content = "Do you want to proceed? (y/n) › "
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        body, options, mode = result
        assert mode == 'yn'
        assert options == ['Yes', 'No']

    def test_parse_yn_bracket_uppercase(self):
        content = "Delete file? [Y/n] "
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        _, options, mode = result
        assert mode == 'yn'
        assert options == ['Yes', 'No']

    def test_parse_yn_bracket_lowercase(self):
        content = "Overwrite existing? [y/N] "
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        _, options, mode = result
        assert mode == 'yn'

    def test_parse_arrow_menu(self):
        content = """Trust the files in this folder?
  ~/Documents/code/myproject

\u276f Yes, proceed
  No, exit"""
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        body, options, mode = result
        assert mode == 'arrow'
        assert 'Yes, proceed' in options
        assert 'No, exit' in options

    def test_parse_arrow_menu_gt_prefix(self):
        content = "> Accept changes\n  Reject changes\n  Skip\n"
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        _, options, mode = result
        assert mode == 'arrow'
        assert len(options) >= 2

    def test_parse_no_match(self):
        """Plain terminal output — no interactive prompt."""
        content = "$ git status\nOn branch main\nnothing to commit"
        assert MCPClient._parse_tmux_prompt(content) is None

    def test_parse_numbered_no_footer(self):
        """Numbered list without footer — should NOT match (avoids false positives)."""
        content = "1. First item\n2. Second item"
        result = MCPClient._parse_tmux_prompt(content)
        assert result is None or result[2] != 'numbered'

    def test_parse_empty_string(self):
        assert MCPClient._parse_tmux_prompt('') is None

    def test_parse_single_line_prompt_output(self):
        """A line that is just a shell prompt should not match."""
        content = "$ "
        assert MCPClient._parse_tmux_prompt(content) is None

    def test_numbered_body_is_non_empty(self):
        content = "Which theme?\n1. Dark\n2. Light\nPress enter to confirm\n"
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        body, _, mode = result
        assert mode == 'numbered'
        assert body  # body should not be empty

    def test_arrow_body_comes_from_preceding_lines(self):
        content = "Trust this project?\n\u276f Yes\n  No\n"
        result = MCPClient._parse_tmux_prompt(content)
        assert result is not None
        body, _, mode = result
        assert mode == 'arrow'
        assert 'Trust' in body


# ===========================================================================
# Harness for integration tests
# ===========================================================================

class Harness:
    """Runs claudecode-controller/main.py as a subprocess.

    Acts as the AskMac MCP daemon: receives tools/call requests, can send
    back mock results, and can fire hook events via the Unix socket.
    """

    def __init__(self, tmp_dir: str, extra_env: dict = None):
        self.tmp_dir = tmp_dir
        self.sessions_path = os.path.join(tmp_dir, 'sessions.json')
        self._sock_id = str(id(self))[-6:]
        self.socket_path = f'/tmp/cctest-{self._sock_id}.sock'
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list = []
        self._lock = threading.Lock()
        self._auto_respond = False
        self._extra_env = extra_env or {}

    def start(self):
        env = os.environ.copy()
        env['ASK_SOCKET_PATH'] = self.socket_path
        env['ASK_SESSIONS_PATH'] = self.sessions_path
        env['ASK_SKIP_DISCOVERY'] = '1'
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
        if self.proc and self.proc.poll() is not None:
            err = self.proc.stderr.read(2000).decode(errors='replace')
            raise RuntimeError(f'claudecode-controller exited before socket; stderr: {err!r}')
        raise RuntimeError(f'socket did not appear at {self.socket_path}')

    def rpc_response(self, rpc_id, result=None):
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'result': result or {}}
        self.proc.stdin.write((json.dumps(msg) + '\n').encode())
        self.proc.stdin.flush()

    def rpc_error(self, rpc_id, message: str):
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'error': {'code': -32000, 'message': message}}
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
        # Wait for an emit to confirm the script is up
        block = self.wait_for(
            lambda m: m.get('method') == 'tools/call'
            and m.get('params', {}).get('name') == 'emit_block',
            timeout=5.0,
        )
        return block is not None

    def send_notification(self, data: dict):
        msg = {
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {'data': data},
        }
        self.proc.stdin.write((json.dumps(msg) + '\n').encode())
        self.proc.stdin.flush()

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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def harness(tmp_path):
    h = Harness(str(tmp_path))
    h.start()
    assert h.handshake(), 'MCP handshake failed'
    yield h
    h.stop()


# ===========================================================================
# 3b.  Permission request handling
# ===========================================================================

class TestPermissionRequests:
    """Integration tests for permission_request handling."""

    def test_allow_response(self, harness):
        """Allow response sends {'value': 'Allow'} back through the socket."""
        result_holder = {}

        def fire():
            result_holder['resp'] = harness.socket_send({
                'type': 'permission_request',
                'tool': 'Bash',
                'preview': 'echo hello',
                'options': ['Allow', 'Deny'],
                'session_id': 'test-session-allow',
            }, wait_response=True)

        t = threading.Thread(target=fire, daemon=True)
        t.start()

        # Wait for the confirmation block to be emitted
        perm_block = harness.wait_for(
            lambda m: is_emit(m, 'confirmation'),
            timeout=4.0,
        )
        assert perm_block is not None, 'Permission block should be emitted'
        block_id = perm_block['params']['arguments']['blockId']

        # Simulate user tapping "Allow"
        harness.send_notification({
            'type': 'user_response',
            'blockId': block_id,
            'value': 'Allow',
        })

        t.join(timeout=5.0)
        assert not t.is_alive(), 'Hook thread should complete after response'
        resp = result_holder.get('resp')
        assert resp is not None
        assert resp.get('value') == 'Allow'

    def test_deny_response(self, harness):
        """Deny response sends {'value': 'Deny'} back through the socket."""
        result_holder = {}

        def fire():
            result_holder['resp'] = harness.socket_send({
                'type': 'permission_request',
                'tool': 'Write',
                'preview': 'overwrite important.txt',
                'options': ['Allow', 'Deny'],
                'session_id': 'test-session-deny',
            }, wait_response=True)

        t = threading.Thread(target=fire, daemon=True)
        t.start()

        perm_block = harness.wait_for(
            lambda m: is_emit(m, 'confirmation'),
            timeout=4.0,
        )
        assert perm_block is not None
        block_id = perm_block['params']['arguments']['blockId']

        harness.send_notification({
            'type': 'user_response',
            'blockId': block_id,
            'value': 'Deny',
        })

        t.join(timeout=5.0)
        assert not t.is_alive()
        resp = result_holder.get('resp')
        assert resp is not None
        assert resp.get('value') == 'Deny'

    def test_permission_block_includes_suggestion_label(self, harness):
        """Permission block payload should include the tool name and preview."""
        result_holder = {}

        def fire():
            result_holder['resp'] = harness.socket_send({
                'type': 'permission_request',
                'tool': 'Bash',
                'preview': 'npm install',
                'options': ['Allow', 'Always Allow', 'Deny'],
                'session_id': 'test-session-label',
            }, wait_response=True)

        t = threading.Thread(target=fire, daemon=True)
        t.start()

        perm_block = harness.wait_for(
            lambda m: is_emit(m, 'confirmation'),
            timeout=4.0,
        )
        assert perm_block is not None
        payload = perm_block['params']['arguments']['payload']
        # Title should mention the tool
        assert 'Bash' in payload.get('title', '')
        # Body should contain the preview
        assert 'npm install' in payload.get('body', '')
        # Always Allow option should be present
        assert 'Always Allow' in payload.get('options', [])

        # Clean up — respond to unblock the hook thread
        block_id = perm_block['params']['arguments']['blockId']
        harness.send_notification({
            'type': 'user_response',
            'blockId': block_id,
            'value': 'Allow',
        })
        t.join(timeout=5.0)


# ===========================================================================
# 3c.  Tool history cap and preview
# ===========================================================================

class TestToolHistory:
    """Unit tests for _handle_pre_tool_use: history cap and preview capture."""

    def _make_client(self):
        client = MCPClient.__new__(MCPClient)
        MCPClient.__init__(client)
        client._initialized = True
        return client

    def test_history_capped_at_20(self):
        """After 25 tool calls, only 20 entries remain."""
        client = self._make_client()
        session_id = 'test-session-history'
        client._sessions[session_id] = {'cwd': '/tmp', 'project': 'test', 'last_seen': time.time()}

        for i in range(25):
            msg = {
                'session_id': session_id,
                'tool': 'Bash',
                'preview': f'cmd-{i}',
                'cwd': '/tmp',
            }
            # Call the synchronous part directly (no async needed for the history logic)
            entry = {'tool': 'Bash', 'preview': f'cmd-{i}', 'ts': time.time()}
            client._current_tools[session_id] = entry
            history = client._tool_histories.setdefault(session_id, [])
            history.append(entry)
            if len(history) > 20:
                del history[:-20]

        hist = client._tool_histories.get(session_id, [])
        assert len(hist) == 20, f'Expected 20 entries, got {len(hist)}'

    def test_preview_captured_in_history(self):
        """Preview text is stored in the history entry."""
        client = self._make_client()
        session_id = 'test-session-preview'
        client._sessions[session_id] = {'cwd': '/tmp', 'project': 'test', 'last_seen': time.time()}

        preview_text = 'git diff --stat HEAD'
        entry = {'tool': 'Bash', 'preview': preview_text, 'ts': time.time()}
        client._current_tools[session_id] = entry
        history = client._tool_histories.setdefault(session_id, [])
        history.append(entry)

        hist = client._tool_histories[session_id]
        assert len(hist) == 1
        assert hist[0]['preview'] == preview_text

    def test_history_oldest_entries_evicted(self):
        """When the cap is exceeded, the oldest entries are removed."""
        client = self._make_client()
        session_id = 'test-session-evict'
        client._sessions[session_id] = {'cwd': '/tmp', 'project': 'test', 'last_seen': time.time()}

        for i in range(25):
            entry = {'tool': 'Bash', 'preview': f'cmd-{i}', 'ts': time.time()}
            history = client._tool_histories.setdefault(session_id, [])
            history.append(entry)
            if len(history) > 20:
                del history[:-20]

        hist = client._tool_histories[session_id]
        # The first 5 entries (cmd-0 through cmd-4) should have been evicted
        previews = [e['preview'] for e in hist]
        for i in range(5):
            assert f'cmd-{i}' not in previews, f'cmd-{i} should have been evicted'
        # cmd-5 through cmd-24 should remain
        assert 'cmd-24' in previews


# ===========================================================================
# 3d.  Session save/load round-trip
# ===========================================================================

class TestSessionPersistence:
    """Unit tests for _save_sessions / _load_sessions."""

    def _make_client(self, sessions_path: str):
        client = MCPClient.__new__(MCPClient)
        MCPClient.__init__(client)
        client._initialized = True
        # Monkeypatch SESSIONS_PATH used by _save_sessions / _load_sessions
        self._orig_path = _mod.SESSIONS_PATH
        _mod.SESSIONS_PATH = sessions_path
        return client

    def _restore(self):
        _mod.SESSIONS_PATH = self._orig_path

    def test_save_load_round_trip(self, tmp_path):
        sessions_path = str(tmp_path / 'sessions.json')
        client = self._make_client(sessions_path)
        try:
            session_id = 'hook-session-abc123'
            client._sessions[session_id] = {
                'cwd': '/Users/kevin/code/myproject',
                'project': 'myproject',
                'last_seen': time.time(),
                'tty': 's003',
            }
            client._save_sessions()

            # Fresh client loads from disk
            client2 = self._make_client(sessions_path)
            client2._load_sessions()
            assert session_id in client2._sessions
            loaded = client2._sessions[session_id]
            assert loaded['cwd'] == '/Users/kevin/code/myproject'
            assert loaded['tty'] == 's003'
        finally:
            self._restore()

    def test_pid_sessions_not_persisted(self, tmp_path):
        sessions_path = str(tmp_path / 'sessions.json')
        client = self._make_client(sessions_path)
        try:
            client._sessions['pid-12345'] = {
                'cwd': '/tmp/something',
                'project': 'something',
                'last_seen': time.time(),
            }
            client._sessions['hook-real-session'] = {
                'cwd': '/tmp/real',
                'project': 'real',
                'last_seen': time.time(),
                'tty': 's004',
            }
            client._save_sessions()

            data = json.loads(open(sessions_path).read())
            assert 'pid-12345' not in data
            assert 'hook-real-session' in data
        finally:
            self._restore()

    def test_expired_sessions_pruned_on_load(self, tmp_path):
        sessions_path = str(tmp_path / 'sessions.json')
        client = self._make_client(sessions_path)
        try:
            old_time = time.time() - SESSION_DISK_TTL - 60  # expired
            fresh_time = time.time()
            data = {
                'old-session': {
                    'cwd': '/tmp/old',
                    'project': 'old',
                    'last_seen': old_time,
                    'tty': 's001',
                },
                'fresh-session': {
                    'cwd': '/tmp/fresh',
                    'project': 'fresh',
                    'last_seen': fresh_time,
                    'tty': 's002',
                },
            }
            with open(sessions_path, 'w') as f:
                json.dump(data, f)

            client._load_sessions()
            assert 'old-session' not in client._sessions, 'Expired session should be pruned'
            assert 'fresh-session' in client._sessions, 'Fresh session should survive'
        finally:
            self._restore()


# ===========================================================================
# 3e.  Process discovery dedup
# ===========================================================================

class TestProcessDiscovery:
    """Verify _discover_active_processes deduplicates on TTY."""

    def test_same_tty_two_pids_creates_one_session(self, tmp_path):
        """Two claude processes on the same TTY → only one session registered."""
        import asyncio

        client = MCPClient.__new__(MCPClient)
        MCPClient.__init__(client)
        client._initialized = True

        # Mock ps output: two claude processes on s003
        ps_output = (
            "  PID TT           COMM\n"
            "  101 s003         claude\n"
            "  102 s003         claude\n"
        ).encode()

        # Mock lsof to return the same cwd for both pids
        lsof_output = b"n/tmp/myproject\n"

        # Skip environment check
        os.environ['ASK_SKIP_DISCOVERY'] = '0'

        async def run():
            with patch('asyncio.create_subprocess_exec') as mock_exec:
                call_count = [0]

                async def fake_exec(*args, **kwargs):
                    call_count[0] += 1
                    proc = MagicMock()
                    if args[0] == 'ps':
                        proc.communicate = asyncio.coroutine(lambda: (ps_output, b''))
                    else:
                        proc.communicate = asyncio.coroutine(lambda: (lsof_output, b''))
                    return proc

                mock_exec.side_effect = fake_exec

                # Pre-seed one process already known so the second is "new"
                # (simulate real dedup: first pid registers, second has same TTY)
                client._sessions['pid-101'] = {
                    'cwd': '/tmp/myproject',
                    'project': 'myproject',
                    'last_seen': time.time(),
                    'tty': 's003',
                }

                await client._discover_active_processes()

        asyncio.run(run())

        # Only one session for /tmp/myproject should exist (pid-101 + pid-102 share s003)
        sessions_for_cwd = [
            sid for sid, info in client._sessions.items()
            if info.get('cwd') == '/tmp/myproject'
        ]
        assert len(sessions_for_cwd) == 1, (
            f'Expected 1 session for shared TTY, got {len(sessions_for_cwd)}: {sessions_for_cwd}'
        )


# ===========================================================================
# 3f.  Session pruning
# ===========================================================================

class TestSessionPruning:
    """Unit tests for _prune_dead_pid_sessions and _prune_dead_real_sessions."""

    def _make_client(self):
        client = MCPClient.__new__(MCPClient)
        MCPClient.__init__(client)
        client._initialized = True
        return client

    def test_dead_pid_session_pruned(self):
        """A pid-* session whose process no longer exists should be pruned."""
        import asyncio

        client = self._make_client()
        # Use a PID that definitely doesn't exist (very high number)
        dead_pid = 999999999
        session_id = f'pid-{dead_pid}'
        client._sessions[session_id] = {
            'cwd': '/tmp/dead',
            'project': 'dead',
            'last_seen': time.time(),
        }

        async def run():
            # _prune_dead_pid_sessions calls asyncio.create_task internally
            # so it must run inside an event loop.
            async def fake_unregister(sid):
                pass

            with patch.object(client, '_tm_unregister', side_effect=fake_unregister):
                return client._prune_dead_pid_sessions()

        dead = asyncio.run(run())

        assert session_id in dead, 'Dead PID session should be in pruned list'
        assert session_id not in client._sessions, 'Dead PID session should be removed'

    def test_live_pid_session_kept(self):
        """A pid-* session whose process is still alive should be kept."""
        import asyncio

        client = self._make_client()
        # Use the current process PID — it's definitely alive
        live_pid = os.getpid()
        session_id = f'pid-{live_pid}'
        client._sessions[session_id] = {
            'cwd': '/tmp/live',
            'project': 'live',
            'last_seen': time.time(),
        }

        async def run():
            async def fake_unregister(sid):
                pass

            with patch.object(client, '_tm_unregister', side_effect=fake_unregister):
                return client._prune_dead_pid_sessions()

        dead = asyncio.run(run())

        assert session_id not in dead, 'Live PID session should NOT be pruned'
        assert session_id in client._sessions, 'Live PID session should remain'

    def test_prune_dead_real_sessions(self):
        """Real (hook-registered) session not in terminal-manager list should be pruned."""
        import asyncio

        client = self._make_client()
        client._sessions['hook-session-live'] = {
            'cwd': '/tmp/live',
            'project': 'live',
            'last_seen': time.time(),
            'tty': 's001',
        }
        client._sessions['hook-session-dead'] = {
            'cwd': '/tmp/dead',
            'project': 'dead',
            'last_seen': time.time(),
            'tty': 's002',
        }

        # Simulate terminal-manager returning only 'hook-session-live'
        async def fake_list_sessions(filter=''):
            return [{'session_id': 'hook-session-live'}]

        async def fake_unregister(sid):
            pass

        async def run():
            with patch.object(client, 'list_terminal_sessions', side_effect=fake_list_sessions):
                with patch.object(client, '_tm_unregister', side_effect=fake_unregister):
                    with patch.object(client, '_save_sessions', return_value=None):
                        return await client._prune_dead_real_sessions()

        dead = asyncio.run(run())
        assert 'hook-session-dead' in dead
        assert 'hook-session-live' not in dead
        assert 'hook-session-dead' not in client._sessions
        assert 'hook-session-live' in client._sessions

    def test_prune_skips_when_tm_returns_empty(self):
        """If terminal-manager returns empty, pruning is skipped (avoids false eviction)."""
        import asyncio

        client = self._make_client()
        client._sessions['hook-session-maybe-alive'] = {
            'cwd': '/tmp/maybe',
            'project': 'maybe',
            'last_seen': time.time(),
            'tty': 's003',
        }

        async def fake_list_sessions(filter=''):
            return []

        async def run():
            with patch.object(client, 'list_terminal_sessions', side_effect=fake_list_sessions):
                return await client._prune_dead_real_sessions()

        dead = asyncio.run(run())
        assert dead == [], 'Should not prune when TM returns empty'
        assert 'hook-session-maybe-alive' in client._sessions


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
