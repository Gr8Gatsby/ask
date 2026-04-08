#!/usr/bin/env python3
"""
terminal-manager — system script providing generic terminal session management
and TUI detection as MCP tools for other scripts.

Protocol: JSON-RPC 2.0 over stdin/stdout (same as all Ask scripts).
System type: tools contributed to AskMac MCP namespace, not surfaced to iPhone.

Each line on stdin is a JSON-RPC message. Responses go to stdout.
Debug output (what's detected, what actions are taken) goes to stderr and log.
"""

import sys
import json
import asyncio
import os
import re
import subprocess
import datetime

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

    # Convert Python string to an AppleScript expression.
    # Non-printable chars (like ESC = 0x1B) become (ASCII character N).
    # do script appends Enter automatically, so ESC[B sequences navigate without extra Enter.
    def _as_str(s: str) -> str:
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

    as_text = _as_str(text)

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
                 tmux_target: str = '', hook: dict = None, read_mode: str = 'history'):
        self.session_id = session_id
        self.app_id = app_id
        self.tty = tty
        self.tmux_target = tmux_target
        self.hook = hook or {}
        self.read_mode = read_mode  # 'history' or 'contents'
        self.session_type = 'tmux' if tmux_target else 'terminal_app'

    def to_dict(self) -> dict:
        return {
            'session_id':   self.session_id,
            'app_id':       self.app_id,
            'type':         self.session_type,
            'tty':          self.tty,
            'tmux_target':  self.tmux_target,
            'has_hook':     bool(self.hook),
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

        read_mode = args.get('read_mode', 'history')
        session = Session(
            session_id=sid,
            app_id=args.get('app_id', 'unknown'),
            tty=tty,
            tmux_target=tmux,
            hook=args.get('hook'),
            read_mode=read_mode,
        )
        self._sessions[sid] = session
        _log(f'Registered session {sid[:12]} type={session.session_type} '
             f'tty={tty!r} tmux={tmux!r} read_mode={read_mode!r} '
             f'hook_patterns={len(session.hook.get("patterns", []))}')
        return {'ok': True, 'session_id': sid, 'type': session.session_type}

    async def _tool_unregister_session(self, args: dict) -> dict:
        sid = args.get('session_id', '')
        removed = self._sessions.pop(sid, None) is not None
        _log(f'Unregistered session {sid[:12]} removed={removed}')
        return {'ok': True, 'removed': removed}

    async def _tool_list_sessions(self, args: dict) -> dict:
        sessions = [s.to_dict() for s in self._sessions.values()]
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
        text = args.get('text', '')
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
        """Inject text into the TTY input queue via TIOCSTI — no clipboard, no focus needed."""
        sid = args.get('session_id', '')
        text = args.get('text', '')
        session = self._sessions.get(sid)
        if not session:
            raise ValueError(f'Unknown session: {sid}')
        if session.session_type == 'tmux':
            # tmux sessions don't use a TTY device — fall back to send_text
            _log(f'inject_tty {sid[:12]} — tmux session, delegating to send_text')
            ok = await _tmux_send_text(session.tmux_target, text)
        else:
            _log(f'inject_tty {sid[:12]} tty={session.tty!r}')
            ok = await _terminal_inject_tty(session.tty, text)
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
            _log(f'focus_window {sid[:12]} tty={session.tty!r}')
            ok = await _terminal_focus(session.tty)
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
        else:
            return await _terminal_send_key(session.tty, key)

    async def _send_text(self, session: Session, text: str) -> bool:
        if session.session_type == 'tmux':
            return await _tmux_send_text(session.tmux_target, text)
        else:
            return await _terminal_send_text(session.tty, text)

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
