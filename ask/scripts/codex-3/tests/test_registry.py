#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from registry import SessionRegistry, PendingPermission


def test_registry_resolves_existing_aliases():
    registry = SessionRegistry()
    session = registry.ensure(raw_id='raw-1', cwd='/tmp/ask', project='ask')
    assert registry.resolve(raw_id='raw-1') == session.session_id


def test_registry_merges_tmux_alias_into_existing_session():
    registry = SessionRegistry()
    session = registry.ensure(raw_id='raw-1', cwd='/tmp/ask', project='ask')
    same = registry.ensure(raw_id='raw-1', tmux_target='codex:ask.0', cwd='/tmp/ask')
    assert same.session_id == session.session_id
    assert registry.resolve(tmux_target='codex:ask.0') == session.session_id


def test_registry_uses_unique_cwd_match_only():
    registry = SessionRegistry()
    one = registry.ensure(raw_id='raw-1', cwd='/tmp/ask', project='ask')
    assert registry.resolve(cwd='/tmp/ask') == one.session_id
    registry.ensure(raw_id='raw-2', cwd='/tmp/ask', project='ask-2')
    assert registry.resolve(cwd='/tmp/ask') == ''


def test_pending_permission_round_trip():
    registry = SessionRegistry()
    session = registry.ensure(raw_id='raw-1', cwd='/tmp/ask', project='ask')
    session.pending_permission = PendingPermission(
        request_id='perm-1',
        tool='Bash',
        preview='git status',
        options=['Allow', 'Deny'],
        requested_at=1.0,
    )
    loaded = SessionRegistry.from_dict(registry.to_dict())
    assert loaded.sessions[session.session_id].pending_permission.request_id == 'perm-1'
