#!/usr/bin/env python3
"""
claude-3 transport utilities.

Repo discovery helper. Terminal session management is handled by terminal-manager
via MCP; see main.py for the async routing calls.
"""
import os


REPO_SEARCH_DIRS = [
    os.path.expanduser('~/Documents/code'),
    os.path.expanduser('~/code'),
    os.path.expanduser('~/projects'),
    os.path.expanduser('~/Developer'),
]


# ---------------------------------------------------------------------------
# Repo discovery
# ---------------------------------------------------------------------------

def find_repos() -> list[tuple[str, str]]:
    """Return (name, path) pairs for git repos found in known search dirs."""
    repos = []
    seen: set[str] = set()
    for base in REPO_SEARCH_DIRS:
        if not os.path.isdir(base):
            continue
        try:
            for name in sorted(os.listdir(base)):
                path = os.path.join(base, name)
                if path in seen:
                    continue
                if os.path.isdir(os.path.join(path, '.git')):
                    seen.add(path)
                    repos.append((name, path))
        except Exception:
            pass
    return repos
