#!/usr/bin/env python3
"""
test_unit.py — automated unit tests for claudecode-controller.

Covers pure functions, session registration/eviction logic, and routing
transport priority (with mocked RPC calls).

Run with:  pytest ask/scripts/claudecode-controller/test_unit.py -v
"""
import sys
import os
import asyncio
import time
import pytest
from unittest.mock import AsyncMock, MagicMock, patch, call

import importlib.util

# Load claudecode-controller's main.py under a unique module name to avoid
# colliding with terminal-manager's main.py in Python's import cache (both
# scripts are named main.py and may be imported in the same pytest session).
_saved_stdout = sys.stdout
_spec = importlib.util.spec_from_file_location(
    'claudecode_main',
    os.path.join(os.path.dirname(__file__), 'main.py'),
)
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)
sys.stdout = _saved_stdout


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_client():
    """Return an MCPClient with _initialized=True and no real I/O."""
    client = cc.MCPClient()
    client._initialized = True
    return client


# ---------------------------------------------------------------------------
# _strip_ansi
# ---------------------------------------------------------------------------

class TestStripAnsi:
    def test_no_escape(self):
        assert cc.MCPClient._strip_ansi('hello') == 'hello'

    def test_color(self):
        assert cc.MCPClient._strip_ansi('\x1b[32mok\x1b[0m') == 'ok'

    def test_cursor(self):
        assert cc.MCPClient._strip_ansi('\x1b[2K\x1b[A') == ''

    def test_osc(self):
        assert cc.MCPClient._strip_ansi('\x1b]0;title\x07text') == 'text'

    def test_carriage_return(self):
        assert cc.MCPClient._strip_ansi('a\rb') == 'ab'


# ---------------------------------------------------------------------------
# _is_claude_idle
# ---------------------------------------------------------------------------

class TestIsClaudeIdle:
    def test_idle_prompt(self):
        assert cc.MCPClient._is_claude_idle('Some output\n> ') is True

    def test_idle_prompt_with_spaces(self):
        assert cc.MCPClient._is_claude_idle('Output\n  >  ') is True

    def test_not_idle_working(self):
        assert cc.MCPClient._is_claude_idle('Claude is thinking...') is False

    def test_empty(self):
        assert cc.MCPClient._is_claude_idle('') is False

    def test_only_blank_lines(self):
        assert cc.MCPClient._is_claude_idle('\n\n\n') is False

    def test_prompt_not_last_line(self):
        assert cc.MCPClient._is_claude_idle('> \nMore output') is False


# ---------------------------------------------------------------------------
# _extract_response
# ---------------------------------------------------------------------------

class TestExtractResponse:
    def test_simple(self):
        content = 'Hello there.\n> '
        assert cc.MCPClient._extract_response(content) == 'Hello there.'

    def test_multiline(self):
        content = 'Line 1\nLine 2\nLine 3\n> '
        result = cc.MCPClient._extract_response(content)
        assert 'Line 1' in result
        assert 'Line 3' in result

    def test_strips_separators(self):
        content = '━━━━━━━━━━\nResponse\n> '
        result = cc.MCPClient._extract_response(content)
        assert '━' not in result
        assert 'Response' in result

    def test_empty(self):
        assert cc.MCPClient._extract_response('') == ''

    def test_only_prompt(self):
        assert cc.MCPClient._extract_response('> ') == ''

    def test_multiple_trailing_prompts(self):
        content = 'Response\n> \n> '
        result = cc.MCPClient._extract_response(content)
        assert result == 'Response'

    def test_truncated_to_4000(self):
        content = ('x' * 200 + '\n') * 30 + '> '
        result = cc.MCPClient._extract_response(content)
        assert len(result) <= 4000


# ---------------------------------------------------------------------------
# _project_label
# ---------------------------------------------------------------------------

class TestProjectLabel:
    def test_long_path(self):
        label = cc.MCPClient._project_label('/Users/kevin/code/myrepo', 'abc123')
        assert 'code/myrepo' in label
        assert 'abc123' in label[:20] or 'abc123'[:6] in label

    def test_short_path(self):
        label = cc.MCPClient._project_label('/repo', 'abc123def')
        assert 'repo' in label

    def test_empty_cwd(self):
        label = cc.MCPClient._project_label('', 'abc123def')
        assert 'Claude Code' in label

    def test_pid_session_shows_full_pid(self):
        label = cc.MCPClient._project_label('/code/repo', 'pid-12345')
        assert 'pid-12345' in label

    def test_real_session_shows_short_id(self):
        label = cc.MCPClient._project_label('/code/repo', 'abcdef1234567890')
        assert 'abcdef' in label
        assert '1234567890' not in label


