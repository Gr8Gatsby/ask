#!/usr/bin/env python3
"""
terminal-manager — system script providing generic terminal session management
and TUI detection as MCP tools for other scripts.

Protocol: JSON-RPC 2.0 over stdin/stdout (same as all Ask scripts).
System type: tools contributed to AskMac MCP namespace, not surfaced to iPhone.

Each line on stdin is a JSON-RPC message. Responses go to stdout.
Debug output (what's detected, what actions are taken) goes to stderr and log.
"""

from __future__ import annotations

import sys
import json
import asyncio
import os
import re
import subprocess
import datetime
import tempfile
import base64
import time as _time

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

LOG_PATH = os.path.expanduser('~/.ask/logs/terminal-manager.log')

# Resolve tmux at startup — Homebrew installs to /opt/homebrew/bin which isn't
# in AskMac's restricted PATH.
def _find_tmux_bin() -> str:
    for p in ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']:
        if os.path.isfile(p):
            return p
    return 'tmux'

TMUX = _find_tmux_bin()

ANSI_RE = re.compile(
    r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]'
    r'|\x1b[()][AB012]'
    r'|\x1b\][^\x07]*\x07'
    r'|\r'
)

# Named key → (Terminal.app key code, tmux key name)
KEY_MAP = {
    'up':      (126, 'Up'),
    'down':    (125, 'Down'),
    'left':    (123, 'Left'),
    'right':   (124, 'Right'),
    'enter':   (36,  'Enter'),
    'escape':  (53,  'Escape'),
    'space':   (49,  'Space'),
    'tab':     (48,  'Tab'),
    'ctrl_c':  (None, 'C-c'),
    'ctrl_u':  (None, 'C-u'),
}

# Terminal apps we know how to address by name, in detection priority order
TERMINAL_APP_NAMES = ['Terminal', 'iTerm2', 'Ghostty', 'Warp', 'Alacritty', 'WezTerm', 'kitty', 'Hyper']


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(msg: str, level: str = 'INFO'):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] [{level}] {msg}'
    print(line, file=sys.stderr, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


def _dbg(msg: str):
    _log(msg, 'DEBUG')


# ---------------------------------------------------------------------------
# AppleScript helpers
# ---------------------------------------------------------------------------

def _as_applescript_str(s: str) -> str:
    """Convert a Python string to an AppleScript string expression, escaping non-ASCII chars."""
    if not s:
        return '""'
    parts, buf = [], ''
    for ch in s:
        code = ord(ch)
        if 32 <= code <= 126 and ch not in ('"', '\\'):
            buf += ch
        else:
            if buf:
                parts.append(f'"{buf}"')
                buf = ''
            parts.append(f'(ASCII character {code})')
    if buf:
        parts.append(f'"{buf}"')
    return ' & '.join(parts) if parts else '""'


# ---------------------------------------------------------------------------
# Terminal app detection
# ---------------------------------------------------------------------------

async def _detect_terminal_for_tty(tty: str) -> str:
    """Walk the process tree for the TTY to find which terminal app owns it.

    Returns a name from TERMINAL_APP_NAMES (e.g. 'Terminal', 'iTerm2') or 'unknown'.
    """
    short = tty.replace('/dev/', '')
    try:
        proc = await asyncio.create_subprocess_exec(
            'ps', '-t', short, '-o', 'pid=',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
        pids = [int(x) for x in stdout.decode().split() if x.strip().isdigit()]
    except Exception as e:
        _log(f'_detect_terminal_for_tty ps failed: {e}', 'WARN')
        return 'unknown'

    checked: set = set()
    to_check = list(pids)
    while to_check:
        pid = to_check.pop(0)
        if pid in checked or pid <= 1:
            continue
        checked.add(pid)
        if len(checked) > 40:
            break
        try:
            # Use 'pid=,ppid=,command=' — 'comm=' truncates long paths on macOS
            r = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'pid=,ppid=,command='],
                capture_output=True, text=True, timeout=1,
            )
            line = r.stdout.strip()
            if not line:
                continue
            parts = line.split(None, 2)  # [pid, ppid, command]
            if len(parts) < 3:
                continue
            comm = parts[2].split('/')[-1].split()[0]  # basename, drop args
            ppid = int(parts[1]) if parts[1].isdigit() else 0
            for app in TERMINAL_APP_NAMES:
                if comm.lower() == app.lower() or comm.lower().startswith(app.lower()):
                    _dbg(f'  [detect_terminal] tty={tty} → {app} (pid={pid} comm={comm!r})')
                    return app
            if ppid > 1:
                to_check.append(ppid)
        except Exception:
            pass

    _dbg(f'  [detect_terminal] tty={tty} → unknown (checked {len(checked)} pids)')
    return 'unknown'


# ---------------------------------------------------------------------------
# TUI Detectors
# ---------------------------------------------------------------------------

def _strip_ansi(text: str) -> str:
    return ANSI_RE.sub('', text)


def _tail_lines(text: str, n: int) -> str:
    """Return the last n lines of text."""
    lines = text.splitlines()
    if len(lines) > n:
        lines = lines[-n:]
    return '\n'.join(lines)


def detect_numbered_menu(text: str, params: dict) -> object:
    """
    Detects: ›N. Option list with a configurable footer line.

    params:
      footer  — string that must be present (e.g. 'Press enter to confirm')
      footers — list of strings, any one must be present (alternative to footer)
    """
    footers = params.get('footers') or []
    if single := params.get('footer'):
        footers = [single] + footers
    if not footers:
        footers = ['Press enter to confirm', 'esc to go back']

    if not any(f in text for f in footers):
        return None

    option_re = re.compile(r'^([›>\s]*)\d+\.\s+(.+)$', re.MULTILINE)
    options = []
    current_idx = 0
    for m in option_re.finditer(text):
        prefix = m.group(1)
        rest = m.group(2).strip()
        label = re.split(r'\s{2,}', rest, maxsplit=1)[0].strip()
        label = label.replace(' (current)', '').strip()
        if not label:
            continue
        if '›' in prefix or '>' in prefix:
            current_idx = options.index(label) if label in options else len(options)
        if label not in options:
            options.append(label)

    if len(options) < 2:
        return None

    # Title: bracketed box or nearest non-option line above first option
    box_re = re.compile(r'\[\s+(.+?)\s*\]')
    option_line_re = re.compile(r'^[›>\s]*\d+\.\s+')
    lines = text.splitlines()
    title = ''
    for line in lines:
        m = box_re.search(line)
        if m:
            title = m.group(1).strip()
            break
    if not title:
        for i, line in enumerate(lines):
            if option_line_re.match(line):
                for j in range(i - 1, -1, -1):
                    c = lines[j].strip()
                    if c and not option_line_re.match(lines[j]):
                        title = c
                        break
                break

    _dbg(f'  [numbered_menu] title={title!r} options={options} current={current_idx}')
    return {'title': title, 'options': options, 'current_index': current_idx}


def detect_slash_command_list(text: str, params: dict) -> object:
    """
    Detects: › / input line with command rows below it.

    params:
      commands — static list of {cmd, desc} dicts. When the menu is open,
                 return the full static list rather than just what's visible.
    """
    if not re.search(r'^[›>]\s+/', text, re.MULTILINE):
        return None

    static = params.get('commands', [])
    if static:
        # Static list provided — return all known commands
        cmds = [{'cmd': c['cmd'], 'desc': c.get('desc', '')} for c in static]
    else:
        # Fall back to parsing visible rows
        slash_re = re.compile(r'^\s+(/\w+)\s{2,}(.+)$', re.MULTILINE)
        seen: set = set()
        cmds = []
        for cmd, desc in slash_re.findall(text):
            if cmd not in seen:
                seen.add(cmd)
                cmds.append({'cmd': cmd, 'desc': desc.strip()})

    if not cmds:
        return None

    _dbg(f'  [slash_command_list] {len(cmds)} commands: {[c["cmd"] for c in cmds]}')
    return {'commands': cmds}


def detect_checkbox_menu(text: str, params: dict) -> object:
    """
    Detects: [ ]/[x] option list with a configurable footer.

    params:
      footer  — string that must be present (e.g. 'Press space to select')
      footers — list of strings, any one must be present
    """
    footers = params.get('footers') or []
    if single := params.get('footer'):
        footers = [single] + footers
    if not footers:
        footers = ['Press space to select', 'enter to save']

    if not any(f in text for f in footers):
        return None

    option_re = re.compile(r'^([›>\s]*)\[([x ])\]\s+(.+?)(?:\s{2,}.*)?$', re.MULTILINE)
    options = []
    existing_labels: list = []
    current_idx = 0
    for m in option_re.finditer(text):
        prefix = m.group(1)
        checked = m.group(2).strip() == 'x'
        label = m.group(3).strip()
        if not label:
            continue
        if '›' in prefix or '>' in prefix:
            current_idx = existing_labels.index(label) if label in existing_labels else len(existing_labels)
        if label not in existing_labels:
            existing_labels.append(label)
            options.append({'label': label, 'checked': checked})

    if not options:
        return None

    # Title: nearest non-checkbox line above first option
    option_line_re = re.compile(r'^[›>\s]*\[[x ]]\s+')
    lines = text.splitlines()
    title = ''
    for i, line in enumerate(lines):
        if option_line_re.match(line):
            for j in range(i - 1, -1, -1):
                c = lines[j].strip()
                if c and not option_line_re.match(lines[j]):
                    title = c
                    break
            break

    _dbg(f'  [checkbox_menu] title={title!r} options={options} current={current_idx}')
    return {'title': title, 'options': options, 'current_index': current_idx}


