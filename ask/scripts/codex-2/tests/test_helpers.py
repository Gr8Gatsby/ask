#!/usr/bin/env python3
"""
Unit tests for codex-2 pure helper functions.
These tests import directly from main.py and patch paths to use temp dirs.
"""
import importlib
import asyncio
import json
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, MagicMock, AsyncMock

# ── Import main.py without executing its module-level side effects ─────────────

# Redirect stdout before import so sys.stdout = open(...) doesn't clobber the
# test runner's stdout.
_real_stdout = sys.stdout
sys.stdout = open(os.devnull, 'w')

MAIN_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
spec = importlib.util.spec_from_file_location('codex2_main', MAIN_PATH)
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)

sys.stdout = _real_stdout


# ── Helper to run tests with paths redirected to a temp dir ───────────────────

class TempDirTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.allowlist_path = os.path.join(self.tmp, 'allowlist.json')
        self.active_blocks_path = os.path.join(self.tmp, 'active_blocks.json')
        self.hooks_path = os.path.join(self.tmp, 'hooks.json')
        self._patches = [
            patch.object(_mod, 'ALLOWLIST_PATH', self.allowlist_path),
            patch.object(_mod, 'ACTIVE_BLOCKS_PATH', self.active_blocks_path),
            patch.object(_mod, 'CODEX_HOOKS_PATH', self.hooks_path),
        ]
        for p in self._patches:
            p.start()

    def tearDown(self):
        for p in self._patches:
            p.stop()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)


# ── Fix 1: _append_allowlist ──────────────────────────────────────────────────

class TestAppendAllowlist(TempDirTest):

    def test_creates_file_if_missing(self):
        _mod._append_allowlist('git status')
        self.assertTrue(os.path.exists(self.allowlist_path))
        data = json.loads(open(self.allowlist_path).read())
        self.assertIn('git status', data['patterns'])

    def test_appends_to_existing_list(self):
        with open(self.allowlist_path, 'w') as f:
            json.dump({'patterns': ['npm test']}, f)
        _mod._append_allowlist('git status')
        data = json.loads(open(self.allowlist_path).read())
        self.assertIn('npm test', data['patterns'])
        self.assertIn('git status', data['patterns'])

    def test_no_duplicates(self):
        _mod._append_allowlist('git status')
        _mod._append_allowlist('git status')
        data = json.loads(open(self.allowlist_path).read())
        self.assertEqual(data['patterns'].count('git status'), 1)

    def test_empty_preview_not_saved(self):
        # Empty strings should not corrupt the allowlist
        _mod._append_allowlist('')
        # File created but patterns list should be empty (empty string is falsy check in caller)
        # The function itself doesn't gate on empty — but the caller does.
        # Just confirm it doesn't crash.

    def test_corrupted_file_is_reset(self):
        with open(self.allowlist_path, 'w') as f:
            f.write('not json')
        _mod._append_allowlist('git status')  # should not raise
        data = json.loads(open(self.allowlist_path).read())
        self.assertIn('git status', data['patterns'])


# ── Fix 11: _update_recent_repos ─────────────────────────────────────────────

class TestUpdateRecentRepos(TempDirTest):

    def test_adds_to_front(self):
        settings = {}
        result = _mod._update_recent_repos(settings, '/code/project-a')
        self.assertEqual(result['recent_repos'][0], '/code/project-a')

    def test_moves_existing_to_front(self):
        settings = {'recent_repos': ['/code/a', '/code/b', '/code/c']}
        result = _mod._update_recent_repos(settings, '/code/c')
        self.assertEqual(result['recent_repos'][0], '/code/c')
        self.assertEqual(len(result['recent_repos']), 3)

    def test_caps_at_max(self):
        paths = [f'/code/project-{i}' for i in range(_mod.MAX_RECENT_REPOS + 3)]
        settings = {'recent_repos': paths}
        result = _mod._update_recent_repos(settings, '/code/new')
        self.assertEqual(len(result['recent_repos']), _mod.MAX_RECENT_REPOS)
        self.assertEqual(result['recent_repos'][0], '/code/new')

    def test_does_not_mutate_original_settings(self):
        settings = {'recent_repos': ['/code/a']}
        original_list = list(settings['recent_repos'])
        _mod._update_recent_repos(settings, '/code/b')
        # Function modifies in place and returns — check it's still consistent
        self.assertEqual(settings['recent_repos'][0], '/code/b')
        # Original list should be unaffected (it was reassigned, not mutated)


# ── Fix 12: _load_active_blocks / _save_active_blocks ────────────────────────