# ---------------------------------------------------------------------------
# _is_pid_alive
# ---------------------------------------------------------------------------

class TestIsPidAlive:
    def test_current_process_alive(self):
        assert cc.MCPClient._is_pid_alive(os.getpid()) is True

    def test_nonexistent_pid(self):
        assert cc.MCPClient._is_pid_alive(999999999) is False

    def test_pid_zero_raises_invalid(self):
        # pid 0 signals the process group — should return False gracefully
        result = cc.MCPClient._is_pid_alive(0)
        assert isinstance(result, bool)


# ---------------------------------------------------------------------------
# _pid_session_alive
# ---------------------------------------------------------------------------

class TestPidSessionAlive:
    def test_non_pid_session_always_alive(self):
        assert cc.MCPClient._pid_session_alive('abc-123') is True

    def test_real_pid_alive(self):
        sid = f'pid-{os.getpid()}'
        assert cc.MCPClient._pid_session_alive(sid) is True

    def test_dead_pid(self):
        assert cc.MCPClient._pid_session_alive('pid-999999999') is False

    def test_invalid_pid_format(self):
        assert cc.MCPClient._pid_session_alive('pid-notanumber') is False


# ---------------------------------------------------------------------------
# _register_session
# ---------------------------------------------------------------------------

class TestRegisterSession:
    def test_new_session_returns_true(self):
        client = make_client()
        result = client._register_session('s1', '/code/repo')
        assert result is True
        assert 's1' in client._sessions

    def test_duplicate_returns_false(self):
        client = make_client()
        client._register_session('s1', '/code/repo')
        result = client._register_session('s1', '/code/repo')
        assert result is False

    def test_stores_cwd_and_project(self):
        client = make_client()
        client._register_session('s1', '/Users/kevin/code/myrepo')
        assert client._sessions['s1']['cwd'] == '/Users/kevin/code/myrepo'
        assert 'myrepo' in client._sessions['s1']['project']

    def test_stores_claude_pid(self):
        client = make_client()
        client._register_session('s1', '/code/repo', claude_pid=12345)
        assert client._sessions['s1']['claude_pid'] == 12345

    def test_updates_pid_on_duplicate(self):
        client = make_client()
        client._register_session('s1', '/code/repo')
        client._sessions['s1'].pop('claude_pid', None)
        # Re-register same session — only updates pid on existing entry
        client._register_session('s1', '/code/repo', claude_pid=99)
        assert client._sessions['s1']['claude_pid'] == 99

    def test_evicts_dead_pid_session(self):
        client = make_client()
        # Register a pid-* session with a definitely-dead PID
        client._sessions['pid-999999999'] = {
            'cwd': '/code/repo', 'project': 'repo [pid-999999999]',
            'last_seen': time.time(),
        }
        with patch('asyncio.create_task'):
            client._register_session('real-session', '/code/repo')
        assert 'pid-999999999' not in client._sessions
        assert 'real-session' in client._sessions

    def test_does_not_evict_live_pid_session(self):
        client = make_client()
        live_pid = os.getpid()
        client._sessions[f'pid-{live_pid}'] = {
            'cwd': '/code/repo', 'project': f'repo [pid-{live_pid}]',
            'last_seen': time.time(),
        }
        with patch('asyncio.create_task'):
            client._register_session('real-session', '/code/repo', claude_pid=os.getpid())
        # Live pid-* session should be left alone (can't confirm dead)
        assert f'pid-{live_pid}' in client._sessions

    def test_picks_up_pending_tmux_target(self):
        client = make_client()
        client._pending_tmux_targets['/code/repo'] = '0:2'
        with patch('asyncio.create_task'):
            client._register_session('s1', '/code/repo')
        assert client._sessions['s1']['tmux_target'] == '0:2'
        assert '/code/repo' not in client._pending_tmux_targets


# ---------------------------------------------------------------------------
# _prune_dead_pid_sessions
# ---------------------------------------------------------------------------

