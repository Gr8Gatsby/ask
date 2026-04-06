#!/usr/bin/env python3
"""
debug_tui.py — Interactive debugger for Codex TUI detection and control.

Usage:
    python3 debug_tui.py               # auto-detect codex TTY
    python3 debug_tui.py /dev/ttys003  # specific TTY

Commands at the prompt:
    r          — read terminal (last 30 lines) and run detection
    R          — read terminal (last 30 lines), raw text dump
    H          — read full history (no trim)
    u / d      — send Up / Down arrow keystroke and re-detect
    enter / e  — send Enter
    esc        — send Escape
    q          — quit
"""
import re
import subprocess
import sys
import time

ANSI_RE = re.compile(
    r'\x1b\[[0-9;]*[mGKHFJABCDsuhl]|\x1b[()][AB012]|\x1b\][^\x07]*\x07|\r'
)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub('', text)


def read_tty_history(tty: str, tail: int = 30) -> str:
    safe = tty.replace('"', '\\"')
    script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe}" then
                    return history of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
    r = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=8)
    text = strip_ansi(r.stdout)
    if tail:
        lines = text.splitlines()
        return '\n'.join(lines[-tail:])
    return text


def detect_tui(content: str):
    """Same logic as MCPClient._detect_codex_tui_menu."""
    lines = [ANSI_RE.sub('', l) for l in content.splitlines()]
    text = '\n'.join(lines)

    if 'Press enter to confirm' not in text and 'esc to go back' not in text:
        return None

    # Codex uses '›' (U+203A) as the cursor marker, not plain '>'.
    option_re = re.compile(r'^([›>\s]*)\d+\.\s+(.+)$', re.MULTILINE)
    options = []
    current_idx = 0
    cursor_labels = []  # track every label where cursor was seen, for debugging
    for m in option_re.finditer(text):
        prefix = m.group(1)
        rest = m.group(2).strip()
        label = re.split(r'\s{2,}', rest, maxsplit=1)[0].strip()
        label = label.replace(' (current)', '').strip()
        if not label:
            continue
        if '›' in prefix or '>' in prefix:
            current_idx = options.index(label) if label in options else len(options)
            cursor_labels.append(label)
        if label not in options:
            options.append(label)

    if len(options) < 2:
        return None

    # Title detection
    box_re = re.compile(r'\[\s+(.+?)\s*\]')
    option_line_re = re.compile(r'^[>\s]*\d+\.\s+')
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
                    candidate = lines[j].strip()
                    if candidate and not option_line_re.match(lines[j]):
                        title = candidate
                        break
                break

    return title, options, current_idx, cursor_labels


def detect_slash_menu(content: str):
    """Same logic as MCPClient._detect_slash_command_menu."""
    lines = [ANSI_RE.sub('', l) for l in content.splitlines()]
    text = '\n'.join(lines)

    if not re.search(r'^[›>]\s+/', text, re.MULTILINE):
        return None

    slash_re = re.compile(r'^\s+(/\w+)\s{2,}(.+)$', re.MULTILINE)
    seen: set = set()
    commands = []
    for cmd, desc in slash_re.findall(text):
        if cmd not in seen:
            seen.add(cmd)
            commands.append((cmd, desc.strip()))

    return commands if len(commands) >= 2 else None


def detect_toggle_menu(content: str):
    """Same logic as MCPClient._detect_toggle_menu."""
    lines = [ANSI_RE.sub('', l) for l in content.splitlines()]
    text = '\n'.join(lines)

    if 'Press space to select' not in text and 'enter to save' not in text:
        return None

    option_re = re.compile(r'^([›>\s]*)\[([x ])\]\s+(.+?)(?:\s{2,}.*)?$', re.MULTILINE)
    options = []
    current_idx = 0
    existing_labels: list = []
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
            options.append((label, checked))

    return (options, current_idx) if options else None


def detect_ansi_highlight(raw_content: str):
    """Scan raw (un-stripped) content for lines with ANSI highlight codes.

    Returns list of (line_no, stripped_text, ansi_codes) for lines that have
    color/bold codes — these are likely the 'selected' rows.
    Highlight codes: bold (1), reverse video (7), any 3x/4x/9x/10x color.
    """
    highlight_re = re.compile(r'\x1b\[([0-9;]*)m')
    results = []
    for i, line in enumerate(raw_content.splitlines()):
        codes = []
        for m in highlight_re.finditer(line):
            for part in m.group(1).split(';'):
                if part:
                    n = int(part)
                    # bold=1, italic=3, underline=4, reverse=7, any color
                    if n in (1, 3, 4, 7) or (30 <= n <= 37) or (40 <= n <= 47) or (90 <= n <= 97) or (100 <= n <= 107):
                        codes.append(n)
        if codes:
            stripped = ANSI_RE.sub('', line).strip()
            if stripped:
                results.append((i, stripped, codes))
    return results


def focus_and_key(tty: str, key_code: int) -> bool:
    safe = tty.replace('"', '\\"')
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
    key code {key_code}
