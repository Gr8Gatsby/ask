#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transport import _is_codex_pane


def test_detects_codex_from_start_command():
    assert _is_codex_pane('node', 'node ~/.nvm/versions/node/bin/codex', 'node')


def test_detects_codex_from_title():
    assert _is_codex_pane('node', '', 'node ~/.nvm/versions/node/bin/codex')


def test_ignores_unrelated_pane():
    assert not _is_codex_pane('zsh', 'zsh', 'shell')