class TestPruneDeadPidSessions:
    def test_removes_dead_sessions(self):
        client = make_client()
        client._sessions['pid-999999999'] = {
            'cwd': '/code', 'project': 'p', 'last_seen': time.time()
        }
        with patch('asyncio.create_task'):
            dead = client._prune_dead_pid_sessions()
        assert 'pid-999999999' in dead
        assert 'pid-999999999' not in client._sessions

    def test_keeps_live_sessions(self):
        client = make_client()
        live_sid = f'pid-{os.getpid()}'
        client._sessions[live_sid] = {
            'cwd': '/code', 'project': 'p', 'last_seen': time.time()
        }
        with patch('asyncio.create_task'):
            dead = client._prune_dead_pid_sessions()
        assert live_sid not in dead
        assert live_sid in client._sessions

    def test_keeps_real_sessions(self):
        client = make_client()
        client._sessions['real-abc123'] = {
            'cwd': '/code', 'project': 'p', 'last_seen': time.time()
        }
        with patch('asyncio.create_task'):
            dead = client._prune_dead_pid_sessions()
        assert 'real-abc123' not in dead


# ---------------------------------------------------------------------------
# _route_to_terminal — transport priority
# ---------------------------------------------------------------------------

class TestRouteToTerminal:
    def _make_client_with_session(self, tty='ttys009', tmux_target=None):
        client = make_client()
        entry = {'cwd': '/code/repo', 'project': 'repo', 'last_seen': time.time()}
        if tty:
            entry['tty'] = tty
        if tmux_target:
            entry['tmux_target'] = tmux_target
        client._sessions['s1'] = entry
        return client

    @pytest.mark.asyncio
    async def test_inject_tty_is_primary_for_tty_sessions(self):
        """inject_tty should be tried first for non-tmux sessions."""
        client = self._make_client_with_session(tty='ttys009')
        inject_result = {'ok': True}
        send_result = {'ok': True}

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('arguments', {}).get  # noqa
            tool = (params or {}).get('arguments', {}).get('session_id', '')
            tool_name = (params or {}).get('name') or (params or {}).get('arguments', {}).get('name', '')
            # Extract name from params['arguments']['name'] isn't right —
            # the call is tools/call with params={'name': ..., 'arguments': ...}
            tool_name = (params or {}).get('name', '')
            if tool_name == 'inject_tty':
                return inject_result
            if tool_name == 'send_text':
                return send_result
            return {}

        client._rpc = mock_rpc
        calls = []

        async def tracking_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            calls.append(name)
            if name == 'inject_tty':
                return {'ok': True}
            return {'ok': False}

        client._rpc = tracking_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert calls[0] == 'inject_tty'

    @pytest.mark.asyncio
    async def test_falls_back_to_send_text_when_inject_tty_fails(self):
        client = self._make_client_with_session(tty='ttys009')
        calls = []

        async def tracking_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            calls.append(name)
            if name == 'inject_tty':
                return {'ok': False}
            if name == 'send_text':
                return {'ok': True}
            return {'ok': False}

        client._rpc = tracking_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert 'inject_tty' in calls
        assert 'send_text' in calls
        assert calls.index('inject_tty') < calls.index('send_text')

    @pytest.mark.asyncio
    async def test_tmux_uses_send_text_not_inject_tty(self):
        """Tmux sessions should use send_text, not inject_tty."""
        client = self._make_client_with_session(tty=None, tmux_target='main:0.0')
        calls = []

        async def tracking_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            calls.append(name)
            if name == 'send_text':
                return {'ok': True}
            return {'ok': False}

        client._rpc = tracking_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert 'inject_tty' not in calls
        assert 'send_text' in calls

    @pytest.mark.asyncio
    async def test_capture_tty_response_scheduled_on_inject_success(self):
        """_capture_tty_response task must be scheduled when inject_tty succeeds."""
        client = self._make_client_with_session(tty='ttys009')

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        tasks_created = []
        with patch('asyncio.create_task', side_effect=lambda coro: tasks_created.append(coro)):
            await client._route_to_terminal_locked('s1', 'hello')

        # At least one task should be a _capture_tty_response coroutine
        coro_names = [getattr(t, '__name__', repr(t)) for t in tasks_created]
        assert any('capture_tty' in str(n) for n in coro_names)

    @pytest.mark.asyncio
    async def test_delivery_failure_notification_when_no_tty(self):
        """When no TTY can be found, an iOS notification block must be emitted."""
        client = make_client()
        # Session exists but has no tty, no tmux_target, no cwd
        client._sessions['s1'] = {
            'cwd': '', 'project': 'Test', 'last_seen': time.time()
        }
        notifications = []

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            # inject_tty and send_text fail
            if name in ('inject_tty', 'send_text'):
                raise Exception('not registered')
            # emit_block succeeds — capture it
            if name == 'emit_block':
                args = (params or {}).get('arguments', {})
                notifications.append(args)
                return {}
            return {}

        client._rpc = mock_rpc

        # Also mock list_terminal_sessions and _find_tty_for_cwd to return nothing
        client.list_terminal_sessions = AsyncMock(return_value=[])
        client._find_tty_for_cwd = AsyncMock(return_value=None)

        emitted_blocks = []
        original_emit = client.emit_block
        async def capture_emit(block_id, block_type, payload, **kwargs):
            emitted_blocks.append({'block_type': block_type, 'payload': payload})

        client.emit_block = capture_emit

        with patch('asyncio.create_task', side_effect=lambda coro: asyncio.ensure_future(coro)):
            await client._route_to_terminal_locked('s1', 'hello')

        # Allow scheduled tasks to run
        await asyncio.sleep(0)

        notification_blocks = [b for b in emitted_blocks if b['block_type'] == 'notification']
        assert len(notification_blocks) >= 1
        assert 'not delivered' in notification_blocks[0]['payload']['title'].lower()


