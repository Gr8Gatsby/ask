#!/usr/bin/env python3
import os
import shlex
import subprocess
import time
from typing import Optional, Set


REPO_SEARCH_DIRS = [
    os.path.expanduser('~/Documents/code'),
    os.path.expanduser('~/code'),
    os.path.expanduser('~/projects'),
    os.path.expanduser('~/Developer'),
]

CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')


def find_tmux_bin() -> str:
    for path in ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']:
        if os.path.isfile(path):
            return path
    return 'tmux'


TMUX = find_tmux_bin()


def _is_codex_pane(current_command: str, start_command: str, title: str, session_name: str = '') -> bool:
    for value in (current_command or '', start_command or '', title or '', session_name or ''):
        if 'codex' in value.lower():
            return True
    return False


def find_tmux_target_for_tty(tty: str) -> dict:
    """Return pane info dict for a given TTY, or {} if not in tmux.

    Keys: tmux_target, cwd, project
    """
    full_tty = f'/dev/{tty}' if not tty.startswith('/') else tty
    try:
        result = subprocess.run(
            [TMUX, 'list-panes', '-a', '-F',
             '#{session_name}:#{window_name}.#{pane_index}\t#{pane_tty}\t#{pane_current_path}\t#{window_name}'],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode != 0:
            return {}
        for line in result.stdout.splitlines():
            parts = line.split('\t')
            if len(parts) == 4 and parts[1] == full_tty:
                target, _, cwd, window_name = parts
                project = os.path.basename(cwd.rstrip('/')) if cwd else window_name
                return {'tmux_target': target, 'cwd': cwd, 'project': project}
    except Exception:
        pass
    return {}


def _get_process_cwd(pid: int) -> str:
    try:
        result = subprocess.run(
            ['lsof', '-p', str(pid), '-d', 'cwd', '-Fn'],
            capture_output=True, text=True, timeout=3,
        )
        for line in result.stdout.splitlines():
            if line.startswith('n'):
                return line[1:]
    except Exception:
        pass
    return ''


def discover_codex_processes() -> list[dict]:
    """Scan running processes for live Codex instances in non-tmux TTYs."""
    try:
        result = subprocess.run(
            ['ps', '-eo', 'pid,tty,comm'],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return []
    processes = []
    for line in result.stdout.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid_str, tty, comm = parts
        if tty == '??' or not pid_str.strip().isdigit():
            continue
        if 'codex' not in comm.lower():
            continue
        pid = int(pid_str.strip())
        cwd = _get_process_cwd(pid)
        processes.append({
            'pid': pid,
            'tty': tty,
            'cwd': cwd,
            'project': os.path.basename(cwd.rstrip('/')) if cwd else f'codex-{tty}',
        })
    return processes


def tty_exists(tty: str) -> bool:
    # macOS ps reports TTY as 's004'; the device is at /dev/ttys004
    return os.path.exists(f'/dev/{tty}') or os.path.exists(f'/dev/tty{tty}')


def discover_codex_panes(exclude_targets: Optional[Set[str]] = None) -> list[dict]:
    exclude_targets = exclude_targets or set()
    try:
        result = subprocess.run(
            [
                TMUX,
                'list-panes',
                '-a',
                '-F',
                '#{session_name}:#{window_name}.#{pane_index}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}\t#{pane_title}\t#{pane_start_command}',
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except Exception:
        return []
    if result.returncode != 0:
        return []

    panes = []
    seen = set()
    for raw in result.stdout.splitlines():
        parts = raw.split('\t')
        if len(parts) != 6:
            continue
        target, cwd, current_command, pid, title, start_command = parts
        if target in exclude_targets or target in seen:
            continue
        session_name = target.split(':')[0] if ':' in target else ''
        if not _is_codex_pane(current_command, start_command, title, session_name):
            continue
        seen.add(target)
        panes.append({
            'tmux_target': target,
            'cwd': cwd,
            'project': os.path.basename((cwd or '').rstrip('/')) or target.rsplit(':', 1)[-1],
            'pid': int(pid) if str(pid).isdigit() else 0,
        })
    panes.sort(key=lambda item: (item['project'].lower(), item['tmux_target']))
    return panes


def get_pane_pid(target: str) -> int:
    try:
        result = subprocess.run(
            [TMUX, 'display-message', '-p', '-t', target, '#{pane_pid}'],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except Exception:
        pass
    return 0


def pane_exists(target: str) -> bool:
    try:
        result = subprocess.run(
            [TMUX, 'list-panes', '-t', target],
            capture_output=True, text=True, timeout=3,
        )
        return result.returncode == 0
    except Exception:
        return False


def send_text(target: str, text: str) -> bool:
    if not target:
        return False
    try:
        subprocess.run([TMUX, 'send-keys', '-t', target, '-l', text], capture_output=True, timeout=3, check=False)
        time.sleep(0.05)  # give codex TUI time to render before Enter fires
        subprocess.run([TMUX, 'send-keys', '-t', target, 'Enter'], capture_output=True, timeout=3, check=False)
        return True
    except Exception:
        return False


def send_interrupt(target: str) -> bool:
    if not target:
        return False
    try:
        subprocess.run([TMUX, 'send-keys', '-t', target, 'C-c'], capture_output=True, timeout=3, check=False)
        return True
    except Exception:
        return False


def send_quit(target: str) -> bool:
    if not target:
        return False
    try:
        subprocess.run([TMUX, 'send-keys', '-t', target, 'C-c'], capture_output=True, timeout=3, check=False)
        subprocess.run([TMUX, 'send-keys', '-t', target, 'C-c'], capture_output=True, timeout=3, check=False)
        subprocess.run([TMUX, 'send-keys', '-t', target, '/quit', 'Enter'], capture_output=True, timeout=3, check=False)
        return True
    except Exception:
        return False


def ensure_repo_trusted(repo_path: str):
    try:
        content = open(CODEX_CONFIG_PATH).read() if os.path.exists(CODEX_CONFIG_PATH) else ''
    except Exception:
        content = ''
    if f'[projects."{repo_path}"]' in content:
        return
    entry = f'\n[projects."{repo_path}"]\ntrust_level = "trusted"\n'
    try:
        os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
        with open(CODEX_CONFIG_PATH, 'a') as handle:
            handle.write(entry)
    except Exception:
        pass


def find_repos() -> list[tuple[str, str]]:
    repos = []
    seen = set()
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


def resolve_codex_bin() -> str:
    candidates = [
        os.path.expanduser('~/.local/bin/codex'),
        os.path.expanduser('~/.npm-global/bin/codex'),
    ]
    try:
        nvm_base = os.path.expanduser('~/.nvm/versions/node')
        if os.path.isdir(nvm_base):
            latest = sorted(os.listdir(nvm_base))[-1]
            candidates.insert(0, os.path.join(nvm_base, latest, 'bin', 'codex'))
    except Exception:
        pass
    for path in candidates:
        if os.path.isfile(path):
            return path
    return 'codex'


def launch_codex(repo_path: str, socket_path: str, install_hooks, interactive: bool = True) -> dict:
    project = os.path.basename(repo_path.rstrip('/'))
    repo_path = os.path.expanduser(repo_path)
    codex_bin = resolve_codex_bin()

    ensure_repo_trusted(repo_path)
    install_hooks()

    shell = os.environ.get('SHELL', '/bin/zsh')
    node_bin_dir = shlex.quote(os.path.dirname(codex_bin))
    path_prefix = f'{node_bin_dir}:/opt/homebrew/bin:/usr/local/bin'
    shell_cmd = (
        f'export PATH={path_prefix}:$PATH; '
        f'export ASK_SOCKET_PATH={shlex.quote(socket_path)}; '
        f'cd {shlex.quote(repo_path)} && exec {shlex.quote(codex_bin)}'
    )

    has_session = subprocess.run([TMUX, 'has-session', '-t', 'codex'], capture_output=True, timeout=3)
    if has_session.returncode == 0:
        windows = subprocess.run(
            [TMUX, 'list-windows', '-t', 'codex', '-F', '#{window_name}'],
            capture_output=True, text=True, timeout=3,
        )
        existing = windows.stdout.strip().splitlines() if windows.returncode == 0 else []
        if project not in existing:
            subprocess.run(
                [TMUX, 'new-window', '-t', 'codex', '-c', repo_path, '-n', project, shell, '-l', '-c', shell_cmd],
                capture_output=True, text=True, timeout=5,
            )
    else:
        subprocess.run(
            [TMUX, 'new-session', '-d', '-s', 'codex', '-c', repo_path, '-n', project, shell, '-l', '-c', shell_cmd],
            capture_output=True, text=True, timeout=5,
        )

    pane_target = f'codex:{project}.0'
    if interactive:
        try:
            win_target = pane_target.rsplit('.', 1)[0]
            subprocess.run([TMUX, 'select-window', '-t', win_target], capture_output=True, timeout=3)
            attach_cmd = 'for i in 1 2 3 4 5; do tmux attach-session -t codex && break; sleep 1; done; exit'
            script = f'tell application "Terminal" to do script "{attach_cmd}"'
            subprocess.Popen(['osascript', '-e', script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    return {
        'project': project,
        'cwd': repo_path,
        'tmux_target': pane_target,
        'pid': get_pane_pid(pane_target),
        'is_headless': not interactive,
    }