def detect_text_prompt(text: str, params: dict) -> object:
    """
    Detects: a line matching a regex that ends with a prompt character.

    params:
      pattern — regex string to match against each line
    """
    pattern = params.get('pattern', r'.+[?:]\s*$')
    lines = text.splitlines()
    for line in reversed(lines):
        stripped = line.strip()
        if stripped and re.search(pattern, stripped):
            _dbg(f'  [text_prompt] matched: {stripped!r}')
            return {'prompt_text': stripped}
    return None


def detect_keyword_match(text: str, params: dict) -> object:
    """
    Detects: all listed keywords present in the scanned text.

    params:
      keywords — list of strings, all must be present
    """
    keywords = params.get('keywords', [])
    if not keywords:
        return None
    matched = [k for k in keywords if k in text]
    if len(matched) == len(keywords):
        _dbg(f'  [keyword_match] all matched: {matched}')
        return {'matched_keywords': matched}
    return None


def detect_interactive_prompt(text: str, params: dict) -> object:
    """
    Detects user-actionable prompts in terminal output.

    Handles three styles:
      binary  — [Y/n], [y/N], (yes/no) lines at the bottom of output
      arrow   — lines prefixed with ❯ or › (cursor-menu style)
      numbered — lines matching "1) ..." or "1. ..." with at least two options
    """
    lines = text.splitlines()

    # Binary: look in the last 10 lines for [Y/n] / (yes/no) patterns
    binary_re = re.compile(
        r'(.*?)\s*[\(\[]([Yy]/[Nn]|[Nn]/[Yy]|yes/no|no/yes)[\)\]]\s*:?\s*$',
        re.IGNORECASE,
    )
    for line in reversed(lines[-10:]):
        m = binary_re.search(line.strip())
        if m:
            prompt_text = m.group(1).strip() or line.strip()
            _dbg(f'  [interactive_prompt] binary: {prompt_text!r}')
            return {'type': 'binary', 'prompt_text': prompt_text}

    # Arrow cursor menu: lines prefixed with ❯ or › — at least 2 options
    arrow_re = re.compile(r'^[›❯]\s+(.+)$')
    plain_option_re = re.compile(r'^\s{2,}(.+)$')
    option_block: list[str] = []
    selected_idx = 0
    in_block = False
    for line in lines:
        stripped = line.strip()
        am = arrow_re.match(stripped)
        if am:
            if not in_block:
                in_block = True
                selected_idx = len(option_block)
            option_block.append(am.group(1).strip())
        elif in_block:
            pm = plain_option_re.match(line)
            if pm and stripped:
                option_block.append(stripped)
            elif not stripped:
                break  # blank line ends the block
            else:
                break
    if len(option_block) >= 2:
        _dbg(f'  [interactive_prompt] arrow: {len(option_block)} options selected={selected_idx}')
        return {'type': 'arrow', 'options': option_block, 'selected_index': selected_idx}

    # Numbered: "1) Option" or "1. Option" — at least 2 items
    numbered_re = re.compile(r'^\s*\d+[.)]\s+(.+)$')
    numbered: list[str] = []
    for line in lines:
        m = numbered_re.match(line)
        if m:
            numbered.append(m.group(1).strip())
    if len(numbered) >= 2:
        _dbg(f'  [interactive_prompt] numbered: {len(numbered)} options')
        return {'type': 'numbered', 'options': numbered}

    return None


def detect_screen_metadata(text: str, params: dict) -> dict:
    """
    Generic screen observer. Extracts every observable fact from the terminal
    screen with no app-specific knowledge. App scripts interpret the results.

    Returns:
      lines          — count of non-empty lines
      versions       — all semver strings found (e.g. ["1.3.13"])
      paths          — all filesystem paths found (e.g. ["~/Documents/code/ask"])
      path_branches  — dict of path → branch when path:branch syntax present
      key_value_pairs — all "label: value" patterns found
      status_segments — any ·/•-separated status bar split into parts
      shortcuts       — keyboard hint pairs {"ctrl+p": "commands", ...}
      input_prompts   — lines that look like active input cursors
      alerts          — lines starting with warning/error symbols
      option_groups   — any structured lists of options (numbered, checkbox, slash)
      right_labels    — standalone words/names right-aligned on a line (e.g. "Chisel")
      app_name        — name extracted from tmux/screen status bar [name] pattern
      cursor_pos      — {x, y} cursor position (tmux sessions only, via display-message)
    """
    all_lines = text.splitlines()
    non_empty = [l for l in all_lines if l.strip()]
    meta: dict = {'lines': len(non_empty)}

    # ── Versions: all semver strings ─────────────────────────────────────────
    ver_re = re.compile(r'\b(\d+\.\d+\.\d+(?:\.\d+)?)\b')
    versions = list(dict.fromkeys(  # preserve order, deduplicate
        m.group(1) for line in non_empty for m in ver_re.finditer(line)
    ))
    if versions:
        meta['versions'] = versions

    # ── Paths + optional :branch ──────────────────────────────────────────────
    path_re = re.compile(r'(~(?:/[\w._-]+)+|/(?:[\w._-]+/)+[\w._-]*)(?::(\w[\w/-]*))?')
    paths_seen: dict = {}  # path → branch or None
    for line in non_empty:
        for m in path_re.finditer(line):
            p = m.group(1)
            b = m.group(2)
            if p not in paths_seen:
                paths_seen[p] = b
    if paths_seen:
        meta['paths'] = list(paths_seen.keys())
        branches = {p: b for p, b in paths_seen.items() if b}
        if branches:
            meta['path_branches'] = branches

    # ── Key-value pairs: "label:  value" ─────────────────────────────────────
    kv_re = re.compile(r'^\s*([\w][\w\s]{0,20}?):\s{1,10}(\S[^\n]{0,80}?)(?:\s{3,}.*)?$',
                       re.MULTILINE)
    SKIP_KV = {'http', 'https', 'ssh', 'git', 'ftp'}
    kv: dict = {}
    for m in kv_re.finditer(text):
        key = m.group(1).strip().lower().replace(' ', '_')
        val = m.group(2).strip()
        if key and val and key not in SKIP_KV and len(key) < 25 and key not in kv:
            kv[key] = val
    if kv:
        meta['key_value_pairs'] = kv

    # ── Status segments: ·/•-separated bars ──────────────────────────────────
    seg_re = re.compile(r'[·•]')
    for line in reversed(non_empty[-10:]):
        stripped = line.strip()
        if seg_re.search(stripped) and len(stripped) > 10:
            parts = [p.strip() for p in re.split(r'\s*[·•]\s*', stripped) if p.strip()]
            if len(parts) >= 2:
                meta['status_segments'] = parts
                break

    # ── Toggle indicators: ►► label on/off (hint) ────────────────────────────
    toggle_re = re.compile(
        r'[►▶]{1,3}\s+([\w][\w\s]+?)\s+(on|off|enabled|disabled)(?:\s*\(([^)]+)\))?',
        re.IGNORECASE,
    )
    toggles = []
    for line in non_empty:
        m = toggle_re.search(line)
        if m:
            t = {'label': m.group(1).strip(), 'state': m.group(2).lower()}
            if m.group(3):
                t['hint'] = m.group(3).strip()
            toggles.append(t)
    if toggles:
        meta['toggle_indicators'] = toggles

    # ── Keyboard shortcuts ────────────────────────────────────────────────────
    # Handles both "ctrl+p commands" and "shift+tab to cycle" (skip "to" connector)
    sc_re = re.compile(
        r'\b(ctrl\+\S+|alt\+\S+|shift\+\S+|tab|esc|enter)\s+(?:to\s+)?([\w][^\s,;|·()]{0,30})',
        re.IGNORECASE,
    )
    shortcuts: dict = {}
    for line in non_empty:
        for m in sc_re.finditer(line):
            key = m.group(1).lower()
            action = m.group(2).strip()
            if key not in shortcuts:
                shortcuts[key] = action
    if shortcuts:
        meta['shortcuts'] = shortcuts

    # ── Input prompts: lines with active cursor markers ───────────────────────
    prompt_re = re.compile(r'^[\s]*[›>❯»]\s+\S')
    prompts = [l.strip() for l in non_empty[-20:] if prompt_re.match(l)]
    if prompts:
        meta['input_prompts'] = prompts

    # ── Alerts: warning/error lines ───────────────────────────────────────────
    alert_re = re.compile(r'^[\s]*[⚠△▲✗✘!]\s+\S')
    alerts = [l.strip() for l in non_empty if alert_re.match(l)]
    if alerts:
        meta['alerts'] = alerts

    # ── Option groups: numbered lists, checkbox lists, slash-command rows ─────
    option_groups = []

    # Numbered: ›N. label
    numbered_re = re.compile(r'^[›>\s]*(\d+)\.\s+(.+)$', re.MULTILINE)
    numbered = [(m.group(1), m.group(2).strip()) for m in numbered_re.finditer(text)]
    if len(numbered) >= 2:
        option_groups.append({'type': 'numbered', 'items': numbered})

    # Checkbox: [ ] / [x] label
    checkbox_re = re.compile(r'^[›>\s]*\[([x ])\]\s+(.+)$', re.MULTILINE)
    checkboxes = [(m.group(2).strip(), m.group(1) == 'x') for m in checkbox_re.finditer(text)]
    if checkboxes:
        option_groups.append({'type': 'checkbox', 'items': checkboxes})

    # Slash commands:  /cmd   description
    slash_re = re.compile(r'^\s+(/\w+)\s{2,}(.+)$', re.MULTILINE)
    slash_cmds = [(m.group(1), m.group(2).strip()) for m in slash_re.finditer(text)]
    if len(slash_cmds) >= 2:
        option_groups.append({'type': 'slash_commands', 'items': slash_cmds})

    if option_groups:
        meta['option_groups'] = option_groups

    # ── Right-aligned labels: words/names isolated at the right of a line ────────
    # Captures things like "Chisel" that appear right-aligned in status bars.
    # Match lines where content starts at column 30+ with a short word/phrase.
    right_label_re = re.compile(r'^\s{30,}([A-Z][a-zA-Z0-9][\w\s]{0,20}?)\s*$')
    right_labels = []
    for line in all_lines:
        m = right_label_re.match(line)
        if m:
            text = m.group(1).strip()
            if text and not text.isdigit() and len(text) >= 3:
                right_labels.append(text)
    if right_labels:
        meta['right_labels'] = right_labels

    # ── App name from [name] in tmux/screen status bar ────────────────────────
    app_re = re.compile(r'\[([a-zA-Z][a-zA-Z0-9_-]+)\]')
    for line in reversed(non_empty[-5:]):
        m = app_re.search(line)
        if m:
            meta['app_name'] = m.group(1)
            break

    _dbg(f'  [screen_metadata] found: {list(meta.keys())}')
    return meta