# ---------------------------------------------------------------------------
# _capture_tty_response
# ---------------------------------------------------------------------------

class TestCaptureTtyResponse:
    @pytest.mark.asyncio
    async def test_emits_on_idle(self):
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code', 'project': 'repo', 'last_seen': time.time(),
            'tty': 'ttys009',
        }

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            if name == 'wait_for_idle':
                return {'idle': True, 'output': 'Claude response here'}
            return {}

        client._rpc = mock_rpc
        emitted = []
        client._emit_session_block = AsyncMock(side_effect=lambda sid, **kw: emitted.append(kw))

        with patch('asyncio.sleep', new_callable=AsyncMock):
            await client._capture_tty_response('s1')

        # Yield to the event loop so the create_task inside _capture_tty_response runs.
        await asyncio.sleep(0)

        assert len(emitted) == 1
        assert emitted[0]['last_message'] == 'Claude response here'

    @pytest.mark.asyncio
    async def test_no_emit_when_not_idle(self):
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code', 'project': 'repo', 'last_seen': time.time(),
        }

        async def mock_rpc(method, params=None, timeout=10.0):
            return {'idle': False, 'output': ''}

        client._rpc = mock_rpc
        client._emit_session_block = AsyncMock()

        with patch('asyncio.sleep', new_callable=AsyncMock):
            await client._capture_tty_response('s1')

        client._emit_session_block.assert_not_called()

    @pytest.mark.asyncio
    async def test_no_emit_when_output_empty(self):
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code', 'project': 'repo', 'last_seen': time.time(),
        }

        async def mock_rpc(method, params=None, timeout=10.0):
            return {'idle': True, 'output': ''}

        client._rpc = mock_rpc
        client._emit_session_block = AsyncMock()

        with patch('asyncio.sleep', new_callable=AsyncMock):
            await client._capture_tty_response('s1')

        client._emit_session_block.assert_not_called()

    @pytest.mark.asyncio
    async def test_handles_rpc_exception(self):
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code', 'project': 'repo', 'last_seen': time.time(),
        }

        async def mock_rpc(method, params=None, timeout=10.0):
            raise TimeoutError('timed out')

        client._rpc = mock_rpc
        client._emit_session_block = AsyncMock()

        with patch('asyncio.sleep', new_callable=AsyncMock):
            # Should not raise
            await client._capture_tty_response('s1')

        client._emit_session_block.assert_not_called()


# ---------------------------------------------------------------------------
# Concurrent reply serialization (per-session lock)
# ---------------------------------------------------------------------------

class TestConcurrentReplySerialization:
    @pytest.mark.asyncio
    async def test_concurrent_calls_are_ordered(self):
        """Two simultaneous route calls for the same session must not interleave."""
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code', 'project': 'repo', 'last_seen': time.time(),
            'tty': 'ttys009',
        }
        order = []

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                order.append(('start', (params or {}).get('arguments', {}).get('text')))
                await asyncio.sleep(0.02)   # simulate latency
                order.append(('end', (params or {}).get('arguments', {}).get('text')))
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        with patch('asyncio.create_task'):
            await asyncio.gather(
                client._route_to_terminal('s1', 'first'),
                client._route_to_terminal('s1', 'second'),
            )

        # start/end pairs must not interleave
        starts = [o for o in order if o[0] == 'start']
        ends = [o for o in order if o[0] == 'end']
        # First started must be first ended (serialized)
        assert starts[0][1] == ends[0][1]

    @pytest.mark.asyncio
    async def test_different_sessions_dont_block_each_other(self):
        """Routing to different sessions should run concurrently."""
        client = make_client()
        for sid in ('s1', 's2'):
            client._sessions[sid] = {
                'cwd': f'/code/{sid}', 'project': sid, 'last_seen': time.time(),
                'tty': f'ttys00{sid[-1]}',
            }

        start_times = {}
        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                sid = (params or {}).get('arguments', {}).get('session_id', '')
                start_times[sid] = asyncio.get_event_loop().time()
                await asyncio.sleep(0.05)
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        with patch('asyncio.create_task'):
            await asyncio.gather(
                client._route_to_terminal('s1', 'msg1'),
                client._route_to_terminal('s2', 'msg2'),
            )

        # Both should have started at nearly the same time (within 20ms)
        assert abs(start_times.get('s1', 0) - start_times.get('s2', 0)) < 0.02