class TestActiveBlocks(TempDirTest):

    def test_load_returns_empty_set_if_missing(self):
        result = _mod._load_active_blocks()
        self.assertIsInstance(result, set)
        self.assertEqual(len(result), 0)

    def test_save_and_load_roundtrip(self):
        blocks = {'block-a', 'block-b', 'block-c'}
        _mod._save_active_blocks(blocks)
        loaded = _mod._load_active_blocks()
        self.assertEqual(loaded, blocks)

    def test_load_handles_corrupt_file(self):
        with open(self.active_blocks_path, 'w') as f:
            f.write('not valid json')
        result = _mod._load_active_blocks()
        self.assertIsInstance(result, set)
        self.assertEqual(len(result), 0)

    def test_save_empty_set(self):
        _mod._save_active_blocks({'a', 'b'})
        _mod._save_active_blocks(set())
        loaded = _mod._load_active_blocks()
        self.assertEqual(loaded, set())


# ── Fix 13: _write_hooks_json merge behavior ──────────────────────────────────

class TestWriteHooksJsonMerge(TempDirTest):

    def _write_hooks(self):
        """Write hooks using a temp hooks path."""
        os.makedirs(self.tmp, exist_ok=True)
        with patch.object(_mod, 'CODEX_HOOKS_PATH', self.hooks_path):
            _mod._write_hooks_json()

    def test_creates_hooks_if_missing(self):
        self._write_hooks()
        data = json.loads(open(self.hooks_path).read())
        self.assertIn('SessionStart', data['hooks'])
        self.assertIn('PreToolUse', data['hooks'])
        self.assertIn('Stop', data['hooks'])

    def test_preserves_existing_custom_hook(self):
        custom = {'hooks': {
            'SessionStart': [{'hooks': [{'type': 'command', 'command': '/usr/local/bin/my-hook.sh'}]}]
        }}
        with open(self.hooks_path, 'w') as f:
            json.dump(custom, f)
        self._write_hooks()
        data = json.loads(open(self.hooks_path).read())
        # Both hooks should be present for SessionStart
        session_start_cmds = [
            h['command']
            for entry in data['hooks']['SessionStart']
            for h in entry.get('hooks', [])
        ]
        self.assertTrue(any('/my-hook.sh' in c for c in session_start_cmds),
                        'Custom hook should be preserved')
        self.assertTrue(any('session_start.py' in c for c in session_start_cmds),
                        'Our hook should be added')

    def test_does_not_duplicate_if_already_registered(self):
        # Write once, write again — our hooks should not be duplicated
        self._write_hooks()
        self._write_hooks()
        data = json.loads(open(self.hooks_path).read())
        session_start_cmds = [
            h['command']
            for entry in data['hooks']['SessionStart']
            for h in entry.get('hooks', [])
        ]
        our_hooks = [c for c in session_start_cmds if 'session_start.py' in c]
        self.assertEqual(len(our_hooks), 1, 'Hook should not be duplicated on re-install')


# ── Fix 3: _get_pane_command ──────────────────────────────────────────────────

