#!/usr/bin/env python3
"""
test_unit.py — automated unit tests for terminal-manager.

Covers pure functions and async tool handlers (with mocked I/O).
Run with:  pytest ask/scripts/terminal-manager/test_unit.py -v
"""
import re
import sys
import os
import asyncio
import pytest
from unittest.mock import AsyncMock, patch, MagicMock

# Load main.py under a unique module name to avoid sys.modules collision with
# other scripts that also have a 'main' module when the full test suite runs.
# Register it in sys.modules as 'terminal_manager_main' so patch() targets work.
import importlib.util as _ilu

_saved_stdout = sys.stdout
_spec = _ilu.spec_from_file_location(
    'terminal_manager_main',
    os.path.join(os.path.dirname(__file__), 'main.py'),
)
tm = _ilu.module_from_spec(_spec)
sys.modules['terminal_manager_main'] = tm
_spec.loader.exec_module(tm)
sys.stdout = _saved_stdout


# ---------------------------------------------------------------------------
# _tty_to_full
# ---------------------------------------------------------------------------

class TestTtyToFull:
    def test_already_full_path(self):
        assert tm._tty_to_full('/dev/ttys009') == '/dev/ttys009'

    def test_ttys_prefix(self):
        assert tm._tty_to_full('ttys009') == '/dev/ttys009'

    def test_ttyp_prefix(self):
        assert tm._tty_to_full('ttyp0') == '/dev/ttyp0'

    def test_short_form(self):
        # e.g. 's009' from list_terminal_sessions
        assert tm._tty_to_full('s009') == '/dev/ttys009'

    def test_empty_string(self):
        # degenerate — shouldn't crash
        result = tm._tty_to_full('')
        assert result == '/dev/tty'


# ---------------------------------------------------------------------------
# _strip_ansi
# ---------------------------------------------------------------------------

class TestStripAnsi:
    def test_no_ansi(self):
        assert tm._strip_ansi('hello world') == 'hello world'

    def test_color_codes(self):
        assert tm._strip_ansi('\x1b[32mgreen\x1b[0m') == 'green'

    def test_cursor_movement(self):
        assert tm._strip_ansi('\x1b[2Khello\x1b[A') == 'hello'

    def test_osc_sequences(self):
        assert tm._strip_ansi('\x1b]0;window title\x07text') == 'text'

    def test_carriage_return(self):
        assert tm._strip_ansi('line\rtext') == 'linetext'

    def test_complex_claude_output(self):
        raw = '\x1b[1m\x1b[32mClaude\x1b[0m: Hello, how can I help?\n> '
        result = tm._strip_ansi(raw)
        assert 'Claude' in result
        assert '\x1b' not in result


# ---------------------------------------------------------------------------
# _tail_lines
# ---------------------------------------------------------------------------

class TestTailLines:
    def test_fewer_lines_than_limit(self):
        result = tm._tail_lines('a\nb\nc', 10)
        assert result == 'a\nb\nc'

    def test_exactly_limit(self):
        text = '\n'.join(str(i) for i in range(5))
        result = tm._tail_lines(text, 5)
        assert result == text

    def test_more_lines_than_limit(self):
        lines = [str(i) for i in range(20)]
        text = '\n'.join(lines)
        result = tm._tail_lines(text, 5)
        assert result == '\n'.join(lines[-5:])


# ---------------------------------------------------------------------------
# TerminalManager._extract_response
# ---------------------------------------------------------------------------

