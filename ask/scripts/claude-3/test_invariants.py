#!/usr/bin/env python3
"""Invariants for claude-3's session registry. Locks the regressions we
keep hitting. Run with: python3 -m pytest ask/scripts/claude-3/test_invariants.py
or just: python3 ask/scripts/claude-3/test_invariants.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from registry import SessionRegistry


def test_cwd_stable_across_cli_restarts():
    """Same project directory → same session_id even with different raw_ids."""
    r = SessionRegistry()
    s1 = r.ensure(raw_id='UUID-A', tty='ttys001', cwd='/proj/foo')
    sid1 = s1.session_id
    r.remove(sid1)  # simulate run 1 ending
    s2 = r.ensure(raw_id='UUID-B', tty='ttys002', cwd='/proj/foo')
    assert s1.session_id == s2.session_id, \
        f'cwd-stable: expected same sid across restarts, got {sid1} vs {s2.session_id}'


def test_concurrent_sessions_in_same_cwd_get_different_sids():
    """Two live claude runs in the same cwd must not collide."""
    r = SessionRegistry()
    a = r.ensure(raw_id='UUID-A', tty='ttys001', cwd='/proj/foo')
    b = r.ensure(raw_id='UUID-B', tty='ttys002', cwd='/proj/foo')
    assert a.session_id != b.session_id, 'concurrent same-cwd sessions collided'


def test_hook_after_transient_discovery_merges():
    """If discovery creates a transient session by tty, a later hook with
    raw_id should bind to the same session, not create a new one."""
    r = SessionRegistry()
    transient = r.ensure(tty='ttys005', cwd='/proj/bar', is_transient=True)
    # Hook fires later with raw_id
    real = r.ensure(raw_id='UUID-X', tty='ttys005', cwd='/proj/bar')
    assert transient.session_id == real.session_id, \
        f'transient/hook merge failed: transient={transient.session_id} hook={real.session_id}'
    assert real.raw_id == 'UUID-X', 'raw_id should be backfilled from the hook'


def test_resolve_by_raw_id_alias():
    """A session created with raw_id must be resolvable by that raw_id."""
    r = SessionRegistry()
    s = r.ensure(raw_id='UUID-Z', tty='ttys009', cwd='/proj/baz')
    assert r.resolve(raw_id='UUID-Z') == s.session_id


def test_remove_purges_aliases():
    """After remove(), no alias should still resolve to the dead sid."""
    r = SessionRegistry()
    s = r.ensure(raw_id='UUID-Q', tty='ttys010', cwd='/proj/qux')
    sid = s.session_id
    r.remove(sid)
    assert r.resolve(raw_id='UUID-Q') == ''
    assert r.resolve(tty='ttys010') == ''
    # And the cwd-derived sid slot must be free for re-use
    s2 = r.ensure(raw_id='UUID-R', tty='ttys011', cwd='/proj/qux')
    assert s2.session_id == sid, 'cwd-derived sid should be reusable after remove'


def test_no_routing_session_persists():
    """A session with no tty and no tmux_target (e.g. the supervisor Claude)
    must not be auto-evicted just for lack of routing."""
    r = SessionRegistry()
    s = r.ensure(raw_id='UUID-NO-ROUTE')
    assert s.session_id in r.sessions
    # last_seen exists; nothing in the registry alone should remove it
    assert r.resolve(raw_id='UUID-NO-ROUTE') == s.session_id


if __name__ == '__main__':
    tests = [v for k, v in globals().items() if k.startswith('test_')]
    failed = 0
    for t in tests:
        try:
            t()
            print(f'  PASS  {t.__name__}')
        except AssertionError as e:
            print(f'  FAIL  {t.__name__}: {e}')
            failed += 1
    print()
    print(f'{len(tests)-failed}/{len(tests)} passed')
    sys.exit(1 if failed else 0)
