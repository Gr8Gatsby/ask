#!/usr/bin/env python3
"""
Real tmux integration tests for claudecode-controller.

Each test starts an actual blocking process in a tmux pane — the same way
Claude Code runs — and verifies _parse_tmux_prompt detects (or ignores) the
output while the process is still alive and waiting for input.

This is the important distinction from static-string tests: the pane has no
trailing shell prompt (the process is blocking), and real programs can emit
ANSI escape sequences that the parser must strip.

All tests are skipped when tmux is not installed.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import uuid

import pytest

# ── Skip if tmux not available ────────────────────────────────────────────────

pytestmark = pytest.mark.skipif(
    shutil.which('tmux') is None,
    reason='tmux not installed'
)

# ── Load _parse_tmux_prompt from main.py ─────────────────────────────────────

MAIN_PY = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py'
)

import importlib.util

def _load_mcp_client():
    import io
    old_stdin = sys.stdin
    sys.stdin = io.StringIO('{}')
    devnull_fd = os.open(os.devnull, os.O_WRONLY)
    saved_stdout_fd = os.dup(sys.stdout.fileno())
    os.dup2(devnull_fd, sys.stdout.fileno())
    os.close(devnull_fd)
    module = None
    try:
        spec = importlib.util.spec_from_file_location('main_mod', MAIN_PY)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except (SystemExit, Exception):
        pass
    finally:
        os.dup2(saved_stdout_fd, sys.stdout.fileno())
        os.close(saved_stdout_fd)
        sys.stdin = old_stdin
    if module is None or not hasattr(module, 'MCPClient'):
        raise RuntimeError('Could not load MCPClient from main.py')
    return module.MCPClient

try:
    MCPClient = _load_mcp_client()
    _parse_tmux_prompt = MCPClient._parse_tmux_prompt
except Exception as e:
    _parse_tmux_prompt = None
    MCPClient = None
    pytestmark = pytest.mark.skip(reason=f'Could not load MCPClient: {e}')


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def tmux_session():
    """Create a detached tmux session with plain bash.

    bash --norc --noprofile avoids shell-plugin prompts (oh-my-zsh etc.)
    that could interfere with prompt detection tests.
    """
    name = f'ask-test-{uuid.uuid4().hex[:8]}'
    subprocess.run(
        ['tmux', 'new-session', '-d', '-s', name, 'bash', '--norc', '--noprofile'],
        check=True,
    )
    time.sleep(0.2)
    yield name
    subprocess.run(['tmux', 'kill-session', '-t', name], capture_output=True)


def capture_pane(session_name: str) -> str:
    """Capture the visible content of the tmux pane."""
    r = subprocess.run(
        ['tmux', 'capture-pane', '-p', '-t', session_name],
        capture_output=True, text=True,
    )
    return r.stdout


def run_blocking_script(session_name: str, script: str, startup_wait: float = 0.4):
    """Write a Python script to a temp file and run it in the tmux pane.

    The script should print its output then block (e.g. sys.stdin.readline()).
    We return once the process is started and waiting for input — the pane
    now shows the script's output with no trailing shell prompt, exactly as
    a real interactive TUI looks.
    """
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False)
    tmp.write(textwrap.dedent(script))
    tmp.close()
    subprocess.run(
        ['tmux', 'send-keys', '-t', session_name, f'python3 {tmp.name}', 'Enter'],
    )
    time.sleep(startup_wait)
    return tmp.name


def cleanup_script(path: str):
    try:
        os.unlink(path)
    except Exception:
        pass


# ── Tests: real blocking programs ─────────────────────────────────────────────

def test_numbered_menu_real_program(tmux_session):
    """Numbered menu from a real blocking process is detected as mode='numbered'.

    The process is still running when we capture — no trailing shell prompt.
    This is the same state as when Claude Code is showing a selection menu.
    """
    script_path = run_blocking_script(tmux_session, """
        import sys
        sys.stdout.write(
            '  1. Option Alpha\\n'
            '  2. Option Beta\\n'
            '  3. Option Gamma\\n'
            'Press enter to confirm'
        )
        sys.stdout.flush()
        sys.stdin.readline()  # block — process stays alive, no shell prompt returns
    """)

    content = capture_pane(tmux_session)
    # Verify the pane shows the process is still running (no trailing $ prompt)
    lines = [l for l in content.splitlines() if l.strip()]
    assert not lines[-1].endswith('$'), (
        'Shell prompt returned — process exited before we captured. '
        f'Pane content:\n{content}'
    )

    result = _parse_tmux_prompt(content)
    assert result is not None, f'Expected numbered menu detection; pane:\n{content}'
    body, options, mode = result
    assert mode == 'numbered'
    assert any('Alpha' in o for o in options)
    assert any('Beta' in o for o in options)
    assert any('Gamma' in o for o in options)
    cleanup_script(script_path)


def test_yn_prompt_real_program(tmux_session):
    """y/n prompt from a real blocking process is detected as mode='yn'."""
    script_path = run_blocking_script(tmux_session, """
        import sys
        sys.stdout.write('Do you want to proceed? (y/n) › ')
        sys.stdout.flush()
        sys.stdin.readline()
    """)

    content = capture_pane(tmux_session)
    result = _parse_tmux_prompt(content)
    assert result is not None, f'Expected yn prompt; pane:\n{content}'
    _, options, mode = result
    assert mode == 'yn'
    assert options == ['Yes', 'No']
    cleanup_script(script_path)


def test_arrow_menu_real_program(tmux_session):
    """Arrow-key menu (❯ prefix) from a real blocking process is detected as mode='arrow'."""
    script_path = run_blocking_script(tmux_session, """
        import sys
        sys.stdout.write(
            'Trust the files in this folder?\\n'
            '  ~/Documents/code/myproject\\n\\n'
            '\\u276f Yes, proceed\\n'
            '  No, exit'
        )
        sys.stdout.flush()
        sys.stdin.readline()
    """)

    content = capture_pane(tmux_session)
    result = _parse_tmux_prompt(content)
    assert result is not None, f'Expected arrow prompt; pane:\n{content}'
    _, options, mode = result
    assert mode == 'arrow'
    assert any('Yes' in o for o in options)
    assert any('No' in o for o in options)
    cleanup_script(script_path)


def test_ansi_escape_codes_do_not_break_detection(tmux_session):
    """Parser correctly handles ANSI color/cursor codes from real TUI frameworks.

    Real Claude Code (built on Ink/React) emits ANSI sequences for colors and
    cursor positioning. This test verifies we strip them and still detect the menu.
    The ANSI codes here mirror what Ink produces for a selection list.
    """
    script_path = run_blocking_script(tmux_session, r"""
        import sys
        # ANSI sequences matching what Ink/Claude Code produces:
        # \033[32m = green, \033[39m = default fg, \033[1m = bold, \033[22m = normal
        GREEN   = '\033[32m'
        RESET   = '\033[39m'
        BOLD    = '\033[1m'
        NORMAL  = '\033[22m'
        CLEAR_LINE = '\033[2K\033[1G'  # clear line + go to col 1 (Ink cursor moves)

        sys.stdout.write(
            f'{BOLD}Choose an action:{NORMAL}\n'
            f'{CLEAR_LINE}{GREEN}\u276f{RESET} Yes, proceed\n'
            f'{CLEAR_LINE}  No, exit\n'
        )
        sys.stdout.flush()
        sys.stdin.readline()
    """)

    content = capture_pane(tmux_session)
    result = _parse_tmux_prompt(content)
    assert result is not None, (
        'Parser failed to detect arrow menu with ANSI escape codes. '
        f'Pane content:\n{content}'
    )
    _, options, mode = result
    assert mode == 'arrow', f'Expected arrow mode, got {mode!r}'
    assert any('Yes' in o for o in options), f'Expected Yes option; got {options}'
    assert any('No' in o for o in options), f'Expected No option; got {options}'
    # Verify ANSI codes were not included in the option text
    for opt in options:
        assert '\033' not in opt, f'ANSI escape leaked into option: {opt!r}'
    cleanup_script(script_path)


def test_plain_terminal_output_not_detected(tmux_session):
    """Normal command output from a real process does not trigger any format.

    Run a real git-status-like output to verify no false positives.
    """
    script_path = run_blocking_script(tmux_session, """
        import sys
        sys.stdout.write(
            'On branch main\\n'
            'Your branch is up to date with origin/main.\\n\\n'
            'nothing to commit, working tree clean\\n'
        )
        sys.stdout.flush()
        sys.stdin.readline()
    """)

    content = capture_pane(tmux_session)
    result = _parse_tmux_prompt(content)
    assert result is None, (
        f'Plain output falsely detected as a prompt: {result}; pane:\n{content}'
    )
    cleanup_script(script_path)


def test_keystroke_delivery_to_real_process(tmux_session):
    """Keystrokes sent via tmux send-keys reach the blocking process.

    This verifies the reply path: after the user taps an option on iPhone,
    we send keystrokes to the pane and the process receives them.
    """
    tmp = tempfile.NamedTemporaryFile(suffix='.txt', delete=False)
    tmp.close()

    script_path = run_blocking_script(tmux_session, f"""
        import sys
        sys.stdout.write('Ready\\n')
        sys.stdout.flush()
        line = sys.stdin.readline().strip()
        open({repr(tmp.name)}, 'w').write(line)
    """, startup_wait=0.5)

    # Now send a keystroke — this is what _on_tmux_prompt_reply does
    subprocess.run(['tmux', 'send-keys', '-t', tmux_session, 'hello', 'Enter'])
    time.sleep(0.5)

    assert os.path.exists(tmp.name), 'Process did not receive keystroke (file not written)'
    with open(tmp.name) as f:
        received = f.read()
    assert received == 'hello', f'Expected "hello", got {received!r}'

    cleanup_script(script_path)
    try:
        os.unlink(tmp.name)
    except Exception:
        pass


def test_numbered_menu_with_gt_arrow_prefix(tmux_session):
    """Arrow menu using ASCII '>' prefix (not ❯) is also detected."""
    script_path = run_blocking_script(tmux_session, """
        import sys
        sys.stdout.write('> Accept changes\\n  Reject changes')
        sys.stdout.flush()
        sys.stdin.readline()
    """)

    content = capture_pane(tmux_session)
    result = _parse_tmux_prompt(content)
    assert result is not None, f'Expected arrow prompt with > prefix; pane:\n{content}'
    _, options, mode = result
    assert mode == 'arrow'
    cleanup_script(script_path)


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