class TestExtractResponse:
    PROMPT_RE = re.compile(r'^\s*>\s*$')

    def _extract(self, content):
        return tm.TerminalManager._extract_response(content, self.PROMPT_RE)

    def test_simple_response(self):
        content = 'Hello, I can help you with that.\n\n> '
        result = self._extract(content)
        assert result == 'Hello, I can help you with that.'

    def test_multiple_lines(self):
        content = 'Line one\nLine two\nLine three\n> '
        result = self._extract(content)
        assert 'Line one' in result
        assert 'Line three' in result

    def test_strips_trailing_prompt(self):
        content = 'Response text\n> \n> '
        result = self._extract(content)
        assert '>' not in result

    def test_strips_decorative_separators(self):
        content = '─────────────\nActual response\n> '
        result = self._extract(content)
        assert '─' not in result
        assert 'Actual response' in result

    def test_empty_content(self):
        assert self._extract('') == ''

    def test_only_prompt(self):
        assert self._extract('> ') == ''

    def test_ansi_already_stripped(self):
        # _extract_response receives already-stripped content
        content = 'No ANSI here\n> '
        result = self._extract(content)
        assert result == 'No ANSI here'

    def test_long_response_truncated(self):
        # More than 40 lines — only the last 40 should be kept
        lines = [f'line {i}' for i in range(60)]
        content = '\n'.join(lines) + '\n> '
        result = self._extract(content)
        result_lines = result.splitlines()
        assert len(result_lines) <= 40
        assert 'line 59' in result   # last line preserved

    def test_response_capped_at_4000_chars(self):
        content = 'x' * 5000 + '\n> '
        result = self._extract(content)
        assert len(result) <= 4000


# ---------------------------------------------------------------------------
# Session type detection
# ---------------------------------------------------------------------------

class TestSessionType:
    def test_tmux_session_type(self):
        s = tm.Session('sid', 'app', tmux_target='main:0.0')
        assert s.session_type == 'tmux'

    def test_terminal_session_type(self):
        s = tm.Session('sid', 'app', tty='/dev/ttys009')
        assert s.session_type == 'terminal_app'

    def test_to_dict(self):
        s = tm.Session('abc', 'myapp', tty='/dev/ttys009')
        d = s.to_dict()
        assert d['session_id'] == 'abc'
        assert d['tty'] == '/dev/ttys009'
        assert d['type'] == 'terminal_app'


# ---------------------------------------------------------------------------
# TerminalManager._tool_register_session
# ---------------------------------------------------------------------------

class TestToolRegisterSession:
    @pytest.mark.asyncio
    async def test_register_tty_session(self):
        manager = tm.TerminalManager()
        result = await manager._tool_register_session({
            'session_id': 'sess1',
            'app_id': 'test',
            'tty': '/dev/ttys009',
        })
        assert result['ok'] is True
        assert result['session_id'] == 'sess1'
        assert result['type'] == 'terminal_app'
        assert 'sess1' in manager._sessions

    @pytest.mark.asyncio
    async def test_register_tmux_session(self):
        manager = tm.TerminalManager()
        result = await manager._tool_register_session({
            'session_id': 'sess2',
            'app_id': 'test',
            'tmux_target': 'main:0.0',
        })
        assert result['ok'] is True
        assert result['type'] == 'tmux'

    @pytest.mark.asyncio
    async def test_register_requires_tty_or_tmux(self):
        manager = tm.TerminalManager()
        with pytest.raises(ValueError, match='tty or tmux_target required'):
            await manager._tool_register_session({
                'session_id': 'sess3',
                'app_id': 'test',
            })

    @pytest.mark.asyncio
    async def test_register_replaces_existing(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 'sess1', 'app_id': 'test', 'tty': '/dev/ttys009',
        })
        # Re-register with a different TTY
        await manager._tool_register_session({
            'session_id': 'sess1', 'app_id': 'test', 'tty': '/dev/ttys010',
        })
        assert manager._sessions['sess1'].tty == '/dev/ttys010'


# ---------------------------------------------------------------------------
# TerminalManager._tool_unregister_session
# ---------------------------------------------------------------------------

class TestToolUnregisterSession:
    @pytest.mark.asyncio
    async def test_unregister_existing(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': '/dev/ttys009',
        })
        result = await manager._tool_unregister_session({'session_id': 's1'})
        assert result['ok'] is True
        assert result['removed'] is True
        assert 's1' not in manager._sessions

    @pytest.mark.asyncio
    async def test_unregister_nonexistent(self):
        manager = tm.TerminalManager()
        result = await manager._tool_unregister_session({'session_id': 'ghost'})
        assert result['ok'] is True
        assert result['removed'] is False


# ---------------------------------------------------------------------------
# TerminalManager._tool_inject_tty
# ---------------------------------------------------------------------------