DETECTORS = {
    'numbered_menu':      detect_numbered_menu,
    'slash_command_list': detect_slash_command_list,
    'checkbox_menu':      detect_checkbox_menu,
    'text_prompt':        detect_text_prompt,
    'keyword_match':      detect_keyword_match,
    'interactive_prompt': detect_interactive_prompt,
    'screen_metadata':    detect_screen_metadata,
}


# ---------------------------------------------------------------------------
# I/O — Terminal.app via AppleScript
# ---------------------------------------------------------------------------

async def _run_script(script: str, timeout: float = 8.0) -> str:
    """Run an AppleScript and return stdout text."""
    try:
        proc = await asyncio.create_subprocess_exec(
            'osascript', '-e', script,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return stdout.decode('utf-8', errors='replace')
    except Exception as e:
        _log(f'osascript error: {e}', 'WARN')
        return ''


def _tty_to_full(tty: str) -> str:
    if tty.startswith('/dev/'):
        return tty
    if tty.startswith('ttys') or tty.startswith('ttyp'):
        return f'/dev/{tty}'
    return f'/dev/tty{tty}'


async def _terminal_read(tty: str, lines: int, read_mode: str = 'history') -> str:
    """Read terminal output.

    read_mode:
      'history'  — scrollback buffer via `history of t`. Use for inline TUI
                   apps (e.g. Codex --no-alt-screen). Immune to screen redraws.
      'contents' — current visible screen via `contents of t`. Use for
                   full-screen / alt-screen apps (e.g. OpenCode, vim, htop).
    """
    safe = _tty_to_full(tty).replace('"', '\\"')
    prop = 'contents' if read_mode == 'contents' else 'history'
    script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe}" then
                    return {prop} of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
    raw = await _run_script(script)
    text = _strip_ansi(raw)
    if read_mode == 'contents':
        return text  # contents is already current screen — no tail needed
    return _tail_lines(text, lines)


async def _terminal_send_key(tty: str, key: str) -> bool:
    """Focus the Terminal tab and send a named key in one AppleScript call."""
    key_code, _ = KEY_MAP.get(key, (None, None))
    safe = _tty_to_full(tty).replace('"', '\\"')

    if key == 'ctrl_c':
        action = 'keystroke "c" using {control down}'
    elif key == 'ctrl_u':
        action = 'keystroke "u" using {control down}'
    elif key_code is not None:
        action = f'key code {key_code}'
    else:
        _log(f'Unknown key for Terminal.app: {key!r}', 'WARN')
        return False

    script = f'''set targetTTY to "{safe}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then return false
delay 0.3
tell application "System Events"
    {action}
end tell
return true'''

    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [terminal_send_key] key={key!r} tty={tty} ok={ok}')
    return ok


async def _terminal_send_text(tty: str, text: str) -> bool:
    """Ctrl+U to clear line, type text, press Enter — all in one script."""
    safe_tty = _tty_to_full(tty).replace('"', '\\"')
    safe_text = text.replace('\\', '\\\\').replace('"', '\\"')

    script = f'''set targetTTY to "{safe_tty}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then return false
delay 0.3
tell application "System Events"
    keystroke "u" using {{control down}}
    delay 0.1
    keystroke "{safe_text}"
    delay 0.05
    key code 36
end tell
return true'''

    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [terminal_send_text] text={text!r} tty={tty} ok={ok}')
    return ok


async def _terminal_inject_tty(tty: str, text: str) -> bool:
    """Inject text into the terminal tab using Terminal.app's native write command.

    Uses Terminal.app's own AppleScript `write text` verb which sends text directly
    to the tab's running process — no Accessibility permission needed, no System Events.
    Sends text + carriage return so the input is submitted (e.g. selecting a menu option).

    TIOCSTI was removed from macOS (permission denied for non-owning processes),
    so Terminal.app's native scripting is the reliable cross-version approach.
    """
    full = _tty_to_full(tty)
    safe = full.replace('"', '\\"')

    as_text = _as_applescript_str(text)

    # Use Terminal.app's do script to send text + Enter to the running process's stdin.
    # No Accessibility permission needed — Terminal.app handles it internally.
    script = f'''
tell application "Terminal"
    set targetTTY to "{safe}"
    set foundTab to false
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is targetTTY then
                    do script {as_text} in t
                    set foundTab to true
                    exit repeat
                end if
            end try
        end repeat
        if foundTab then exit repeat
    end repeat
    return foundTab
end tell'''

    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [inject_tty] Terminal.app write text={text!r} tty={tty} ok={ok}')
    if not ok:
        _log(f'inject_tty failed — tab not found for {full}', 'WARN')
    return ok


async def _terminal_focus(tty: str) -> bool:
    """Bring the Terminal.app tab with this TTY to the front without typing."""
    safe = _tty_to_full(tty).replace('"', '\\"')
    script = f'''set targetTTY to "{safe}"
set found to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set found to true
                        exit repeat
                    end if
                end try
            end repeat
            if found then exit repeat
        end repeat
    end tell
end if
return found'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [terminal_focus] tty={tty} ok={ok}')
    return ok


async def _terminal_send_raw(tty: str, text: str) -> bool:
    """Type raw text without clearing or pressing Enter."""
    safe_tty = _tty_to_full(tty).replace('"', '\\"')
    safe_text = text.replace('\\', '\\\\').replace('"', '\\"')

    script = f'''set targetTTY to "{safe_tty}"
set foundTab to false
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with i from 1 to tabCount
                set t to tab i of w
                try
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTab to true
                        exit repeat
                    end if
                end try
            end repeat
            if foundTab then exit repeat
        end repeat
    end tell
end if
if not foundTab then return false
delay 0.3
tell application "System Events"
    keystroke "{safe_text}"
end tell
return true'''

    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [terminal_send_raw] text={text!r} tty={tty} ok={ok}')
    return ok


# ---------------------------------------------------------------------------
# I/O — iTerm2 via AppleScript
# ---------------------------------------------------------------------------

async def _iterm2_inject_tty(tty: str, text: str) -> bool:
    """Inject text into an iTerm2 session by TTY — no window focus needed."""
    safe = _tty_to_full(tty).replace('"', '\\"')
    as_text = _as_applescript_str(text)
    script = f'''tell application "iTerm2"
    repeat with w in windows
        repeat with tb in tabs of w
            repeat with s in sessions of tb
                try
                    if tty of s is "{safe}" then
                        write text {as_text} to s
                        return true
                    end if
                end try
            end repeat
        end repeat
    end repeat
    return false
end tell'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [iterm2_inject_tty] text={text!r} tty={tty} ok={ok}')
    if not ok:
        _log(f'iterm2_inject_tty: session not found for {tty}', 'WARN')
    return ok


