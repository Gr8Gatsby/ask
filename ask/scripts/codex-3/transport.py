#!/usr/bin/env python3
"""
codex-3 transport utilities.

Repo discovery and Codex launch helpers. Terminal session management
(liveness checks, send_text, discover sessions) is handled by terminal-manager
via MCP; see main.py for the async routing calls.
"""
import os
import shlex
import subprocess
from typing import Optional


REPO_SEARCH_DIRS = [
    os.path.expanduser('~/Documents/code'),
    os.path.expanduser('~/code'),
    os.path.expanduser('~/projects'),
    os.path.expanduser('~/Developer'),
]

CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')


def _find_tmux_bin() -> str:
    for path in ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']:
        if os.path.isfile(path):
            return path
    return 'tmux'


_TMUX = _find_tmux_bin()


def _get_pane_pid(target: str) -> int:
    try:
        result = subprocess.run(
            [_TMUX, 'display-message', '-p', '-t', target, '#{pane_pid}'],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except Exception:
        pass
    return 0


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

    has_session = subprocess.run([_TMUX, 'has-session', '-t', 'codex'], capture_output=True, timeout=3)
    if has_session.returncode == 0:
        windows = subprocess.run(
            [_TMUX, 'list-windows', '-t', 'codex', '-F', '#{window_name}'],
            capture_output=True, text=True, timeout=3,
        )
        existing = windows.stdout.strip().splitlines() if windows.returncode == 0 else []
        if project not in existing:
            subprocess.run(
                [_TMUX, 'new-window', '-t', 'codex', '-c', repo_path, '-n', project, shell, '-l', '-c', shell_cmd],
                capture_output=True, text=True, timeout=5,
            )
    else:
        subprocess.run(
            [_TMUX, 'new-session', '-d', '-s', 'codex', '-c', repo_path, '-n', project, shell, '-l', '-c', shell_cmd],
            capture_output=True, text=True, timeout=5,
        )

    pane_target = f'codex:{project}.0'
    if interactive:
        try:
            win_target = pane_target.rsplit('.', 1)[0]
            subprocess.run([_TMUX, 'select-window', '-t', win_target], capture_output=True, timeout=3)
            attach_cmd = 'for i in 1 2 3 4 5; do tmux attach-session -t codex && break; sleep 1; done; exit'
            script = f'tell application "Terminal" to do script "{attach_cmd}"'
            subprocess.Popen(['osascript', '-e', script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    return {
        'project': project,
        'cwd': repo_path,
        'tmux_target': pane_target,
        'pid': _get_pane_pid(pane_target),
        'is_headless': not interactive,
    }
