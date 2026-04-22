#!/usr/bin/env python3
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import transport
from transport import _is_codex_pane


def test_detects_codex_from_start_command():
    assert _is_codex_pane('node', 'node ~/.nvm/versions/node/bin/codex', 'node')


def test_detects_codex_from_title():
    assert _is_codex_pane('node', '', 'node ~/.nvm/versions/node/bin/codex')


def test_ignores_unrelated_pane():
    assert not _is_codex_pane('zsh', 'zsh', 'shell')


def test_send_text_types_and_submits(monkeypatch):
    calls = []

    def fake_run(args, **kwargs):
        calls.append(args)
        return SimpleNamespace(returncode=0, stdout="")

    monkeypatch.setattr(transport.subprocess, "run", fake_run)
    monkeypatch.setattr(transport.time, "sleep", lambda _: None)

    assert transport.send_text("codex:jokes.0", "What are we working on?")
    assert calls == [
        [transport.TMUX, 'send-keys', '-t', 'codex:jokes.0', '-l', 'What are we working on?'],
        [transport.TMUX, 'send-keys', '-t', 'codex:jokes.0', 'Enter'],
    ]