# ---------------------------------------------------------------------------
# Dedup guard — prevents double/triple send from RPC timeout + retry
# ---------------------------------------------------------------------------

class TestDedupGuard:
    def _make_client_with_tty_session(self):
        client = make_client()
        client._sessions['s1'] = {
            'cwd': '/code/repo', 'project': 'repo',
            'last_seen': time.time(), 'tty': 'ttys009',
        }
        return client

    @pytest.mark.asyncio
    async def test_exact_duplicate_within_window_is_dropped(self):
        """Second call with same (session, text) within 5 s must not reach the terminal."""
        client = self._make_client_with_tty_session()
        send_count = 0

        async def mock_rpc(method, params=None, timeout=10.0):
            nonlocal send_count
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                send_count += 1
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')
            await client._route_to_terminal_locked('s1', 'hello')  # duplicate

        assert send_count == 1, f'Expected 1 send, got {send_count}'

    @pytest.mark.asyncio
    async def test_different_text_is_not_deduplicated(self):
        """Different text to the same session must both be delivered."""
        client = self._make_client_with_tty_session()
        sent_texts = []

        async def mock_rpc(method, params=None, timeout=10.0):
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                sent_texts.append((params or {}).get('arguments', {}).get('text', ''))
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')
            await client._route_to_terminal_locked('s1', 'world')

        assert sent_texts == ['hello', 'world']

    @pytest.mark.asyncio
    async def test_same_text_different_sessions_both_delivered(self):
        """Same text to different sessions must both be delivered."""
        client = make_client()
        for sid in ('s1', 's2'):
            client._sessions[sid] = {
                'cwd': f'/code/{sid}', 'project': sid,
                'last_seen': time.time(), 'tty': f'ttys00{sid[-1]}',
            }
        send_count = 0

        async def mock_rpc(method, params=None, timeout=10.0):
            nonlocal send_count
            if (params or {}).get('name') == 'inject_tty':
                send_count += 1
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')
            await client._route_to_terminal_locked('s2', 'hello')

        assert send_count == 2

    @pytest.mark.asyncio
    async def test_duplicate_allowed_after_window_expires(self):
        """Same text is allowed again once the 5 s dedup window has passed."""
        client = self._make_client_with_tty_session()
        send_count = 0

        async def mock_rpc(method, params=None, timeout=10.0):
            nonlocal send_count
            if (params or {}).get('name') == 'inject_tty':
                send_count += 1
                return {'ok': True}
            return {'ok': False}

        client._rpc = mock_rpc
        # Plant an entry that expired 6 s ago
        client._last_sent[('s1', 'hello')] = time.monotonic() - 6.0
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert send_count == 1

    @pytest.mark.asyncio
    async def test_slow_rpc_ghost_does_not_cause_double_send(self):
        """Simulate the ghost-execution bug: RPC times out in caller, but terminal-manager
        still completes the operation.  The dedup guard must absorb the retry send."""
        client = self._make_client_with_tty_session()
        send_count = 0

        async def slow_inject_rpc(method, params=None, timeout=10.0):
            nonlocal send_count
            name = (params or {}).get('name', '')
            if name == 'inject_tty':
                # Simulate ghost: operation executes but reply comes after timeout
                send_count += 1
                await asyncio.sleep(0.01)   # fast in test, but would be slow in prod
                return {'ok': True}
            return {'ok': False}

        client._rpc = slow_inject_rpc

        # First call: inject_tty succeeds → dedup key recorded
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert send_count == 1

        # Second call (retry after ghost timeout): must be absorbed by dedup guard
        with patch('asyncio.create_task'):
            await client._route_to_terminal_locked('s1', 'hello')

        assert send_count == 1, f'Dedup guard failed: {send_count} sends (expected 1)'
