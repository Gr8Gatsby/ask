#!/usr/bin/env python3
"""
claude-3 transport utilities.

Synchronous helpers for: repo discovery, live process detection, TTY health
checks, and interactive terminal prompt parsing. Async terminal-manager routing
(inject_tty, send_text, send_interrupt, read_output) is handled directly in
main.py because those calls go through the MCP RPC loop.
"""
import os
import re
import subprocess
from typing import Optional


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


# ---------------------------------------------------------------------------
# Process discovery
# ---------------------------------------------------------------------------

def discover_claude_processes() -> list[dict]:
    """Scan running processes and return info about live Claude Code instances.

    Returns a list of dicts with keys: pid, tty, comm.
    Only processes with a real TTY are returned — headless/background
    processes cannot be routed to.
    """
    try:
        result = subprocess.run(
            ['ps', '-eo', 'pid,tty,comm'],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode != 0:
            return []
        processes = []
        for line in result.stdout.splitlines()[1:]:
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            pid_str, tty, comm = parts[0], parts[1], parts[2].strip()
            if tty in ('??', ''):
                continue
            if 'claude' not in comm.lower():
                continue
            try:
                pid = int(pid_str)
            except ValueError:
                continue
            processes.append({'pid': pid, 'tty': tty, 'comm': comm})
        return processes
    except Exception:
        return []


# ---------------------------------------------------------------------------
# TTY health
# ---------------------------------------------------------------------------

def tty_is_live(tty: str) -> bool:
    """Return True if the TTY device file still exists.

    tty may be a bare name like 's003' or a full path like '/dev/ttys003'.
    """
    if not tty:
        return False
    if tty.startswith('/dev/'):
        return os.path.exists(tty)
    # Try both macOS forms: ttys003 and s003
    return (
        os.path.exists(f'/dev/tty{tty}')
        or os.path.exists(f'/dev/{tty}')
    )


# ---------------------------------------------------------------------------
# Interactive terminal prompt detection
# ---------------------------------------------------------------------------

def parse_tmux_prompt(content: str) -> Optional[tuple[str, list[str], str]]:
    """Detect an interactive prompt in terminal output.

    Returns (body, options, reply_mode) or None if no prompt is found.
    reply_mode is one of: 'numbered', 'arrow', 'yn'.

    Claude Code's own idle UI strings are explicitly excluded so they are
    never surfaced as user-actionable prompts.
    """
    # Claude Code's own UI patterns — never treat these as prompts
    _CLAUDE_CODE_UI = [
        'accept edits on',
        'shift+tab to cycle',
        'esc to interrupt',
        'tab to interrupt',
    ]
    content_lower = content.lower()
    if any(p in content_lower for p in _CLAUDE_CODE_UI):
        return None

    lines = content.splitlines()

    # Format 1: Numbered menu (e.g. "1. Option") with a footer line
    option_re = re.compile(r'^\s*[>❯]?\s*(\d+)[.)]\s+(.+)$')
    footer_re = re.compile(r'press\s+enter|to\s+continue|to\s+confirm|esc\s+to', re.IGNORECASE)
    options_numbered: list[str] = []
    body_lines: list[str] = []
    found_options = False
    for line in lines:
        m = option_re.match(line)
        if m:
            found_options = True
            options_numbered.append(m.group(2).strip())
        elif not found_options:
            s = line.strip()
            if s and not re.match(r'^[$%#>]\s', s):
                body_lines.append(s)
    has_footer = any(footer_re.search(ln) for ln in lines)
    if len(options_numbered) >= 2 and has_footer:
        body = ' '.join(body_lines[-2:]) if body_lines else 'Choose an option'
        return body, options_numbered, 'numbered'

    # Format 2: Arrow-key menu (lines prefixed with ❯ or >)
    arrow_re = re.compile(r'^[❯>]\s+(.+)$')
    plain_re = re.compile(r'^\s{2,}(\S.+)$')
    arrow_options: list[str] = []
    in_menu = False
    menu_body_lines: list[str] = []
    for line in lines:
        ma = arrow_re.match(line.rstrip())
        if ma:
            in_menu = True
            arrow_options.append(ma.group(1).strip())
        elif in_menu:
            mp = plain_re.match(line.rstrip())
            if mp:
                arrow_options.append(mp.group(1).strip())
            elif line.strip():
                in_menu = False
        elif not in_menu and line.strip() and not re.match(r'^[$%#❯>]', line.strip()):
            menu_body_lines.append(line.strip())
    if len(arrow_options) >= 2:
        body = ' '.join(menu_body_lines[-2:]) if menu_body_lines else 'Choose an option'
        return body, arrow_options, 'arrow'

    # Format 3: y/n inline prompt
    yn_re = re.compile(r'(\(y[/\\]n\)|\[y[/\\]N\]|\[Y[/\\]n\])\s*[›>]?\s*$', re.IGNORECASE)
    for line in lines:
        m = yn_re.search(line)
        if m:
            return line.strip(), ['Yes', 'No'], 'yn'

    return None