async def _iterm2_send_text(tty: str, text: str) -> bool:
    """Focus iTerm2 session by TTY and type text via System Events."""
    safe_tty = _tty_to_full(tty).replace('"', '\\"')
    safe_text = text.replace('\\', '\\\\').replace('"', '\\"')
    script = f'''set targetTTY to "{safe_tty}"
set foundSession to false
if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            repeat with tb in tabs of w
                repeat with s in sessions of tb
                    try
                        if tty of s is targetTTY then
                            select tb
                            set index of w to 1
                            activate
                            set foundSession to true
                            exit repeat
                        end if
                    end try
                end repeat
                if foundSession then exit repeat
            end repeat
            if foundSession then exit repeat
        end repeat
    end tell
end if
if not foundSession then return false
delay 0.3
tell application "System Events"
    keystroke "u" using {{control down}}
    delay 0.1
    keystroke "{safe_text}"
    delay 0.05
    key code 36
end tell
return true'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [iterm2_send_text] text={text!r} tty={tty} ok={ok}')
    return ok


async def _iterm2_send_key(tty: str, key: str) -> bool:
    """Focus iTerm2 session by TTY and send a named key via System Events."""
    key_code, _ = KEY_MAP.get(key, (None, None))
    safe_tty = _tty_to_full(tty).replace('"', '\\"')
    if key == 'ctrl_c':
        action = 'keystroke "c" using {control down}'
    elif key == 'ctrl_u':
        action = 'keystroke "u" using {control down}'
    elif key_code is not None:
        action = f'key code {key_code}'
    else:
        _log(f'Unknown key for iTerm2: {key!r}', 'WARN')
        return False
    script = f'''set targetTTY to "{safe_tty}"
set foundSession to false
if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            repeat with tb in tabs of w
                repeat with s in sessions of tb
                    try
                        if tty of s is targetTTY then
                            select tb
                            set index of w to 1
                            activate
                            set foundSession to true
                            exit repeat
                        end if
                    end try
                end repeat
                if foundSession then exit repeat
            end repeat
            if foundSession then exit repeat
        end repeat
    end tell
end if
if not foundSession then return false
delay 0.3
tell application "System Events"
    {action}
end tell
return true'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [iterm2_send_key] key={key!r} tty={tty} ok={ok}')
    return ok


async def _iterm2_focus(tty: str) -> bool:
    """Bring the iTerm2 window/tab hosting this TTY to the front."""
    safe = _tty_to_full(tty).replace('"', '\\"')
    script = f'''set targetTTY to "{safe}"
set found to false
if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            repeat with tb in tabs of w
                repeat with s in sessions of tb
                    try
                        if tty of s is targetTTY then
                            select tb
                            set index of w to 1
                            activate
                            set found to true
                            exit repeat
                        end if
                    end try
                end repeat
                if found then exit repeat
            end repeat
            if found then exit repeat
        end repeat
    end tell
end if
return found'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [iterm2_focus] tty={tty} ok={ok}')
    return ok


# ---------------------------------------------------------------------------
# I/O — Generic (Ghostty, Warp, Alacritty, etc.)
# ---------------------------------------------------------------------------

async def _generic_send_text(app_name: str, text: str) -> bool:
    """Activate the named terminal app and send text using clipboard + keyboard.

    Used for terminals without TTY-based window lookup. Activates the app (bringing
    its last-focused window to front) then pastes via Ctrl+U, Cmd+V, Enter.
    """
    safe_app = app_name.replace('"', '\\"')
    try:
        subprocess.run(['pbcopy'], input=text.encode('utf-8'), timeout=2, check=True)
    except Exception as e:
        _log(f'_generic_send_text pbcopy failed: {e}', 'WARN')
        return False
    script = f'''if application "{safe_app}" is running then
    tell application "{safe_app}" to activate
else
    return false
end if
delay 0.4
tell application "System Events"
    keystroke "u" using {{control down}}
    delay 0.1
    keystroke "v" using command down
    delay 0.1
    key code 36
end tell
return true'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [generic_send_text] app={app_name!r} ok={ok}')
    return ok


async def _generic_send_key(app_name: str, key: str) -> bool:
    """Activate the named app and send a key via System Events."""
    key_code, _ = KEY_MAP.get(key, (None, None))
    safe_app = app_name.replace('"', '\\"')
    if key == 'ctrl_c':
        action = 'keystroke "c" using {control down}'
    elif key == 'ctrl_u':
        action = 'keystroke "u" using {control down}'
    elif key_code is not None:
        action = f'key code {key_code}'
    else:
        _log(f'Unknown key for generic: {key!r}', 'WARN')
        return False
    script = f'''if application "{safe_app}" is running then
    tell application "{safe_app}" to activate
else
    return false
end if
delay 0.4
tell application "System Events"
    {action}
end tell
return true'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [generic_send_key] app={app_name!r} key={key!r} ok={ok}')
    return ok


async def _generic_focus(app_name: str) -> bool:
    """Activate the named app, bringing its last-focused window to front."""
    safe = app_name.replace('"', '\\"')
    script = f'''if application "{safe}" is running then
    tell application "{safe}" to activate
    return true