end tell
return true'''
    r = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=8)
    return r.stdout.strip() == 'true'


def find_codex_tty():
    """Find the TTY of a running codex process."""
    r = subprocess.run(
        ['ps', 'aux'],
        capture_output=True, text=True
    )
    for line in r.stdout.splitlines():
        if 'codex' in line and 'node' in line and 'debug_tui' not in line:
            parts = line.split()
            pid = parts[1]
            # lsof to find TTY
            lsof = subprocess.run(
                ['lsof', '-p', pid, '-a', '-d', '0'],
                capture_output=True, text=True
            )
            for lline in lsof.stdout.splitlines():
                if lline.startswith('node') and '/dev/tty' in lline:
                    parts2 = lline.split()
                    for p in parts2:
                        if p.startswith('/dev/tty'):
                            return p
    return None


def do_read(tty: str, verbose: bool = False):
    raw = read_tty_history(tty, tail=0)  # always full history
    content = raw  # already stripped by read_tty_history
    if verbose:
        print('\n─── RAW stripped (all lines) ───')
        for i, line in enumerate(content.splitlines()):
            print(f'{i:3}: {repr(line)}')

    print()

    # --- Detector 1: numbered menu ---
    result = detect_tui(content)
    if result is None:
        has_footer = 'Press enter' in content or 'esc to go back' in content
        print(f'  [numbered]  None  {"(footer present, <2 options)" if has_footer else "(no footer)"}')
    else:
        title, options, current_idx, cursor_labels = result
        cur_label = options[current_idx] if current_idx < len(options) else 'OUT OF BOUNDS'
        print(f'  [numbered]  title={title!r}  idx={current_idx} → {cur_label!r}  options={options}')

    # --- Detector 2: slash command ---
    slash = detect_slash_menu(content)
    if slash is None:
        has_prompt = bool(re.search(r'^[›>]\s+/', content, re.MULTILINE))
        print(f'  [slash]     None  {"(› / found, <2 commands)" if has_prompt else "(no › / line)"}')
    else:
        cmds = [c for c, _ in slash]
        print(f'  [slash]     {len(slash)} commands: {cmds}')

    # --- Detector 3: toggle/checkbox ---
    toggle = detect_toggle_menu(content)
    if toggle is None:
        has_footer = 'Press space' in content or 'enter to save' in content
        print(f'  [toggle]    None  {"(footer present, no options)" if has_footer else "(no footer)"}')
    else:
        options_t, cur_t = toggle
        print(f'  [toggle]    idx={cur_t}  options={options_t}')

    print()
    return content, result, slash, toggle


def main():
    tty = sys.argv[1] if len(sys.argv) > 1 else None
    if not tty:
        print('Auto-detecting codex TTY...')
        tty = find_codex_tty()
        if not tty:
            print('No codex process found. Start codex and try again, or pass TTY as argument.')
            sys.exit(1)
    print(f'Using TTY: {tty}')
    print('Commands: r=detect  R=raw dump  H=last 60 lines  A=raw ANSI  S=highlight scan  u=Up  d=Down  e=Enter  esc=Escape  q=quit\n')

    while True:
        try:
            cmd = input('> ').strip()
        except (EOFError, KeyboardInterrupt):
            break

        if cmd in ('q', 'Q'):
            break
        elif cmd == 'r':
            do_read(tty)
        elif cmd == 'R':
            do_read(tty, verbose=True)
        elif cmd == 'H':
            # Show ONLY the last 60 raw lines without detection
            content = read_tty_history(tty, tail=0)
            lines = content.splitlines()
            print(f'\n─── last 60 of {len(lines)} lines ───')
            for i, line in enumerate(lines[-60:]):
                print(f'{len(lines)-60+i:4}: {repr(line)}')
            print()
        elif cmd in ('s', 'S'):
            # Scan raw ANSI for highlighted lines (bold/color/reverse) — shows cursor signals
            safe = tty.replace('"', '\\"')
            script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe}" then
                    return history of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
            r_raw = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=8)
            raw_content = r_raw.stdout
            highlights = detect_ansi_highlight(raw_content)
            print(f'\n─── ANSI highlight scan: {len(highlights)} highlighted lines ───')
            for lineno, text_s, codes in highlights[-30:]:
                print(f'  {lineno:4}: codes={codes}  text={text_s!r}')
            print()
        elif cmd == 'A':
            # Show last 60 lines with ANSI escape sequences VISIBLE (not stripped)
            # so we can see color codes for slash command highlight detection
            safe = tty.replace('"', '\\"')
            script = f'''tell application "Terminal"
    repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
            set t to tab i of w
            try
                if tty of t is "{safe}" then
                    return history of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell'''
            import subprocess as _sp
            r = _sp.run(['osascript', '-e', script], capture_output=True, text=True, timeout=8)
            raw = r.stdout  # NOT stripped
            lines = raw.split('\n')
            print(f'\n─── RAW ANSI last 40 of {len(lines)} lines ───')
            for i, line in enumerate(lines[-40:]):
                # Make escape sequences visible
                visible = line.replace('\x1b', 'ESC').replace('\r', '<CR>')
                print(f'{len(lines)-40+i:4}: {visible}')
            print()
        elif cmd in ('u', 'U'):
            print('Sending Up (key code 126)...')
            ok = focus_and_key(tty, 126)
            print(f'  focus+key: {ok}')
            time.sleep(0.8)
            do_read(tty, tail=0)
        elif cmd in ('d', 'D'):
            print('Sending Down (key code 125)...')
            ok = focus_and_key(tty, 125)
            print(f'  focus+key: {ok}')
            time.sleep(0.8)
            do_read(tty, tail=0)
        elif cmd in ('e', 'E', 'enter'):
            print('Sending Enter (key code 36)...')
            ok = focus_and_key(tty, 36)
            print(f'  focus+key: {ok}')
            time.sleep(0.5)
            do_read(tty, tail=0)
        elif cmd in ('esc', 'ESC'):
            print('Sending Escape (key code 53)...')
            ok = focus_and_key(tty, 53)
            print(f'  focus+key: {ok}')
            time.sleep(0.5)
            do_read(tty, tail=0)
        else:
            print('Unknown command. r / R / H / A / S / u / d / e / esc / q')


if __name__ == '__main__':
    main()