class TestToolInjectTty:
    @pytest.mark.asyncio
    async def test_inject_tty_calls_terminal_inject(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        with patch('terminal_manager_main._terminal_inject_tty', new_callable=AsyncMock, return_value=True) as mock_inject:
            result = await manager._tool_inject_tty({'session_id': 's1', 'text': 'hello'})
        assert result['ok'] is True
        mock_inject.assert_called_once_with('ttys009', 'hello')

    @pytest.mark.asyncio
    async def test_inject_tty_delegates_to_tmux_for_tmux_session(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's2', 'app_id': 'test', 'tmux_target': 'main:0.0',
        })
        with patch('terminal_manager_main._tmux_send_text', new_callable=AsyncMock, return_value=True) as mock_tmux:
            result = await manager._tool_inject_tty({'session_id': 's2', 'text': 'hello'})
        assert result['ok'] is True
        mock_tmux.assert_called_once_with('main:0.0', 'hello')

    @pytest.mark.asyncio
    async def test_inject_tty_unknown_session(self):
        manager = tm.TerminalManager()
        with pytest.raises(ValueError, match='Unknown session'):
            await manager._tool_inject_tty({'session_id': 'ghost', 'text': 'hi'})

    @pytest.mark.asyncio
    async def test_inject_tty_propagates_failure(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's3', 'app_id': 'test', 'tty': 'ttys009',
        })
        with patch('terminal_manager_main._terminal_inject_tty', new_callable=AsyncMock, return_value=False):
            result = await manager._tool_inject_tty({'session_id': 's3', 'text': 'hi'})
        assert result['ok'] is False


# ---------------------------------------------------------------------------
# TerminalManager._tool_focus_window
# ---------------------------------------------------------------------------

class TestToolFocusWindow:
    @pytest.mark.asyncio
    async def test_focus_tty_session(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        with patch('terminal_manager_main._terminal_focus', new_callable=AsyncMock, return_value=True) as mock_focus:
            result = await manager._tool_focus_window({'session_id': 's1'})
        assert result['ok'] is True
        mock_focus.assert_called_once_with('ttys009')

    @pytest.mark.asyncio
    async def test_focus_tmux_session(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's2', 'app_id': 'test', 'tmux_target': 'main:1.0',
        })
        mock_proc = MagicMock()
        mock_proc.wait = AsyncMock(return_value=0)
        with patch('asyncio.create_subprocess_exec', new_callable=AsyncMock, return_value=mock_proc):
            result = await manager._tool_focus_window({'session_id': 's2'})
        assert result['ok'] is True

    @pytest.mark.asyncio
    async def test_focus_unknown_session(self):
        manager = tm.TerminalManager()
        with pytest.raises(ValueError, match='Unknown session'):
            await manager._tool_focus_window({'session_id': 'ghost'})


# ---------------------------------------------------------------------------
# TerminalManager._tool_wait_for_idle
# ---------------------------------------------------------------------------