end if
return false'''
    result = await _run_script(script)
    ok = result.strip() == 'true'
    _dbg(f'  [generic_focus] app={app_name!r} ok={ok}')
    return ok


# ---------------------------------------------------------------------------
# I/O — tmux
# ---------------------------------------------------------------------------

async def _tmux_read(target: str, lines: int) -> str:
    """Read scrollback + screen content. Used for interactive TUI pattern matching."""
    try:
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'capture-pane', '-p', '-t', target, '-e', f'-S-{lines}',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        return _strip_ansi(stdout.decode('utf-8', errors='replace'))
    except Exception as e:
        _log(f'tmux read error: {e}', 'WARN')
        return ''


async def _tmux_read_screen(target: str) -> str:
    """Read only the current visible screen (no scrollback). Used for screen_metadata."""
    try:
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'capture-pane', '-p', '-t', target, '-e',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        return _strip_ansi(stdout.decode('utf-8', errors='replace'))
    except Exception as e:
        _log(f'tmux screen read error: {e}', 'WARN')
        return ''


async def _tmux_cursor_pos(target: str) -> object:
    """Return {x, y} cursor position for a tmux pane, or None on error."""
    try:
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'display-message', '-p', '-t', target, '#{cursor_x} #{cursor_y}',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
        parts = stdout.decode().strip().split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            return {'x': int(parts[0]), 'y': int(parts[1])}
    except Exception:
        pass
    return None


async def _tmux_send_key(target: str, key: str) -> bool:
    _, tmux_key = KEY_MAP.get(key, (None, None))
    if not tmux_key:
        _log(f'Unknown key for tmux: {key!r}', 'WARN')
        return False
    try:
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'send-keys', '-t', target, tmux_key, '',
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=3)
        _dbg(f'  [tmux_send_key] key={key!r} target={target}')
        return True
    except Exception as e:
        _log(f'tmux send-keys error: {e}', 'WARN')
        return False


async def _tmux_send_text(target: str, text: str) -> bool:
    try:
        # Ctrl-U to clear, then type, then Enter
        for keys in ['C-u', text, 'Enter']:
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'send-keys', '-t', target, keys, '',
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=3)
            await asyncio.sleep(0.05)
        _dbg(f'  [tmux_send_text] text={text!r} target={target}')
        return True
    except Exception as e:
        _log(f'tmux send-text error: {e}', 'WARN')
        return False


# ---------------------------------------------------------------------------
# Session registry
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, session_id: str, app_id: str, tty: str = '',
                 tmux_target: str = '', hook: dict = None, read_mode: str = 'history',
                 terminal_app: str = '', pid: int = None):
        self.session_id = session_id
        self.app_id = app_id
        self.tty = tty
        self.tmux_target = tmux_target
        self.hook = hook or {}
        self.read_mode = read_mode  # 'history' or 'contents'
        self.terminal_app = terminal_app  # 'Terminal', 'iTerm2', 'Ghostty', etc.
        self.session_type = 'tmux' if tmux_target else 'terminal_app'
        self.pid: int | None = pid
        self.registered_at: float = _time.time()

    def to_dict(self) -> dict:
        return {
            'session_id':    self.session_id,
            'app_id':        self.app_id,
            'type':          self.session_type,
            'tty':           self.tty,
            'tmux_target':   self.tmux_target,
            'terminal_app':  self.terminal_app,
            'pid':           self.pid,
            'has_hook':      bool(self.hook),
            'registered_at': self.registered_at,
        }


# ---------------------------------------------------------------------------
# TerminalManager
# ---------------------------------------------------------------------------

class TerminalManager:

    def __init__(self):
        self._sessions: dict[str, Session] = {}
        self._pending_calls: dict = {}
        self._rpc_id = 0

    # -----------------------------------------------------------------------
    # JSON-RPC dispatch
    # -----------------------------------------------------------------------

    def _send(self, obj: dict):
        print(json.dumps(obj), flush=True)

    def _reply(self, rpc_id, result):
        self._send({'jsonrpc': '2.0', 'id': rpc_id, 'result': result})

    def _error(self, rpc_id, message: str, code: int = -32600):
        self._send({'jsonrpc': '2.0', 'id': rpc_id,
                    'error': {'code': code, 'message': message}})

    async def read_stdin(self):
        loop = asyncio.get_running_loop()
        buf = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, buf.readline)
            except Exception:
                break
            if not raw:
                break
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            asyncio.create_task(self._dispatch(msg))

    async def _dispatch(self, msg: dict):
        rpc_id = msg.get('id')
        method = msg.get('method', '')
        params = msg.get('params', {})

        # Result/error for calls we made
        if rpc_id is not None and 'result' in msg:
            fut = self._pending_calls.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return
        if rpc_id is not None and 'error' in msg:
            fut = self._pending_calls.pop(rpc_id, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return

        # Incoming tool call routed from AskMac
        if method == 'tools/call':
            name = params.get('name', '')
            args = params.get('arguments', {})
            _log(f'← tool call: {name}({json.dumps(args)[:120]})')
            handler = getattr(self, f'_tool_{name}', None)
            if handler is None:
                self._error(rpc_id, f'Unknown tool: {name}')
                return
            try:
                result = await handler(args)
                self._reply(rpc_id, result)
            except Exception as e:
                _log(f'Tool {name} error: {e}', 'ERROR')
                self._error(rpc_id, str(e))
            return

        _log(f'Unhandled message method={method!r}', 'WARN')

    # -----------------------------------------------------------------------
    # Tool handlers
    # -----------------------------------------------------------------------

    async def _tool_register_session(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        if not sid:
            raise ValueError('session_id required')

        tty = args.get('tty', '')
        tmux = args.get('tmux_target', '')
        if not tty and not tmux:
            raise ValueError('tty or tmux_target required')

        pid_raw = args.get('pid')
        pid = int(pid_raw) if pid_raw is not None else None

        read_mode = args.get('read_mode', 'history')
        terminal_app = ''
        if tty and not tmux:
            terminal_app = await _detect_terminal_for_tty(tty)
        session = Session(
            session_id=sid,
            app_id=args.get('app_id', 'unknown'),
            tty=tty,
            tmux_target=tmux,
            hook=args.get('hook'),
            read_mode=read_mode,
            terminal_app=terminal_app,
            pid=pid,
        )
        self._sessions[sid] = session
        _log(f'Registered session {sid[:12]} type={session.session_type} '
             f'tty={tty!r} tmux={tmux!r} pid={pid} terminal_app={terminal_app!r} '
             f'read_mode={read_mode!r} hook_patterns={len(session.hook.get("patterns", []))}')
        return {'ok': True, 'session_id': sid, 'type': session.session_type}

    async def _tool_unregister_session(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        removed = self._sessions.pop(sid, None) is not None
        _log(f'Unregistered session {sid[:12]} removed={removed}')
        return {'ok': True, 'removed': removed}

    # -----------------------------------------------------------------------
    # Liveness and discovery
    # -----------------------------------------------------------------------

    async def _check_alive(self, session: Session) -> tuple[bool, str]:
        """Internal liveness check. Returns (alive, reason).

        Priority:
          1. tmux pane  → #{pane_dead} query
          2. PID stored → os.kill(pid, 0)
          3. TTY only   → ps -t confirms at least one process on the TTY
          4. No routing → always dead
        """
        if session.session_type == 'tmux' and session.tmux_target:
            result = await self._tool_pane_alive({'target': session.tmux_target})
            if result.get('alive'):
                return True, 'alive'
            return False, result.get('reason', 'tmux_pane_dead')

        if not session.tty and not session.tmux_target:
            return False, 'no_routing'

        if session.pid is not None:
            try:
                os.kill(session.pid, 0)
                return True, 'alive'
            except ProcessLookupError:
                return False, 'pid_not_found'
            except PermissionError:
                # Process exists but owned by another user — still alive
                return True, 'alive'
            except Exception:
                return False, 'pid_check_error'

        # No PID — check if any process is attached to the TTY via ps
        short = session.tty.replace('/dev/', '')
        try:
            proc = await asyncio.create_subprocess_exec(
                'ps', '-t', short, '-o', 'pid=',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
            pids = [x.strip() for x in stdout.decode().split() if x.strip().isdigit()]
            if pids:
                return True, 'alive'
            return False, 'no_processes_on_tty'
        except Exception as e:
            _log(f'_check_alive ps failed for {session.tty!r}: {e}', 'WARN')
            return False, 'ps_error'

    async def _tool_session_alive(self, args: dict) -> dict:
        """Check whether a registered session's underlying process is still running."""
        sid = args.get('session_id', '')
        session = self._sessions.get(sid)
        if not session:
            _log(f'session_alive: unknown session {sid!r}', 'WARN')
            return {'alive': False, 'reason': 'unknown_session', 'session_id': sid}
        alive, reason = await self._check_alive(session)
        _log(f'session_alive {sid[:12]} alive={alive} reason={reason}')
        return {'alive': alive, 'reason': reason, 'session_id': sid}

    async def _find_tmux_target_for_tty(self, tty: str) -> str | None:
        """Return the tmux pane target whose pane_tty matches, or None."""
        full_tty = _tty_to_full(tty)
        try:
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'list-panes', '-a', '-F',
                '#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            for line in stdout.decode().splitlines():
                parts = line.strip().split('\t', 1)
                if len(parts) == 2 and parts[0] == full_tty:
                    return parts[1]
        except Exception as e:
            _log(f'_find_tmux_target_for_tty failed: {e}', 'WARN')
        return None

    async def _tool_discover_sessions(self, args: dict) -> dict:
        """Find all running processes matching an executable name.

        Returns each as a candidate session with pid, tty, cwd, and tmux_target
        (if the process runs inside a tmux pane). Callers use this to adopt
        processes that registered before routing was resolved.

        params:
          executable          — process name to match (e.g. "claude", "codex")
          exclude_session_ids — list of session_ids already tracked; skip their TTYs
        """
        executable = args.get('executable', '').strip()
        if not executable:
            raise ValueError('executable required')
        exclude = set(args.get('exclude_session_ids', []))

        # Build set of TTYs for already-tracked sessions we want to exclude
        tracked_ttys: set[str] = set()
        for s in self._sessions.values():
            if s.session_id not in exclude and s.tty:
                tracked_ttys.add(_tty_to_full(s.tty))

        try:
            proc = await asyncio.create_subprocess_exec(
                'ps', 'aux',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        except Exception as e:
            raise RuntimeError(f'ps failed: {e}')

        results = []
        for line in stdout.decode().splitlines()[1:]:  # skip header
            parts = line.split(None, 10)
            if len(parts) < 11:
                continue
            _user, pid_str, _cpu, _mem, _vsz, _rss, tty_raw, _stat, _start, _time, command = parts

            # Match executable by basename of command path
            cmd_base = command.split('/')[-1].split()[0]
            if cmd_base != executable:
                continue

            try:
                pid = int(pid_str)
            except ValueError:
                continue

            # Normalize TTY — '??' means no controlling terminal
            tty: str | None = None
            if tty_raw and tty_raw != '??':
                tty = _tty_to_full(tty_raw) if not tty_raw.startswith('/') else tty_raw

            if tty and tty in tracked_ttys:
                continue  # already managed by a tracked session

            # Resolve cwd via lsof
            cwd = ''
            try:
                cwd_proc = await asyncio.create_subprocess_exec(
                    'lsof', '-p', str(pid), '-d', 'cwd', '-Fn',
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                )
                cwd_out, _ = await asyncio.wait_for(cwd_proc.communicate(), timeout=3)
                for cwd_line in cwd_out.decode().splitlines():
                    if cwd_line.startswith('n/'):
                        cwd = cwd_line[1:]
                        break
            except Exception:
                pass

            # Resolve tmux target if the TTY is inside a tmux pane
            tmux_target: str | None = None
            if tty:
                tmux_target = await self._find_tmux_target_for_tty(tty)

            results.append({
                'pid': pid,
                'tty': tty,
                'cwd': cwd,
                'tmux_target': tmux_target,
            })

        _log(f'discover_sessions executable={executable!r} found={len(results)}')
        return {'sessions': results}

    async def _tool_list_sessions(self, args: dict) -> dict:
        sessions = []
        for s in self._sessions.values():
            alive, reason = await self._check_alive(s)
            d = s.to_dict()
            d['alive'] = alive
            d['alive_reason'] = reason
            sessions.append(d)
        _log(f'list_sessions → {len(sessions)} sessions')
        return {'sessions': sessions}

    async def _tool_read_output(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        lines = int(args.get('lines', 80))
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')

        text = await self._read(session, lines)
        result_lines = text.splitlines()
        _log(f'read_output {sid[:12]} → {len(result_lines)} lines')

        # Print last 5 non-empty lines for debugging
        preview = [l for l in result_lines if l.strip()][-5:]
        for l in preview:
            _dbg(f'  | {l}')

        return {'lines': result_lines}

    async def _tool_detect_tui(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')

        hook = session.hook
        scan_lines = hook.get('scan_lines', 80)
        patterns = hook.get('patterns', [])

        text = await self._read(session, scan_lines)
        _log(f'detect_tui {sid[:12]} scanning {len(text.splitlines())} lines '
             f'against {len(patterns)} patterns')

        interactive_match = None
        metadata = None

        # For screen_metadata, read visible screen only (no scrollback) to avoid
        # extracting patterns from code/content displayed in the terminal.
        screen_text = None
        if session.session_type == 'tmux':
            screen_text = await _tmux_read_screen(session.tmux_target)
        else:
            screen_text = text  # non-tmux: no distinction, use same buffer

        for pattern in patterns:
            pid = pattern.get('id', '?')
            detect = pattern.get('detect', {})
            dtype = detect.get('type', '')
            detector = DETECTORS.get(dtype)
            if detector is None:
                _log(f'  Unknown detector type: {dtype!r}', 'WARN')
                continue

            _dbg(f'  Testing pattern {pid!r} ({dtype})')
            # screen_metadata uses screen_text (no scrollback) to avoid false
            # positives from code/content in the terminal history.
            # Interactive patterns also use screen_text so they detect TUI modals
            # that may be rendered on the alternate screen buffer (not scrollback).
            scan_text = screen_text if screen_text is not None else text
            result = detector(scan_text if dtype != 'screen_metadata' else screen_text, detect)

            if dtype == 'screen_metadata':
                # Always collect metadata but don't treat as interactive match
                metadata = result
                _dbg(f'  [screen_metadata] collected')
                continue

            if result is not None and interactive_match is None:
                _log(f'MATCH pattern={pid!r} type={dtype} result_keys={list(result.keys())}')
                interactive_match = {'pattern_id': pid, 'result': result}

        # Attach cursor position for tmux sessions
        if session.session_type == 'tmux' and metadata is not None:
            cursor = await _tmux_cursor_pos(session.tmux_target)
            if cursor:
                metadata['cursor_pos'] = cursor

        if interactive_match:
            interactive_match['metadata'] = metadata
            return interactive_match

        if metadata:
            _log(f'No interactive match — returning metadata only '
                 f'keys={list(metadata.keys())}')
            return {'pattern_id': None, 'result': None, 'metadata': metadata}

        _dbg(f'  No patterns matched')
        return {'pattern_id': None, 'result': None, 'metadata': None}

    async def _tool_send_key(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        key = args.get('key', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')
        if key not in KEY_MAP:
            raise ValueError(f'Unknown key: {key!r}. Valid: {list(KEY_MAP.keys())}')

        _log(f'send_key {sid[:12]} key={key!r}')
        ok = await self._send_key(session, key)
        return {'ok': ok}

    async def _tool_send_text(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        target = args.get('target', '')
        text = args.get('text', '')
        # Direct tmux target (no session_id needed) — same pattern as send_interrupt
        if not sid and target:
            _log(f'send_text target={target!r} text={text!r}')
            ok = await _tmux_send_text(target, text)
            return {'ok': ok}
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')

        _log(f'send_text {sid[:12]} text={text!r}')
        ok = await self._send_text(session, text)
        return {'ok': ok}

    async def _tool_send_raw(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        text = args.get('text', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')

        _log(f'send_raw {sid[:12]} text={text!r}')
        ok = await self._send_raw(session, text)
        return {'ok': ok}

    async def _tool_inject_tty(self, args: dict) -> dict:
        """Inject text into the TTY input queue — no clipboard, no window focus needed."""
        sid = args.get('session_id', '')
        text = args.get('text', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')
        if session.session_type == 'tmux':
            _log(f'inject_tty {sid[:12]} — tmux session, delegating to send_text')
            ok = await _tmux_send_text(session.tmux_target, text)
        else:
            app = session.terminal_app or 'Terminal'
            _log(f'inject_tty {sid[:12]} tty={session.tty!r} terminal={app!r}')
            if app == 'iTerm2':
                ok = await _iterm2_inject_tty(session.tty, text)
            elif app in ('Terminal', 'unknown', ''):
                ok = await _terminal_inject_tty(session.tty, text)
            else:
                # Ghostty, Warp, etc.: no direct inject — signal caller to use send_text
                _log(f'inject_tty: {app!r} has no native inject, returning false', 'WARN')
                ok = False
        return {'ok': ok}

    async def _tool_focus_window(self, args: dict) -> dict:
        """Bring the terminal window/pane for this session to the foreground."""
        sid = args.get('session_id', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')
        if session.session_type == 'tmux':
            # Select the tmux window containing this pane
            try:
                proc = await asyncio.create_subprocess_exec(
                    TMUX, 'select-window', '-t', session.tmux_target,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                await asyncio.wait_for(proc.wait(), timeout=3)
                _log(f'focus_window {sid[:12]} tmux={session.tmux_target}')
                return {'ok': True}
            except Exception as e:
                _log(f'focus_window tmux error: {e}', 'WARN')
                return {'ok': False}
        else:
            app = session.terminal_app or 'Terminal'
            _log(f'focus_window {sid[:12]} tty={session.tty!r} terminal={app!r}')
            if app == 'iTerm2':
                ok = await _iterm2_focus(session.tty)
            elif app in ('Terminal', 'unknown', ''):
                ok = await _terminal_focus(session.tty)
            else:
                ok = await _generic_focus(app)
            return {'ok': ok}

    async def _tool_wait_for_idle(self, args: dict) -> dict:
        """Poll until the session shows a Claude Code idle prompt, then return the response.

        Returns {'idle': bool, 'output': str} where output is the text above the
        final prompt line — i.e. Claude's most recent response.  Useful for TTY
        sessions where response capture isn't available via tmux capture-pane.

        params:
          session_id     — required
          timeout        — seconds to wait (default 120)
          prompt_pattern — regex for the idle prompt line (default Claude Code '> ')
          poll_interval  — seconds between polls (default 1)
          stable_count   — how many identical idle reads confirm idle (default 2)
        """
        import re as _re
        sid = args.get('session_id', '')
        timeout = float(args.get('timeout', 120))
        pattern = args.get('prompt_pattern', r'^\s*>\s*$')
        poll_interval = float(args.get('poll_interval', 1))
        stable_needed = int(args.get('stable_count', 2))

        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')

        prompt_re = _re.compile(pattern)
        deadline = asyncio.get_event_loop().time() + timeout
        prev_content = ''
        stable = 0

        _log(f'wait_for_idle {sid[:12]} timeout={timeout}s pattern={pattern!r}')

        while asyncio.get_event_loop().time() < deadline:
            content = await self._read(session, 120)
            lines = [l for l in content.splitlines() if l.strip()]

            if lines and prompt_re.match(lines[-1]):
                if content == prev_content:
                    stable += 1
                    if stable >= stable_needed:
                        output = self._extract_response(content, prompt_re)
                        _log(f'wait_for_idle {sid[:12]} idle — {len(output)} chars')
                        return {'idle': True, 'output': output}
                else:
                    stable = 0
            else:
                stable = 0

            prev_content = content
            await asyncio.sleep(poll_interval)

        _log(f'wait_for_idle {sid[:12]} timed out after {timeout}s')
        return {'idle': False, 'output': ''}

    @staticmethod
    def _extract_response(content: str, prompt_re) -> str:
        """Extract the text above the trailing prompt line(s)."""
        import re as _re
        lines = content.splitlines()
        # Find the last prompt line
        bottom = len(lines)
        for i in range(len(lines) - 1, -1, -1):
            if prompt_re.match(lines[i]):
                bottom = i
            else:
                break
        candidate = lines[:bottom]
        # Strip trailing blank lines and decorative separators
        while candidate and not candidate[-1].strip():
            candidate.pop()
        response_lines = [
            l for l in candidate
            if l.strip() and not _re.match(r'^[-─━═╌╍\s]+$', l)
        ]
        return '\n'.join(response_lines[-40:]).strip()[:4000]

    # -----------------------------------------------------------------------
    # tmux lifecycle & advanced tools
    # -----------------------------------------------------------------------

    async def _tmux_ensure_session(self, session: str, cwd: str = '') -> bool:
        """Create tmux session if it doesn't exist. Returns True if created, False if already existed."""
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'has-session', '-t', session,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=3)
        if proc.returncode == 0:
            return False
        cmd = [TMUX, 'new-session', '-d', '-s', session]
        if cwd:
            cmd += ['-c', cwd]
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=10)
        _log(f'_tmux_ensure_session: created {session!r}')
        return True

    async def _tool_create_window(self, params: dict) -> dict:
        """Create a named tmux window, optionally running a command inside it."""
        session = params.get('session', 'ask')
        window_name = params['window_name']
        command = params.get('command', '')
        cwd = params.get('cwd', '')
        await self._tmux_ensure_session(session, cwd)
        # Use -P -F to capture the new window's unique ID so the target is
        # unambiguous even when multiple windows share the same name.
        cmd = [TMUX, 'new-window', '-t', session, '-n', window_name,
               '-P', '-F', f'{session}:#{{window_id}}']
        if cwd:
            cmd += ['-c', cwd]
        if command:
            cmd.append(command)
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        target = stdout.decode().strip() or f'{session}:{window_name}'
        _log(f'_tool_create_window: created {target!r}')
        return {'target': target, 'session': session, 'window': window_name}

    async def _tool_destroy_window(self, params: dict) -> dict:
        """Kill a tmux window, optionally sending Ctrl+C first. Unregisters any matching session."""
        target = params['target']
        force = params.get('force', False)
        try:
            if not force:
                proc = await asyncio.create_subprocess_exec(
                    TMUX, 'send-keys', '-t', target, 'C-c', '',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await asyncio.wait_for(proc.communicate(), timeout=5)
                await asyncio.sleep(0.3)
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'kill-window', '-t', target,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.communicate(), timeout=10)
            ok = True
        except Exception as exc:
            _log(f'_tool_destroy_window: error killing {target!r}: {exc}')
            ok = False
        # Unregister any registered session whose tmux_target matches
        to_remove = [sid for sid, s in self._sessions.items() if s.tmux_target == target]
        for sid in to_remove:
            del self._sessions[sid]
            _log(f'_tool_destroy_window: unregistered session {sid!r} (target={target!r})')
        _log(f'_tool_destroy_window: ok={ok} target={target!r}')
        return {'ok': ok, 'target': target}

    async def _tool_list_windows(self, params: dict) -> dict:
        """List all windows in a tmux session with index, name, active state, and command."""
        session = params.get('session', 'ask')
        fmt = '#{window_index}\t#{window_name}\t#{window_active}\t#{pane_current_command}\t#{pane_dead}'
        try:
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'list-windows', '-t', session, '-F', fmt,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        except Exception:
            return {'session': session, 'windows': []}
        if proc.returncode != 0:
            return {'session': session, 'windows': []}
        windows = []
        for line in stdout.decode().splitlines():
            parts = line.split('\t')
            if len(parts) < 5:
                continue
            index, name, active, command, dead = parts
            windows.append({
                'index': index,
                'name': name,
                'target': f'{session}:{name}',
                'active': active == '1',
                'command': command,
                'alive': dead != '1',
            })
        _log(f'_tool_list_windows: session={session!r} count={len(windows)}')
        return {'session': session, 'windows': windows}

    async def _tool_rename_window(self, params: dict) -> dict:
        """Rename a tmux window by target string."""
        target = params['target']
        new_name = params['new_name']
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'rename-window', '-t', target, new_name,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=5)
        if proc.returncode != 0:
            raise RuntimeError(f'rename-window failed: {stderr.decode().strip()}')
        _log(f'_tool_rename_window: {target!r} -> {new_name!r}')
        return {'ok': True, 'target': target, 'new_name': new_name}

    async def _tool_split_pane(self, params: dict) -> dict:
        """Split a tmux pane horizontally or vertically, optionally running a command."""
        target = params['target']
        direction = params.get('direction', 'horizontal')
        command = params.get('command', '')
        cwd = params.get('cwd', '')
        percent = params.get('percent', 50)
        flag = '-h' if direction == 'horizontal' else '-v'
        cmd = [TMUX, 'split-window', flag, '-t', target, '-p', str(percent)]
        if cwd:
            cmd += ['-c', cwd]
        if command:
            cmd.append(command)
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.communicate(), timeout=10)
        # Get new pane target
        proc2 = await asyncio.create_subprocess_exec(
            TMUX, 'display-message', '-t', target, '-p',
            '#{session_name}:#{window_name}.#{pane_index}',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc2.communicate(), timeout=5)
        new_target = stdout.decode().strip()
        _log(f'_tool_split_pane: target={target!r} new_pane={new_target!r} direction={direction!r}')
        return {'ok': True, 'target': target, 'new_pane': new_target, 'direction': direction}

    async def _tool_pane_alive(self, params: dict) -> dict:
        """Check whether a tmux pane is still running (not dead).

        tmux display-message silently falls back to the active window when the
        target doesn't exist (exit 0, no error). We guard against that by also
        verifying the returned window name/ID matches the requested target.
        """
        target = params['target']
        # Format: 'session:window_ref' where window_ref is a name or '@<id>'
        colon = target.find(':')
        window_ref = target[colon + 1:] if colon != -1 else target
        is_id_target = window_ref.startswith('@')
        # Fetch both pane_dead and the actual window identifier in one call
        fmt = '#{pane_dead}\t#{window_id}' if is_id_target else '#{pane_dead}\t#{window_name}'
        try:
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'display-message', '-t', target, '-p', fmt,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        except asyncio.TimeoutError:
            return {'alive': False, 'target': target, 'reason': 'timeout'}
        except Exception:
            return {'alive': False, 'target': target, 'reason': 'not_found'}
        if proc.returncode != 0:
            return {'alive': False, 'target': target, 'reason': 'not_found'}
        parts = stdout.decode().strip().split('\t', 1)
        dead = parts[0]
        actual = parts[1] if len(parts) > 1 else ''
        # Verify tmux actually resolved to the window we asked for (not a fallback)
        if is_id_target:
            # window_ref='@30', actual from #{window_id} is '@30'
            if actual != window_ref:
                return {'alive': False, 'target': target, 'reason': 'not_found'}
        else:
            # name-based: verify the returned window name matches
            if actual != window_ref:
                return {'alive': False, 'target': target, 'reason': 'not_found'}
        return {'alive': dead != '1', 'target': target}

    async def _tool_get_pane_info(self, params: dict) -> dict:
        """Return full metadata for a tmux pane: pid, command, dimensions, tty, session, window."""
        target = params['target']
        fmt = '#{pane_pid}\t#{pane_current_command}\t#{pane_dead}\t#{pane_width}\t#{pane_height}\t#{window_name}\t#{session_name}\t#{pane_tty}'
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'display-message', '-t', target, '-p', fmt,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        parts = stdout.decode().strip().split('\t')
        pid_raw, command, dead, width_raw, height_raw, window, session, tty = (parts + [''] * 8)[:8]
        try:
            pid = int(pid_raw)
        except (ValueError, TypeError):
            pid = None
        try:
            width = int(width_raw)
        except (ValueError, TypeError):
            width = 0
        try:
            height = int(height_raw)
        except (ValueError, TypeError):
            height = 0
        return {
            'target': target,
            'session': session,
            'window': window,
            'tty': tty,
            'pid': pid,
            'command': command,
            'alive': dead != '1',
            'width': width,
            'height': height,
        }

    async def _tool_send_interrupt(self, params: dict) -> dict:
        """Send Ctrl+C to a tmux pane by direct target or registered session_id."""
        target = params.get('target', '')
        session_id = params.get('session_id', '')
        if not target and session_id:
            session = self._sessions.get(session_id)
            if session and session.tmux_target:
                target = session.tmux_target
        if not target:
            raise ValueError('send_interrupt requires target or a valid session_id with a tmux_target')
        proc = await asyncio.create_subprocess_exec(
            TMUX, 'send-keys', '-t', target, 'C-c', '',
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.communicate(), timeout=5)
        _log(f'_tool_send_interrupt: sent C-c to {target!r}')
        return {'ok': True, 'target': target}

    async def _tool_wait_for_pattern(self, params: dict) -> dict:
        """Poll a tmux pane until a regex pattern matches, with stable-count and timeout support."""
        target = params.get('target', '')
        session_id = params.get('session_id', '')
        pattern = params['pattern']
        timeout = float(params.get('timeout', 30))
        poll_interval = float(params.get('poll_interval', 0.5))
        stable_count = int(params.get('stable_count', 1))
        lines = int(params.get('lines', 50))
        if not target and session_id:
            session = self._sessions.get(session_id)
            if session and session.tmux_target:
                target = session.tmux_target
        if not target:
            raise ValueError('wait_for_pattern requires target or a valid session_id with a tmux_target')
        _log(f'_tool_wait_for_pattern: waiting for {pattern!r} on {target!r} timeout={timeout}')
        deadline = _time.monotonic() + timeout
        last_content = ''
        consecutive = 0
        timed_out = False
        matched = False
        while _time.monotonic() < deadline:
            content = await _tmux_read(target, lines)
            if re.search(pattern, content, re.MULTILINE):
                if content == last_content:
                    consecutive += 1
                else:
                    consecutive = 1
                last_content = content
                if consecutive >= stable_count:
                    matched = True
                    break
            else:
                consecutive = 0
                last_content = content
            remaining = deadline - _time.monotonic()
            await asyncio.sleep(min(poll_interval, max(0, remaining)))
        else:
            timed_out = True
        _log(f'_tool_wait_for_pattern: matched={matched} timed_out={timed_out} target={target!r}')
        return {'matched': matched, 'output': last_content, 'timed_out': timed_out}

    async def _tool_run_command(self, params: dict) -> dict:
        """Create an ephemeral tmux window, run a command, wait for completion, return output."""
        command = params['command']
        session = params.get('session', 'ask')
        timestamp = int(_time.time())
        window_name = params.get('window_name', f'run_{timestamp}')
        cwd = params.get('cwd', '')
        timeout = float(params.get('timeout', 60))
        keep_window = params.get('keep_window', False)
        create_result = await self._tool_create_window({
            'session': session,
            'window_name': window_name,
            'command': command,
            'cwd': cwd,
        })
        target = create_result['target']
        _prompt_re = re.compile(r'[$#%>]\s*$', re.MULTILINE)
        start = _time.monotonic()
        timed_out = False
        while True:
            elapsed = _time.monotonic() - start
            if elapsed >= timeout:
                timed_out = True
                break
            alive_result = await self._tool_pane_alive({'target': target})
            if not alive_result.get('alive', True):
                break
            snippet = await _tmux_read(target, 5)
            if _prompt_re.search(snippet):
                break
            await asyncio.sleep(1)
        elapsed = _time.monotonic() - start
        output = await _tmux_read(target, 500)
        if not keep_window:
            await self._tool_destroy_window({'target': target, 'force': True})
            final_target = None
        else:
            final_target = target
        _log(f'_tool_run_command: elapsed={elapsed:.1f}s timed_out={timed_out} target={target!r}')
        return {'output': output, 'elapsed': elapsed, 'timed_out': timed_out, 'target': final_target}

    async def _tool_screenshot(self, params: dict) -> dict:
        """Capture the current state of a tmux pane as text and optionally as a PNG image."""
        target = params.get('target', '')
        session_id = params.get('session_id', '')
        fmt = params.get('format', 'auto')
        if not target and session_id:
            session = self._sessions.get(session_id)
            if session and session.tmux_target:
                target = session.tmux_target
        if not target:
            raise ValueError('screenshot requires target or a valid session_id with a tmux_target')
        # Always capture text
        try:
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'capture-pane', '-p', '-t', target,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
            raw_text = stdout.decode()
        except Exception:
            raw_text = ''
        # Strip ANSI escape codes
        ansi_re = re.compile(r'\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[^[\\]', re.DOTALL)
        text = ansi_re.sub('', raw_text)
        result: dict = {'target': target, 'text': text}
        if fmt in ('image', 'auto'):
            image_data = await self._capture_terminal_image(target)
            if image_data is not None:
                result['image'] = image_data
        return result

    async def _capture_terminal_image(self, target: str):
        """Capture a PNG screenshot of the terminal window hosting the given tmux pane."""
        try:
            # Step 1: find terminal app via tmux client TTYs (pane TTY leads to tmux server,
            # not the terminal emulator — client TTY leads to iTerm2/Terminal.app)
            proc = await asyncio.create_subprocess_exec(
                TMUX, 'list-clients', '-F', '#{client_tty}',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            client_ttys = [t.strip() for t in stdout.decode().splitlines() if t.strip()]

            app = 'unknown'
            for tty in client_ttys:
                detected = await _detect_terminal_for_tty(tty)
                if detected != 'unknown':
                    app = detected
                    break
            if app == 'unknown':
                return None
            # Step 3: get CGWindowID by asking the app directly (System Events
            # can't return CGWindowID for some apps like Terminal.app)
            script = f'tell application "{app}" to return id of front window'
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
            window_id = stdout.decode().strip()
            if not window_id:
                return None
            # Step 4: screencapture to temp file
            tmp = tempfile.NamedTemporaryFile(suffix='.png', delete=False)
            tmp_path = tmp.name
            tmp.close()
            try:
                proc = await asyncio.create_subprocess_exec(
                    'screencapture', '-l', window_id, '-x', '-o', tmp_path,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                await asyncio.wait_for(proc.communicate(), timeout=15)
                with open(tmp_path, 'rb') as f:
                    data = f.read()
                b64_string = base64.b64encode(data).decode('ascii')
            finally:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
            return {'format': 'png', 'encoding': 'base64', 'data': b64_string}
        except Exception as exc:
            _log(f'WARN _capture_terminal_image: {exc}')
            return None

    async def _get_tty_cwd(self, tty: str) -> str:
        """Return the cwd of the foreground shell process on a TTY, via lsof."""
        short = tty.replace('/dev/', '')
        try:
            proc = await asyncio.create_subprocess_exec(
                'ps', '-t', short, '-o', 'pid=,comm=',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        except Exception:
            return ''

        shell_names = {'bash', 'zsh', 'fish', 'sh', 'tcsh', 'csh'}
        shell_pid = None
        first_pid = None
        for line in stdout.decode().splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            pid_str, comm = parts
            comm_base = comm.split('/')[-1].lstrip('-')
            if first_pid is None:
                first_pid = pid_str
            if comm_base in shell_names and shell_pid is None:
                shell_pid = pid_str

        target_pid = shell_pid or first_pid
        if not target_pid:
            return ''

        try:
            proc = await asyncio.create_subprocess_exec(
                'lsof', '-p', target_pid, '-d', 'cwd', '-Fn',
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            for line in stdout.decode().splitlines():
                if line.startswith('n') and line[1:].startswith('/'):
                    return line[1:]
        except Exception:
            pass
        return ''

    async def _tool_migrate_to_tmux(self, params: dict) -> dict:
        """Migrate a terminal session (TTY) to a tmux-owned window.

        Detects the cwd of the shell on the TTY, creates a new tmux window
        there, and updates (or creates) the session record to point at tmux.
        The original TTY entry is cleared so all subsequent tool calls use
        the tmux path automatically.

        params:
          session_id   — registered session to migrate (provides tty automatically)
          tty          — TTY device path, e.g. /dev/ttys003 (used when no session_id)
          cwd          — override cwd detection
          session      — tmux session name (default 'ask')
          window_name  — tmux window name (default: basename of cwd)
          command      — command to run in the new window (e.g. 'claude')
        """
        session_id = params.get('session_id', '')
        tty = params.get('tty', '')
        cwd = params.get('cwd', '')
        tmux_session = params.get('session', 'ask')
        command = params.get('command', '')
        window_name = params.get('window_name', '')

        source = None
        if session_id:
            source = self._sessions.get(session_id)
            if not source:
                raise ValueError(f'Unknown session: {session_id!r}')
            tty = tty or source.tty

        if not tty:
            raise ValueError('session_id (with a registered tty) or tty required')

        if not cwd:
            cwd = await self._get_tty_cwd(tty)
            _log(f'migrate_to_tmux: detected cwd={cwd!r} from tty={tty!r}')

        if not window_name:
            window_name = os.path.basename(cwd.rstrip('/')) if cwd else 'terminal'

        result = await self._tool_create_window({
            'session': tmux_session,
            'window_name': window_name,
            'command': command,
            'cwd': cwd,
        })
        target = result['target']

        if source:
            source.tty = ''
            source.tmux_target = target
            source.session_type = 'tmux'
            source.terminal_app = ''
        else:
            new_sid = f'migrated:{os.path.basename(tty)}'
            self._sessions[new_sid] = Session(
                session_id=new_sid,
                app_id='migrated',
                tty='',
                tmux_target=target,
            )
            session_id = new_sid

        _log(f'migrate_to_tmux: {tty!r} → {target!r} cwd={cwd!r}')
        return {
            'target': target,
            'session_id': session_id,
            'cwd': cwd,
            'window': window_name,
            'tmux_session': tmux_session,
        }

    # -----------------------------------------------------------------------
    # I/O dispatch
    # -----------------------------------------------------------------------

    async def _read(self, session: Session, lines: int) -> str:
        if session.session_type == 'tmux':
            return await _tmux_read(session.tmux_target, lines)
        else:
            return await _terminal_read(session.tty, lines, session.read_mode)

    async def _send_key(self, session: Session, key: str) -> bool:
        if session.session_type == 'tmux':
            return await _tmux_send_key(session.tmux_target, key)
        app = session.terminal_app or 'Terminal'
        if app == 'iTerm2':
            return await _iterm2_send_key(session.tty, key)
        elif app in ('Terminal', 'unknown', ''):
            return await _terminal_send_key(session.tty, key)
        else:
            return await _generic_send_key(app, key)

    async def _send_text(self, session: Session, text: str) -> bool:
        if session.session_type == 'tmux':
            return await _tmux_send_text(session.tmux_target, text)
        app = session.terminal_app or 'Terminal'
        if app == 'iTerm2':
            return await _iterm2_send_text(session.tty, text)
        elif app in ('Terminal', 'unknown', ''):
            return await _terminal_send_text(session.tty, text)
        else:
            return await _generic_send_text(app, text)

    async def _send_raw(self, session: Session, text: str) -> bool:
        if session.session_type == 'tmux':
            # tmux: just send-keys without C-u or Enter
            try:
                proc = await asyncio.create_subprocess_exec(
                    TMUX, 'send-keys', '-t', session.tmux_target, text, '',
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                await asyncio.wait_for(proc.wait(), timeout=3)
                return True
            except Exception:
                return False
        else:
            return await _terminal_send_raw(session.tty, text)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    _log('terminal-manager starting')
    manager = TerminalManager()
    stdin_task = asyncio.create_task(manager.read_stdin())
    _log('terminal-manager ready — listening on stdin')
    try:
        await stdin_task
    except asyncio.CancelledError:
        pass
    _log('terminal-manager shutting down')


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