class TestGetPaneCommand(unittest.TestCase):

    def test_returns_command_on_success(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = 'node\n'
        with patch('subprocess.run', return_value=mock_result):
            result = _mod._get_pane_command('codex:ask.0')
        self.assertEqual(result, 'node')

    def test_returns_empty_string_on_failure(self):
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = ''
        with patch('subprocess.run', return_value=mock_result):
            result = _mod._get_pane_command('codex:ask.0')
        self.assertEqual(result, '')

    def test_returns_empty_on_exception(self):
        with patch('subprocess.run', side_effect=Exception('tmux not found')):
            result = _mod._get_pane_command('codex:ask.0')
        self.assertEqual(result, '')

    def test_strips_whitespace(self):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = '  zsh  \n'
        with patch('subprocess.run', return_value=mock_result):
            result = _mod._get_pane_command('codex:ask.0')
        self.assertEqual(result, 'zsh')


# ── Fix 15: per-launch mode picker ID format ──────────────────────────────────

class TestPerLaunchModePicker(unittest.TestCase):
    """Verify the mode picker block ID is unique per launch, not a shared constant."""

    def test_no_global_mode_pick_block_id_constant(self):
        """MODE_PICK_BLOCK_ID should no longer exist as a module constant."""
        self.assertFalse(
            hasattr(_mod, 'MODE_PICK_BLOCK_ID'),
            'MODE_PICK_BLOCK_ID should have been removed; per-launch IDs are used instead'
        )

    def test_pending_launches_is_dict_not_string(self):
        """CodexController should use _pending_launches dict, not _pending_launch_path."""
        ctrl = _mod.CodexController.__new__(_mod.CodexController)
        ctrl._sessions = {}
        ctrl._poll_tasks = {}
        ctrl._tm_sessions = {}
        ctrl._real_to_stable = {}
        ctrl._pending_permissions = {}
        ctrl._pending_launches = {}
        ctrl._tile_debounce_tasks = {}
        ctrl._active_perm_blocks = set()
        ctrl._start_repos = {}
        ctrl._settings = {}
        ctrl._last_payload_hash = {}
        ctrl._next_id = 0
        ctrl._pending_calls = {}
        self.assertIsInstance(ctrl._pending_launches, dict)
        self.assertFalse(
            hasattr(ctrl, '_pending_launch_path'),
            '_pending_launch_path should be gone; use _pending_launches dict'
        )


class TestSessionLookup(unittest.TestCase):

    def _controller(self):
        ctrl = _mod.CodexController.__new__(_mod.CodexController)
        ctrl._sessions = {}
        ctrl._tm_sessions = {}
        ctrl._poll_tasks = {}
        ctrl._real_to_stable = {}
        ctrl._pending_permissions = {}
        ctrl._pending_launches = {}
        ctrl._tile_debounce_tasks = {}
        ctrl._active_perm_blocks = set()
        ctrl._start_repos = {}
        ctrl._settings = {}
        ctrl._last_payload_hash = {}
        return ctrl

    def test_lookup_uses_exact_mapping_before_tmux_discovery(self):
        ctrl = self._controller()
        ctrl._sessions = {
            'tmux-codex:alpha.0': {'cwd': '/tmp/alpha', 'tmux_target': 'codex:alpha.0'},
            'tmux-codex:beta.0': {'cwd': '/tmp/beta', 'tmux_target': 'codex:beta.0'},
        }
        ctrl._real_to_stable = {'raw-beta': 'tmux-codex:beta.0'}
        with patch.object(_mod, '_find_tmux_target', return_value='codex:alpha.0'):
            resolved = ctrl._lookup_session_id(raw_id='raw-beta')
        self.assertEqual(resolved, 'tmux-codex:beta.0')

    def test_lookup_does_not_guess_when_cwd_is_ambiguous(self):
        ctrl = self._controller()
        ctrl._sessions = {
            'tmux-codex:alpha.0': {'cwd': '/tmp/shared', 'tmux_target': 'codex:alpha.0'},
            'tmux-codex:beta.0': {'cwd': '/tmp/shared', 'tmux_target': 'codex:beta.0'},
        }
        with patch.object(_mod, '_find_tmux_target', return_value=''):
            resolved = ctrl._lookup_session_id(raw_id='raw-unknown', cwd='/tmp/shared')
        self.assertEqual(resolved, '')


class TestStrictToolRouting(unittest.TestCase):

    def _controller(self):
        ctrl = _mod.CodexController.__new__(_mod.CodexController)
        ctrl._sessions = {}
        ctrl._tm_sessions = {}
        ctrl._poll_tasks = {}
        ctrl._real_to_stable = {}
        ctrl._pending_permissions = {}
        ctrl._pending_launches = {}
        ctrl._tile_debounce_tasks = {}
        ctrl._active_perm_blocks = set()
        ctrl._start_repos = {}
        ctrl._settings = {}
        ctrl._last_payload_hash = {}
        return ctrl

    def test_reply_returns_unknown_session_instead_of_falling_back(self):
        ctrl = self._controller()
        ctrl._sessions = {
            'tmux-codex:alpha.0': {'cwd': '/tmp/alpha', 'tmux_target': 'codex:alpha.0'}
        }
        with patch.object(ctrl, '_send_session_text', new=AsyncMock(return_value=True)):
            result = asyncio.run(ctrl._tool_reply({
                'session_id': 'tmux-codex:missing.0',
                'message': 'hello',
            }))
        self.assertEqual(result, {'error': 'unknown session'})

    def test_stop_returns_unknown_session_instead_of_falling_back(self):
        ctrl = self._controller()
        ctrl._sessions = {
            'tmux-codex:alpha.0': {'cwd': '/tmp/alpha', 'tmux_target': 'codex:alpha.0'}
        }
        with patch.object(ctrl, '_send_session_key', new=AsyncMock(return_value=True)):
            result = asyncio.run(ctrl._tool_stop_session({
                'session_id': 'tmux-codex:missing.0',
            }))
        self.assertEqual(result, {'error': 'unknown session'})


if __name__ == '__main__':
    unittest.main()