class TestToolWaitForIdle:
    @pytest.mark.asyncio
    async def test_detects_idle_prompt(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        idle_content = 'Here is my response.\n> '
        # Return same content twice so stable_count reaches 2
        manager._read = AsyncMock(return_value=idle_content)
        result = await manager._tool_wait_for_idle({
            'session_id': 's1', 'timeout': 5, 'poll_interval': 0.01, 'stable_count': 2,
        })
        assert result['idle'] is True
        assert 'Here is my response' in result['output']

    @pytest.mark.asyncio
    async def test_not_stable_until_consistent(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        # Alternate between two different idle contents — should never stabilize
        contents = ['Response A\n> ', 'Response B\n> ']
        call_count = 0
        async def alternating_read(session, lines):
            nonlocal call_count
            call_count += 1
            return contents[call_count % 2]
        manager._read = alternating_read
        result = await manager._tool_wait_for_idle({
            'session_id': 's1', 'timeout': 0.1, 'poll_interval': 0.01, 'stable_count': 2,
        })
        assert result['idle'] is False

    @pytest.mark.asyncio
    async def test_times_out_when_not_idle(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        # Content never has the idle prompt
        manager._read = AsyncMock(return_value='Still working...')
        result = await manager._tool_wait_for_idle({
            'session_id': 's1', 'timeout': 0.05, 'poll_interval': 0.01,
        })
        assert result['idle'] is False
        assert result['output'] == ''

    @pytest.mark.asyncio
    async def test_unknown_session_raises(self):
        manager = tm.TerminalManager()
        with pytest.raises(ValueError, match='Unknown session'):
            await manager._tool_wait_for_idle({'session_id': 'ghost', 'timeout': 1})

    @pytest.mark.asyncio
    async def test_custom_prompt_pattern(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009',
        })
        # Custom prompt: bash $ prompt
        content = 'Done with task\n$ '
        manager._read = AsyncMock(return_value=content)
        result = await manager._tool_wait_for_idle({
            'session_id': 's1',
            'timeout': 5,
            'prompt_pattern': r'^\s*\$\s*$',
            'poll_interval': 0.01,
            'stable_count': 2,
        })
        assert result['idle'] is True
        assert 'Done with task' in result['output']


# ---------------------------------------------------------------------------
# TerminalManager._tool_list_sessions
# ---------------------------------------------------------------------------

class TestToolListSessions:
    @pytest.mark.asyncio
    async def test_empty(self):
        manager = tm.TerminalManager()
        result = await manager._tool_list_sessions({})
        assert result['sessions'] == []

    @pytest.mark.asyncio
    async def test_lists_registered(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session({
            'session_id': 's1', 'app_id': 'test', 'tty': '/dev/ttys009',
        })
        await manager._tool_register_session({
            'session_id': 's2', 'app_id': 'test', 'tmux_target': 'main:0.0',
        })
        result = await manager._tool_list_sessions({})
        ids = {s['session_id'] for s in result['sessions']}
        assert ids == {'s1', 's2'}


# ---------------------------------------------------------------------------
# _as_applescript_str
# ---------------------------------------------------------------------------

class TestAsApplescriptStr:
    def test_plain_ascii(self):
        result = tm._as_applescript_str('hello')
        assert result == '"hello"'

    def test_empty_string(self):
        assert tm._as_applescript_str('') == '""'

    def test_double_quote_escaped(self):
        result = tm._as_applescript_str('say "hi"')
        assert '(ASCII character 34)' in result
        assert '"say ' in result

    def test_non_printable_esc(self):
        result = tm._as_applescript_str('\x1b[B')
        assert '(ASCII character 27)' in result

    def test_escape_arrow_sequence(self):
        # ESC[B ESC[B — two down arrows
        result = tm._as_applescript_str('\x1b[B\x1b[B')
        assert result.count('(ASCII character 27)') == 2

    def test_backslash_escaped(self):
        result = tm._as_applescript_str('a\\b')
        assert '(ASCII character 92)' in result


# ---------------------------------------------------------------------------
# Multi-terminal dispatch: inject_tty
# ---------------------------------------------------------------------------

class TestMultiTerminalInjectTty:
    async def _register(self, manager, sid, tty, terminal_app):
        """Register a session with a pre-set terminal_app, bypassing detection."""
        with patch('terminal_manager_main._detect_terminal_for_tty',
                   new_callable=AsyncMock, return_value=terminal_app):
            await manager._tool_register_session(
                {'session_id': sid, 'app_id': 'test', 'tty': tty}
            )

    @pytest.mark.asyncio
    async def test_iterm2_routes_to_iterm2_inject(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'iTerm2')
        with patch('terminal_manager_main._iterm2_inject_tty',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_inject_tty({'session_id': 's1', 'text': 'hi'})
        assert result['ok'] is True
        mock.assert_called_once()

    @pytest.mark.asyncio
    async def test_terminal_app_routes_to_terminal_inject(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Terminal')
        with patch('terminal_manager_main._terminal_inject_tty',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_inject_tty({'session_id': 's1', 'text': 'hi'})
        assert result['ok'] is True
        mock.assert_called_once()

    @pytest.mark.asyncio
    async def test_ghostty_returns_false_no_native_inject(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Ghostty')
        result = await manager._tool_inject_tty({'session_id': 's1', 'text': 'hi'})
        assert result['ok'] is False

    @pytest.mark.asyncio
    async def test_warp_returns_false_no_native_inject(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Warp')
        result = await manager._tool_inject_tty({'session_id': 's1', 'text': 'hi'})
        assert result['ok'] is False


# ---------------------------------------------------------------------------
# Multi-terminal dispatch: send_text
# ---------------------------------------------------------------------------

class TestMultiTerminalSendText:
    async def _register(self, manager, sid, tty, terminal_app):
        with patch('terminal_manager_main._detect_terminal_for_tty',
                   new_callable=AsyncMock, return_value=terminal_app):
            await manager._tool_register_session(
                {'session_id': sid, 'app_id': 'test', 'tty': tty}
            )

    @pytest.mark.asyncio
    async def test_iterm2_routes_to_iterm2_send_text(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'iTerm2')
        with patch('terminal_manager_main._iterm2_send_text',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_send_text({'session_id': 's1', 'text': 'hello'})
        assert result['ok'] is True
        mock.assert_called_once_with('ttys009', 'hello')

    @pytest.mark.asyncio
    async def test_terminal_routes_to_terminal_send_text(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Terminal')
        with patch('terminal_manager_main._terminal_send_text',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_send_text({'session_id': 's1', 'text': 'hello'})
        assert result['ok'] is True
        mock.assert_called_once_with('ttys009', 'hello')

    @pytest.mark.asyncio
    async def test_ghostty_routes_to_generic_send_text(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Ghostty')
        with patch('terminal_manager_main._generic_send_text',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_send_text({'session_id': 's1', 'text': 'hello'})
        assert result['ok'] is True
        mock.assert_called_once_with('Ghostty', 'hello')

    @pytest.mark.asyncio
    async def test_warp_routes_to_generic_send_text(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Warp')
        with patch('terminal_manager_main._generic_send_text',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_send_text({'session_id': 's1', 'text': 'hello'})
        assert result['ok'] is True
        mock.assert_called_once_with('Warp', 'hello')


# ---------------------------------------------------------------------------
# Multi-terminal dispatch: focus_window
# ---------------------------------------------------------------------------

class TestMultiTerminalFocusWindow:
    async def _register(self, manager, sid, tty, terminal_app):
        with patch('terminal_manager_main._detect_terminal_for_tty',
                   new_callable=AsyncMock, return_value=terminal_app):
            await manager._tool_register_session(
                {'session_id': sid, 'app_id': 'test', 'tty': tty}
            )

    @pytest.mark.asyncio
    async def test_iterm2_routes_to_iterm2_focus(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'iTerm2')
        with patch('terminal_manager_main._iterm2_focus',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_focus_window({'session_id': 's1'})
        assert result['ok'] is True
        mock.assert_called_once_with('ttys009')

    @pytest.mark.asyncio
    async def test_ghostty_routes_to_generic_focus(self):
        manager = tm.TerminalManager()
        await self._register(manager, 's1', 'ttys009', 'Ghostty')
        with patch('terminal_manager_main._generic_focus',
                   new_callable=AsyncMock, return_value=True) as mock:
            result = await manager._tool_focus_window({'session_id': 's1'})
        assert result['ok'] is True
        mock.assert_called_once_with('Ghostty')


# ---------------------------------------------------------------------------
# terminal_app stored on session and included in to_dict
# ---------------------------------------------------------------------------

class TestSessionTerminalApp:
    @pytest.mark.asyncio
    async def test_terminal_app_stored_on_session(self):
        manager = tm.TerminalManager()
        with patch('terminal_manager_main._detect_terminal_for_tty',
                   new_callable=AsyncMock, return_value='iTerm2'):
            await manager._tool_register_session(
                {'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009'}
            )
        assert manager._sessions['s1'].terminal_app == 'iTerm2'

    @pytest.mark.asyncio
    async def test_terminal_app_in_to_dict(self):
        manager = tm.TerminalManager()
        with patch('terminal_manager_main._detect_terminal_for_tty',
                   new_callable=AsyncMock, return_value='Ghostty'):
            await manager._tool_register_session(
                {'session_id': 's1', 'app_id': 'test', 'tty': 'ttys009'}
            )
        result = await manager._tool_list_sessions({})
        session = result['sessions'][0]
        assert session['terminal_app'] == 'Ghostty'

    @pytest.mark.asyncio
    async def test_tmux_session_has_no_terminal_app(self):
        manager = tm.TerminalManager()
        await manager._tool_register_session(
            {'session_id': 's1', 'app_id': 'test', 'tmux_target': 'main:0.0'}
        )
        assert manager._sessions['s1'].terminal_app == ''
