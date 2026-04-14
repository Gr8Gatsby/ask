#!/usr/bin/env python3
"""
codex-2 — Codex CLI session supervisor using terminal-manager for TUI detection.

Differences from codex-controller:
  - No inline terminal reading or TUI detection code
  - All terminal I/O delegated to terminal-manager via AskMac MCP proxy
  - Simpler session model: one block per session, updated on each TUI poll
"""

import sys
import json
import asyncio
import os
import shlex
import subprocess
import uuid
import datetime

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
SOCKET_PATH  = os.environ.get('ASK_SOCKET_PATH',
               os.path.expanduser('~/.ask/sockets/codex-2.sock'))
LOG_PATH     = os.path.expanduser('~/.ask/logs/codex-2.log')
TILE_ID               = 'codex-2-tile'
START_SESSION_BLOCK_ID = 'codex2-start'
# Paths are overridable via env vars for testing
SETTINGS_PATH      = os.environ.get('ASK_CODEX2_SETTINGS_PATH',
                     os.path.expanduser('~/.ask/codex2-settings.json'))
ALLOWLIST_PATH     = os.environ.get('ASK_CODEX2_ALLOWLIST_PATH',
                     os.path.expanduser('~/.ask/codex_allowlist.json'))
PERMISSION_MODE_PATH = os.environ.get('ASK_CODEX2_PERMISSION_MODE_PATH',
                     os.path.expanduser('~/.ask/codex_permission_mode.json'))
ACTIVE_BLOCKS_PATH = os.environ.get('ASK_CODEX2_ACTIVE_BLOCKS_PATH',
                     os.path.expanduser('~/.ask/codex2-active-blocks.json'))
SESSIONS_PATH      = os.environ.get('ASK_CODEX2_SESSIONS_PATH',
                     os.path.expanduser('~/.ask/codex2-sessions.json'))
CODEX_HOOKS_PATH   = os.environ.get('ASK_CODEX2_HOOKS_PATH',
                     os.path.expanduser('~/.codex/hooks.json'))
# Set ASK_CODEX2_SKIP_DISCOVERY=1 in tests to skip tmux scanning
_SKIP_DISCOVERY    = os.environ.get('ASK_CODEX2_SKIP_DISCOVERY') == '1'
MAX_RECENT_REPOS      = 5
SESSION_TTL           = 300  # heartbeat refreshes every 30s; 300s gives buffer for MCP hiccups

# Common repo search roots — scanned by start_session picker
REPO_SEARCH_DIRS = [
    os.path.expanduser('~/Documents/code'),
    os.path.expanduser('~/code'),
    os.path.expanduser('~/projects'),
    os.path.expanduser('~/Developer'),
]

CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')

# Resolve tmux at startup — Homebrew installs to /opt/homebrew/bin which isn't
# in AskMac's restricted PATH.
def _find_tmux_bin() -> str:
    for p in ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']:
        if os.path.isfile(p):
            return p
    return 'tmux'  # fallback: hope it's in PATH

TMUX = _find_tmux_bin()


# ── Tool name helpers ─────────────────────────────────────────────────────────

# Map Codex CLI tool names → iOS display names (must match toolIcon/toolActivityText in RemoteKitModels.swift)
_CODEX_TOOL_MAP = {
    'shell':        'Bash',
    'bash':         'Bash',
    'computer':     'Bash',
    'read_file':    'Read',
    'file_read':    'Read',
    'write_file':   'Write',
    'file_write':   'Write',
    'edit_file':    'Edit',
    'file_edit':    'Edit',
    'str_replace':  'Edit',
    'web_search':   'Grep',
    'search':       'Grep',
}

def _map_tool_name(tool: str) -> str:
    if not tool:
        return 'Bash'
    return _CODEX_TOOL_MAP.get(tool.lower(), tool)


# ── Process helpers ───────────────────────────────────────────────────────────

def _pid_running(pid: int) -> bool:
    """Return True if the process with the given PID is still alive."""
    if not pid:
        return True  # unknown — assume alive
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists but not ours to signal


def _get_pane_pid(target: str) -> int:
    """Return the PID of the foreground process in a tmux pane."""
    try:
        r = subprocess.run(
            [TMUX, 'display-message', '-p', '-t', target, '#{pane_pid}'],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0:
            return int(r.stdout.strip())
    except Exception:
        pass
    return 0


def _get_pane_cwd(target: str) -> str:
    """Return the current working directory of a tmux pane."""
    try:
        r = subprocess.run(
            [TMUX, 'display-message', '-p', '-t', target, '#{pane_current_path}'],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return ''


def _get_pane_command(target: str) -> str:
    """Return the foreground command running in a tmux pane."""
    try:
        r = subprocess.run(
            [TMUX, 'display-message', '-p', '-t', target, '#{pane_current_command}'],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return ''


# ── Logging ───────────────────────────────────────────────────────────────────

def _log(msg: str, level: str = 'INFO'):
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [{level}] {msg}"
    print(line, file=sys.stderr)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


# ── Terminal-manager hook config ──────────────────────────────────────────────

CODEX_HOOK = {
    'scan_lines': 80,
    'patterns': [
        {
            'id': 'numbered_menu',
            'detect': {
                'type': 'numbered_menu',
                'footers': ['Press enter to confirm', 'Press enter to continue', 'esc to go back'],
            },
        },
        {
            'id': 'slash_commands',
            'detect': {
                'type': 'slash_command_list',
                'commands': [
                    {'cmd': '/model',        'desc': 'choose model and reasoning effort'},
                    {'cmd': '/fast',         'desc': 'toggle Fast mode'},
                    {'cmd': '/permissions',  'desc': 'choose what Codex is allowed to do'},
                    {'cmd': '/experimental', 'desc': 'toggle experimental features'},
                    {'cmd': '/skills',       'desc': 'use skills to improve Codex'},
                    {'cmd': '/review',       'desc': 'review changes and find issues'},
                    {'cmd': '/rename',       'desc': 'rename the current thread'},
                    {'cmd': '/new',          'desc': 'start a new chat'},
                    {'cmd': '/agent',        'desc': 'switch agent'},
                    {'cmd': '/diff',         'desc': 'show diff'},
                    {'cmd': '/copy',         'desc': 'copy to clipboard'},
                    {'cmd': '/status',       'desc': 'show status'},
                    {'cmd': '/compact',      'desc': 'compact context'},
                    {'cmd': '/plan',         'desc': 'show plan'},
                ],
            },
        },
        {
            'id': 'toggle_menu',
            'detect': {
                'type': 'checkbox_menu',
                'footers': ['Press space to select', 'enter to save'],
            },
        },
        {
            'id': 'screen_metadata',
            'detect': {'type': 'screen_metadata'},
        },
    ],
}


# ── Hook installer ────────────────────────────────────────────────────────────

def _install_hooks():
    _ensure_config_flag()
    _write_hooks_json()


def _ensure_config_flag():
    os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
    try:
        content = open(CODEX_CONFIG_PATH).read() if os.path.exists(CODEX_CONFIG_PATH) else ''
    except Exception:
        content = ''
    if 'codex_hooks' not in content:
        try:
            with open(CODEX_CONFIG_PATH, 'a') as f:
                f.write('\n[features]\ncodex_hooks = true\n')
        except Exception as e:
            _log(f'Could not update config.toml: {e}', 'WARN')


def _write_hooks_json():
    py = sys.executable
    hooks_dir = os.path.join(SCRIPT_DIR, 'hooks')
    our_hooks = {
        'SessionStart': [{'hooks': [{'type': 'command',
            'command': f'{py} {os.path.join(hooks_dir, "session_start.py")}'}]}],
        'PreToolUse': [{'hooks': [{'type': 'command',
            'command': f'{py} {os.path.join(hooks_dir, "pre_tool_use.py")}'}]}],
        'PostToolUse': [{'hooks': [{'type': 'command',
            'command': f'{py} {os.path.join(hooks_dir, "post_tool_use.py")}'}]}],
        'Stop': [{'hooks': [{'type': 'command',
            'command': f'{py} {os.path.join(hooks_dir, "session_stop.py")}'}]}],
        'UserPromptSubmit': [{'hooks': [{'type': 'command',
            'command': f'{py} {os.path.join(hooks_dir, "user_prompt_submit.py")}'}]}],
    }
    # Read existing hooks and merge — preserve any hooks not ours
    existing = {}
    try:
        with open(CODEX_HOOKS_PATH) as f:
            existing = json.load(f).get('hooks', {})
    except Exception:
        pass
    merged = dict(existing)
    for event, hook_list in our_hooks.items():
        our_cmd = hook_list[0]['hooks'][0]['command']
        # Check if our hook is already registered for this event
        existing_for_event = existing.get(event, [])
        already_registered = any(
            h.get('command') == our_cmd
            for entry in existing_for_event
            for h in entry.get('hooks', [])
        )
        if not already_registered:
            # Prepend our hook to existing hooks for this event
            merged[event] = hook_list + existing_for_event
    os.makedirs(os.path.dirname(CODEX_HOOKS_PATH), exist_ok=True)
    try:
        with open(CODEX_HOOKS_PATH, 'w') as f:
            json.dump({'hooks': merged}, f, indent=2)
        _log(f'Updated hooks at {CODEX_HOOKS_PATH}')
    except Exception as e:
        _log(f'Could not write hooks.json: {e}', 'WARN')


# ── Settings ──────────────────────────────────────────────────────────────────

def _load_settings_file() -> dict:
    try:
        with open(SETTINGS_PATH) as f:
            return json.load(f)
    except Exception:
        return {'interactive': True}


def _save_settings_file(settings: dict):
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    try:
        with open(SETTINGS_PATH, 'w') as f:
            json.dump(settings, f, indent=2)
    except Exception as e:
        _log(f'Could not save settings: {e}', 'WARN')


def _load_permission_mode() -> str:
    try:
        with open(PERMISSION_MODE_PATH) as f:
            mode = json.load(f).get('mode', 'supervised')
        return mode if mode in ('supervised', 'full-auto') else 'supervised'
    except Exception:
        return 'supervised'


def _save_permission_mode(mode: str):
    os.makedirs(os.path.dirname(PERMISSION_MODE_PATH), exist_ok=True)
    try:
        with open(PERMISSION_MODE_PATH, 'w') as f:
            json.dump({'mode': mode}, f, indent=2)
    except Exception as e:
        _log(f'Could not save permission mode: {e}', 'WARN')


def _append_allowlist(preview: str):
    """Append a command preview to the persistent allowlist."""
    try:
        data = {'patterns': []}
        try:
            with open(ALLOWLIST_PATH) as f:
                data = json.load(f)
        except Exception:
            pass
        patterns = data.setdefault('patterns', [])
        if preview not in patterns:
            patterns.append(preview)
            with open(ALLOWLIST_PATH, 'w') as f:
                json.dump(data, f, indent=2)
            _log(f'Allowlisted: {preview[:60]!r}')
    except Exception as e:
        _log(f'Could not save allowlist: {e}', 'WARN')


def _update_recent_repos(settings: dict, path: str) -> dict:
    """Move path to the front of recent_repos in settings."""
    recent = settings.get('recent_repos', [])
    if path in recent:
        recent.remove(path)
    recent.insert(0, path)
    settings['recent_repos'] = recent[:MAX_RECENT_REPOS]
    return settings


def _load_active_blocks() -> set:
    try:
        with open(ACTIVE_BLOCKS_PATH) as f:
            return set(json.load(f))
    except Exception:
        return set()


def _save_active_blocks(block_ids: set):
    try:
        with open(ACTIVE_BLOCKS_PATH, 'w') as f:
            json.dump(list(block_ids), f)
    except Exception:
        pass


def _load_sessions() -> dict:
    """Return persisted sessions dict, pruning stale entries (older than SESSION_TTL)."""
    try:
        with open(SESSIONS_PATH) as f:
            raw = json.load(f)
        now = datetime.datetime.now().timestamp()
        return {
            sid: info for sid, info in raw.items()
            if info.get('last_seen') and (now - info['last_seen']) < SESSION_TTL
        }
    except Exception:
        return {}


def _save_sessions(sessions: dict):
    """Persist sessions dict to disk; silently ignore errors."""
    try:
        os.makedirs(os.path.dirname(SESSIONS_PATH), exist_ok=True)
        with open(SESSIONS_PATH, 'w') as f:
            json.dump(sessions, f)
    except Exception:
        pass


# ── Helpers ───────────────────────────────────────────────────────────────────

def _find_tmux_target(cwd: str = '') -> str:
    """Return 'session:window_index.pane' for a Codex pane in the 'codex' session.

    Uses window index (not name) so the target stays valid even if tmux auto-renames
    the window. If cwd is provided, prefers the window whose current path matches exactly.
    Falls back to the first codex/node pane found.
    """
    try:
        r = subprocess.run(
            [TMUX, 'list-panes', '-t', 'codex', '-a', '-F',
             '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}'],
            capture_output=True, text=True, timeout=3,
        )
        candidates = []
        for line in r.stdout.strip().splitlines():
            parts = line.split(' ', 2)
            if len(parts) < 2:
                continue
            target = parts[0]
            cmd = parts[1].lower()
            pane_cwd = parts[2].strip() if len(parts) > 2 else ''
            if cmd not in ('node', 'codex'):
                continue
            if cwd and pane_cwd == cwd:
                return target  # exact cwd match — highest priority
            candidates.append(target)
        if candidates:
            return candidates[0]
    except Exception:
        pass
    return ''


def _tty_to_dev(tty: str) -> str:
    """Normalise 's003' → '/dev/ttys003'."""
    if not tty:
        return ''
    if tty.startswith('/dev/'):
        return tty
    return f'/dev/tty{tty}'


def _ensure_repo_trusted(repo_path: str):
    """Add repo_path to ~/.codex/config.toml trusted projects if not already present."""
    try:
        content = open(CODEX_CONFIG_PATH).read() if os.path.exists(CODEX_CONFIG_PATH) else ''
    except Exception:
        content = ''
    # Check if path already trusted
    if f'[projects."{repo_path}"]' in content:
        return
    entry = f'\n[projects."{repo_path}"]\ntrust_level = "trusted"\n'
    try:
        os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
        with open(CODEX_CONFIG_PATH, 'a') as f:
            f.write(entry)
        _log(f'Auto-trusted repo: {repo_path}')
    except Exception as e:
        _log(f'Could not update config.toml: {e}', 'WARN')


# ── Repo discovery ───────────────────────────────────────────────────────────

def _find_repos() -> list:
    """Return [(display_name, abs_path)] for git repos in common locations."""
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


# ── Main controller ───────────────────────────────────────────────────────────

class CodexController:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}          # rpc_id → Future
        self._pending_permissions = {}    # block_id → Future (for permission_request)
        self._sessions = {}               # stable_id → {cwd, tty, tmux_target, is_working, ...}
        self._tm_sessions = {}            # stable_id → tm_session_id (registered with TM)
        self._poll_tasks = {}             # stable_id → asyncio.Task
        self._real_to_stable = {}         # hook UUID → stable tmux-based session_id
        self._start_repos = {}            # display name → abs path (populated by start_session)
        self._initialized = False
        # Persistent settings (last-used interactive mode, etc.)
        self._settings = _load_settings_file()
        self._pending_launches: dict = {}   # launch_id → repo_path
        self._active_perm_blocks: set = set()
        # Deduplication: last payload hash per block_id — skip emit if unchanged
        self._last_payload_hash = {}      # block_id → sha256 hex
        # Debounce: pending tile-emit tasks per session
        self._tile_debounce_tasks = {}    # session_id → asyncio.Task

    # ── MCP outbound ──────────────────────────────────────────────────────────

    def _write(self, obj: dict):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method: str, params: dict = None) -> dict:
        rpc_id = self._next_id = self._next_id + 1
        fut = asyncio.get_running_loop().create_future()
        self._pending_calls[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._write(msg)
        return await asyncio.wait_for(fut, timeout=15.0)

    async def _call_tool(self, name: str, args: dict) -> dict:
        result = await self._rpc('tools/call', {'name': name, 'arguments': args})
        # AskMac wraps result in {"content": [{"type": "text", "text": "..."}]}
        # or returns the dict directly for proxied system tools.
        if isinstance(result, dict) and 'content' not in result:
            return result
        try:
            text = result['content'][0]['text']
            return json.loads(text)
        except Exception:
            return result

    async def emit_block(self, block_id: str, block_type: str, payload: dict,
                         ttl: int = None, force: bool = False, inbox: bool = False):
        import hashlib
        payload_hash = hashlib.sha256(
            json.dumps(payload, sort_keys=True).encode()
        ).hexdigest()
        if not force and self._last_payload_hash.get(block_id) == payload_hash:
            return  # content unchanged — skip CloudKit write
        self._last_payload_hash[block_id] = payload_hash
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._call_tool('emit_block', args)

    async def clear_block(self, block_id: str):
        self._last_payload_hash.pop(block_id, None)
        await self._call_tool('clear_block', {'blockId': block_id})

    # ── Terminal-manager calls ────────────────────────────────────────────────

    async def _tm_register(self, session_id: str, tmux_target: str, tty: str):
        tm_sid = f'codex2-{session_id[:16]}'
        read_mode = 'tmux' if tmux_target else 'history'
        try:
            await self._call_tool('register_session', {
                'session_id': tm_sid,
                'app_id': 'codex-2',
                'tty': tty or '',
                'tmux_target': tmux_target or '',
                'hook': CODEX_HOOK,
                'read_mode': read_mode,
            })
            self._tm_sessions[session_id] = tm_sid
            _log(f'Registered with terminal-manager: {tm_sid} (tmux={tmux_target!r} tty={tty!r})')
        except Exception as e:
            _log(f'terminal-manager register_session failed: {e}', 'WARN')

    async def _tm_unregister(self, session_id: str):
        tm_sid = self._tm_sessions.pop(session_id, None)
        if tm_sid:
            try:
                await self._call_tool('unregister_session', {'session_id': tm_sid})
            except Exception:
                pass

    async def _tm_detect(self, session_id: str) -> dict:
        tm_sid = self._tm_sessions.get(session_id)
        if not tm_sid:
            return {}
        try:
            return await self._call_tool('detect_tui', {'session_id': tm_sid})
        except Exception as e:
            _log(f'detect_tui error for {session_id}: {e}', 'WARN')
            return {}

    async def _tm_send_key(self, session_id: str, key: str):
        tm_sid = self._tm_sessions.get(session_id)
        if not tm_sid:
            return False
        try:
            await self._call_tool('send_key', {'session_id': tm_sid, 'key': key})
            return True
        except Exception as e:
            _log(f'send_key error: {e}', 'WARN')
            return False

    async def _tm_send_text(self, session_id: str, text: str):
        tm_sid = self._tm_sessions.get(session_id)
        if not tm_sid:
            return False
        try:
            await self._call_tool('send_text', {'session_id': tm_sid, 'text': text})
            return True
        except Exception as e:
            _log(f'send_text error: {e}', 'WARN')
            return False

    # ── Session ID resolution ─────────────────────────────────────────────────

    @staticmethod
    def _sanitize_id(s: str) -> str:
        """Replace characters that are invalid in CloudKit record names."""
        import re
        return re.sub(r'[^a-zA-Z0-9_\-]', '-', s)

    def _stable_id(self, raw_id: str, tmux_target: str = '') -> str:
        """Map any session identifier to its stable tmux-target-based ID.

        Session IDs are always 'tmux-{target}' internally so that block IDs
        stay constant across codex-2 restarts.  Hook UUIDs are looked up via
        the _real_to_stable mapping or resolved fresh from tmux.
        """
        if raw_id.startswith('tmux-'):
            return raw_id
        # Already have a mapping for this UUID
        if raw_id in self._real_to_stable:
            return self._real_to_stable[raw_id]
        # Derive from provided or freshly-looked-up tmux target
        target = tmux_target or _find_tmux_target()
        if target:
            stable = f'tmux-{target}'
            if raw_id:
                self._real_to_stable[raw_id] = stable
            return stable
        # No tmux session found — fall back to raw id
        return raw_id

    def _session_block_id(self, session_id: str) -> str:
        # session_id is always stable ('tmux-codex:0.0') so block ID is constant
        return f'codex2-session-{self._sanitize_id(session_id)}'

    def _permission_block_id(self, session_id: str, tool: str) -> str:
        return f'codex2-perm-{self._sanitize_id(session_id[:16])}-{tool}'

    def _lookup_session_id(self, raw_id: str = '', cwd: str = '', tmux_target: str = '') -> str:
        """Resolve a session without guessing across unrelated panes.

        Resolution order:
          1. Exact stable/raw session ID match
          2. Existing raw→stable mapping
          3. Exact tmux target match
          4. Stable ID derived from an explicit/discoverable tmux target
          5. Single CWD match when unambiguous

        Returns an empty string when no exact match exists.
        """
        if raw_id:
            if raw_id in self._sessions:
                return raw_id
            if raw_id in self._real_to_stable:
                stable = self._real_to_stable[raw_id]
                if stable in self._sessions:
                    return stable

        if tmux_target:
            stable = f'tmux-{tmux_target}'
            if stable in self._sessions:
                if raw_id:
                    self._real_to_stable[raw_id] = stable
                return stable
            for sid, info in self._sessions.items():
                if info.get('tmux_target') == tmux_target:
                    if raw_id:
                        self._real_to_stable[raw_id] = sid
                    return sid

        discovered_target = ''
        if not tmux_target and cwd:
            discovered_target = _find_tmux_target(cwd)
            if discovered_target:
                stable = f'tmux-{discovered_target}'
                if stable in self._sessions:
                    if raw_id:
                        self._real_to_stable[raw_id] = stable
                    return stable

        if raw_id:
            stable = self._stable_id(raw_id, tmux_target or discovered_target)
            if stable in self._sessions:
                return stable

        if cwd:
            matches = [sid for sid, info in self._sessions.items() if info.get('cwd') == cwd]
            if len(matches) == 1:
                if raw_id:
                    self._real_to_stable[raw_id] = matches[0]
                return matches[0]

        return ''

    async def _ensure_tm_session(self, session_id: str) -> bool:
        """Ensure terminal-manager knows about this session."""
        info = self._sessions.get(session_id, {})
        if not info:
            return False
        if session_id in self._tm_sessions:
            return True
        await self._tm_register(
            session_id,
            info.get('tmux_target', ''),
            info.get('tty', ''),
        )
        return session_id in self._tm_sessions

    async def _send_session_text(self, session_id: str, text: str) -> bool:
        """Route text to a session, re-registering or falling back when needed."""
        if session_id not in self._sessions:
            return False
        if await self._ensure_tm_session(session_id):
            if await self._tm_send_text(session_id, text):
                return True
            info = self._sessions.get(session_id, {})
            await self._tm_register(
                session_id,
                info.get('tmux_target', ''),
                info.get('tty', ''),
            )
            if await self._tm_send_text(session_id, text):
                return True

        tmux_target = self._sessions.get(session_id, {}).get('tmux_target', '')
        if tmux_target:
            try:
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, '-l', text],
                               capture_output=True, timeout=3, check=False)
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, 'Enter'],
                               capture_output=True, timeout=3, check=False)
                return True
            except Exception as e:
                _log(f'send_text tmux fallback error: {e}', 'WARN')
        return False

    async def _send_session_key(self, session_id: str, key: str) -> bool:
        """Route a keypress to a session, re-registering or falling back when needed."""
        if session_id not in self._sessions:
            return False
        if await self._ensure_tm_session(session_id):
            if await self._tm_send_key(session_id, key):
                return True
            info = self._sessions.get(session_id, {})
            await self._tm_register(
                session_id,
                info.get('tmux_target', ''),
                info.get('tty', ''),
            )
            if await self._tm_send_key(session_id, key):
                return True

        tmux_target = self._sessions.get(session_id, {}).get('tmux_target', '')
        if tmux_target:
            tmux_key = 'C-c' if key in ('C-c', 'ctrl_c') else key
            try:
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, tmux_key],
                               capture_output=True, timeout=3, check=False)
                return True
            except Exception as e:
                _log(f'send_key tmux fallback error: {e}', 'WARN')
        return False

    # ── Session tile emission ──────────────────────────────────────────────────

    def _schedule_session_tile(self, session_id: str, metadata: dict = None, delay: float = 0.5):
        """Debounced tile emit — cancels any pending emit for this session and reschedules.
        Rapid-fire events (pre_tool_use, post_tool_use) collapse into a single CloudKit write."""
        existing = self._tile_debounce_tasks.pop(session_id, None)
        if existing and not existing.done():
            existing.cancel()

        async def _delayed():
            await asyncio.sleep(delay)
            await self._emit_session_tile(session_id, metadata)

        self._tile_debounce_tasks[session_id] = asyncio.create_task(_delayed())

    async def _emit_session_tile(self, session_id: str, metadata: dict = None, force: bool = False):
        info = self._sessions.get(session_id, {})
        cwd = info.get('cwd', '')
        project = os.path.basename(cwd) if cwd else session_id[:8]

        # Build status summary from metadata
        status_parts = []
        if metadata:
            # Toggle indicators (e.g. accept edits on/off)
            for t in metadata.get('toggle_indicators', []):
                status_parts.append(f"{t['label']}: {t['state']}")
            # Key-value pairs (model, context, etc.)
            for k, v in list(metadata.get('key_value_pairs', {}).items())[:3]:
                status_parts.append(f'{k}: {v}')
            # Version
            versions = metadata.get('versions', [])
            if versions:
                status_parts.append(f'v{versions[0]}')

        status = '  ·  '.join(status_parts) if status_parts else 'Running'

        info = self._sessions.get(session_id, {})
        payload = {
            'session_id': session_id,
            'project': project,
            'cwd': cwd,
            'is_working': info.get('is_working', False),
            'is_headless': info.get('is_headless', False),
            'permission_mode': _load_permission_mode(),
        }
        # Include last agent message if available (captured from PostToolUse hook)
        if last_msg := info.get('last_message'):
            payload['last_message'] = last_msg
        # Include current tool activity when working
        if info.get('is_working'):
            if ct := info.get('current_tool'):
                payload['current_tool'] = ct
            if cp := info.get('current_preview'):
                payload['current_preview'] = cp
            if info.get('current_prompt') and info.get('is_working'):
                payload['current_prompt'] = info['current_prompt']
        await self.emit_block(
            self._session_block_id(session_id),
            'agent_session',
            payload,
            ttl=SESSION_TTL,
            force=force,
        )

    # ── TUI block emission ────────────────────────────────────────────────────

    async def _emit_numbered_menu(self, session_id: str, result: dict):
        # terminal-manager detect_numbered_menu returns:
        # {'title': str (proposed command), 'options': [str], 'current_index': int}
        options = result.get('options', [])
        if not options:
            return None
        cmd_title = result.get('title', '')
        # Values are "N  <option text>" — the leading number is extracted on response
        # and sent to tmux. style=list forces a vertical radio-button list in the app.
        option_values = [f'{i+1}  {opt}' for i, opt in enumerate(options)]
        block_id = f'codex2-menu-{self._sanitize_id(session_id[:8])}'
        payload = {
            'title': cmd_title or 'Choose an option',
            'body': '',
            'options': option_values,
            'session_id': session_id,
            'style': 'list',
        }
        await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        return block_id

    async def _emit_slash_menu(self, session_id: str, result: dict):
        commands = result.get('commands', [])
        if not commands:
            return None
        options = [c['cmd'] for c in commands]
        descs = {c['cmd']: c.get('desc', '') for c in commands}
        body = '\n'.join(f"{cmd}  {descs[cmd]}" for cmd in options if descs.get(cmd))
        block_id = f'codex2-slash-{self._sanitize_id(session_id[:8])}'
        payload = {
            'title': 'Slash commands',
            'body': body,
            'options': options,
            'session_id': session_id,
            'style': 'list',
        }
        await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        return block_id

    async def _emit_toggle_menu(self, session_id: str, result: dict):
        # terminal-manager detect_checkbox_menu returns:
        # {'title': str, 'options': [str], 'current_index': int}
        options = result.get('options', [])
        if not options:
            return None
        title = result.get('title') or 'Settings'
        body = '\n'.join(options)
        block_id = f'codex2-toggle-{self._sanitize_id(session_id[:8])}'
        payload = {
            'title': title,
            'body': body,
            'options': options,
            'session_id': session_id,
        }
        await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        return block_id

    # ── Polling ───────────────────────────────────────────────────────────────

    async def _poll_session(self, session_id: str):
        _log(f'Starting TUI poll for session {session_id[:12]}')
        last_pattern_id = None
        active_tui_block = None

        while session_id in self._sessions:
            try:
                info = self._sessions.get(session_id, {})

                # Skip TUI detection while Codex is actively working — streaming
                # output can false-positive against numbered/arrow menu patterns.
                # Clear any stale TUI block so it doesn't linger during work.
                if info.get('is_working'):
                    if active_tui_block:
                        try:
                            await self.clear_block(active_tui_block)
                        except Exception:
                            pass
                        active_tui_block = None
                        last_pattern_id = None
                    await asyncio.sleep(0.5)
                    continue

                result = await self._tm_detect(session_id)
                pattern_id = result.get('pattern_id')
                tui_result = result.get('result') or {}
                metadata = result.get('metadata') or {}

                if result:
                    _log(f'detect_tui [{session_id[:8]}]: pattern={pattern_id!r} '
                         f'keys={list(result.keys())}')

                # Update session tile with latest metadata
                if metadata:
                    await self._emit_session_tile(session_id, metadata)

                # Handle interactive TUI patterns
                if pattern_id != last_pattern_id:
                    # Clear old TUI block if pattern changed
                    if active_tui_block:
                        try:
                            await self.clear_block(active_tui_block)
                        except Exception:
                            pass
                        active_tui_block = None

                    if pattern_id == 'numbered_menu':
                        active_tui_block = await self._emit_numbered_menu(
                            session_id, tui_result)
                    elif pattern_id == 'slash_commands':
                        active_tui_block = await self._emit_slash_menu(
                            session_id, tui_result)
                    elif pattern_id == 'toggle_menu':
                        active_tui_block = await self._emit_toggle_menu(
                            session_id, tui_result)

                    # Only advance last_pattern_id when block was actually emitted;
                    # if emit returned None (e.g. empty options), retry next poll.
                    if pattern_id is None or active_tui_block is not None:
                        last_pattern_id = pattern_id

            except asyncio.CancelledError:
                break
            except Exception as e:
                _log(f'Poll error for {session_id[:12]}: {e}', 'WARN')

            await asyncio.sleep(0.5)

        # Clean up TUI block when session ends
        if active_tui_block:
            try:
                await self.clear_block(active_tui_block)
            except Exception:
                pass
        _log(f'Stopped TUI poll for session {session_id[:12]}')

    # ── Hook event handlers ───────────────────────────────────────────────────

    async def _discover_active_sessions(self):
        """Scan tmux for running Codex sessions and register any not yet known."""
        if _SKIP_DISCOVERY:
            return
        try:
            r = subprocess.run(
                [TMUX, 'list-panes', '-a', '-F',
                 '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'],
                capture_output=True, text=True, timeout=3,
            )
            for line in r.stdout.strip().splitlines():
                parts = line.split(' ', 1)
                if len(parts) != 2:
                    continue
                target, cmd = parts
                session_name = target.split(':')[0]
                # Look for panes running node (Codex) in the shared 'codex' session
                if session_name.lower() != 'codex' or cmd.lower() not in ('node', 'codex'):
                    continue
                # Generate a stable synthetic session_id from the tmux target
                synth_id = f'tmux-{target}'
                if synth_id in self._sessions:
                    continue
                # Skip if any known session already maps to this tmux target.
                # Prevents duplicate sessions after codex-2 reloads while Codex is running.
                target_prefix = target.split('.')[0]  # e.g. "codex:ask"
                already_tracked = any(
                    info.get('tmux_target', '').split('.')[0] == target_prefix
                    for info in self._sessions.values()
                )
                if already_tracked:
                    _log(f'Skipping discovery for {target} — session already tracked')
                    continue
                _log(f'Discovered idle Codex session at {target}')
                pid = _get_pane_pid(target)
                cwd = _get_pane_cwd(target) or os.path.expanduser('~')
                await self._handle_session_active({
                    'session_id': synth_id,
                    'cwd': cwd,
                    'tty': '',
                    'tmux_target': target,
                    'pid': pid,
                })
                # Detect whether the tmux session has an attached terminal client
                if synth_id in self._sessions and 'is_headless' not in self._sessions[synth_id]:
                    tmux_session = session_name
                    try:
                        lc = subprocess.run(
                            [TMUX, 'list-clients', '-t', tmux_session, '-F', '#{client_tty}'],
                            capture_output=True, text=True, timeout=2,
                        )
                        self._sessions[synth_id]['is_headless'] = not bool(lc.stdout.strip())
                    except Exception:
                        self._sessions[synth_id]['is_headless'] = False
        except Exception as e:
            _log(f'Session discovery error: {e}', 'WARN')

    async def _session_heartbeat(self):
        """Periodically rediscover sessions, validate PIDs, and refresh TTLs."""
        if _SKIP_DISCOVERY:
            return
        while True:
            await asyncio.sleep(30)
            try:
                _log(f'Heartbeat: {len(self._sessions)} session(s)')
                # Validate existing sessions — clean up any whose process died
                for session_id in list(self._sessions.keys()):
                    info = self._sessions.get(session_id, {})
                    # Check if the tmux pane is still running Codex.
                    # #{pane_pid} is the shell PID (always alive), so instead we
                    # check the foreground command. If it's no longer node/codex,
                    # Codex has exited and the session should be cleaned up.
                    tmux_target = info.get('tmux_target', '')
                    if tmux_target:
                        pane_cmd = _get_pane_command(tmux_target)
                        # Empty pane_cmd means tmux is gone or the pane no longer exists.
                        # Either way, Codex is dead — clean up so iOS doesn't keep showing it.
                        if not pane_cmd or pane_cmd.lower() not in ('node', 'codex'):
                            reason = 'tmux gone' if not pane_cmd else pane_cmd
                            _log(f'Pane {tmux_target} ({reason!r}) — Codex exited, cleaning up')
                            asyncio.create_task(self._handle_session_stop(
                                {'session_id': session_id, 'last_message': 'Session ended'}))
                            continue
                    # Sessions that predate is_headless tracking: detect via tmux clients.
                    if 'is_headless' not in info:
                        tmux_target = info.get('tmux_target', '')
                        tmux_session = tmux_target.split(':')[0] if tmux_target else ''
                        if tmux_session:
                            try:
                                lc = subprocess.run(
                                    [TMUX, 'list-clients', '-t', tmux_session, '-F', '#{client_tty}'],
                                    capture_output=True, text=True, timeout=2,
                                )
                                info['is_headless'] = not bool(lc.stdout.strip())
                            except Exception:
                                info['is_headless'] = False
                        else:
                            info['is_headless'] = False
                    # Refresh session block TTL so it doesn't expire while we're running.
                    # Use force=True to bypass dedup — content may be unchanged but
                    # CloudKit needs the TTL refreshed or the record disappears.
                    if session_id in self._sessions:
                        self._sessions[session_id]['last_seen'] = datetime.datetime.now().timestamp()
                        await self._emit_session_tile(session_id, force=True)

                await self._discover_active_sessions()
                _save_sessions(self._sessions)

                if not self._sessions:
                    await self.emit_block(TILE_ID, 'tile', {
                        'label': 'No sessions',
                        'status_color': 'blue',
                        'action_required': False,
                    }, ttl=600)
                # Refresh start-session block to prevent TTL expiry
                await self._emit_start_session_block(force=True)
            except Exception:
                pass

    async def _handle_session_active(self, msg: dict):
        raw_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        raw_tty = msg.get('tty', '')
        if not raw_id:
            return

        tty = _tty_to_dev(raw_tty)
        tmux_target = msg.get('tmux_target') or _find_tmux_target(cwd)

        # Always resolve to stable tmux-based ID — block IDs are constant across restarts
        session_id = self._stable_id(raw_id, tmux_target)

        # If cwd is absent (e.g. PostToolUse hook doesn't send it), read from tmux
        if not cwd and tmux_target:
            cwd = _get_pane_cwd(tmux_target)

        info = self._sessions.setdefault(session_id, {})
        if cwd:
            info['cwd'] = cwd
        info.update({'tty': tty, 'tmux_target': tmux_target})
        if pid := msg.get('pid'):
            info['pid'] = pid
        if last_msg := msg.get('last_message'):
            info['last_message'] = last_msg
        if msg.get('tool_name') or msg.get('tool'):
            info['is_working'] = True
        elif 'is_working' in msg:
            info['is_working'] = bool(msg['is_working'])
            if not info['is_working']:
                # Clear in-progress tool indicators when going idle
                info.pop('current_tool', None)
                info.pop('current_preview', None)

        info['last_seen'] = datetime.datetime.now().timestamp()
        _save_sessions(self._sessions)
        _log(f'Session active: {session_id} (raw={raw_id[:12]}) cwd={cwd} tmux={tmux_target!r}')

        # Register with terminal-manager if not already done
        if session_id not in self._tm_sessions:
            await self._tm_register(session_id, tmux_target, tty)

        # Emit session tile immediately
        await self._emit_session_tile(session_id)

        # Clear the "No sessions" tile so the iOS app derives the label
        # from agent_session block count automatically.
        try:
            await self.clear_block(TILE_ID)
        except Exception:
            pass

        # Start polling task
        if session_id not in self._poll_tasks or self._poll_tasks[session_id].done():
            self._poll_tasks[session_id] = asyncio.create_task(
                self._poll_session(session_id))

    async def _handle_session_stop(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        cwd = msg.get('cwd', '')
        session_id = self._lookup_session_id(raw_id=raw_id, cwd=cwd)
        if not session_id and raw_id.startswith('tmux-'):
            session_id = raw_id
        if not session_id:
            session_id = self._real_to_stable.get(raw_id, raw_id)
        last_message = msg.get('last_message', '')
        _log(f'Session stop: {session_id} (raw={raw_id[:12]})')

        # Cancel poll task
        task = self._poll_tasks.pop(session_id, None)
        if task:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        # Unregister from terminal-manager
        await self._tm_unregister(session_id)

        # Clear the session block — iOS auto-dismisses when blocks are gone.
        # Lingering "Session ended" blocks were causing stale state after restarts.
        info = self._sessions.pop(session_id, {})
        _save_sessions(self._sessions)
        try:
            await self.clear_block(self._session_block_id(session_id))
        except Exception:
            pass

        # Re-emit tile if no active sessions remain
        if not self._sessions:
            await self.emit_block(TILE_ID, 'tile', {
                'label': 'No sessions',
                'status_color': 'blue',
                'action_required': False,
            }, ttl=600)

    async def _capture_tui_result(self, session_id: str):
        """Capture terminal output after a TUI menu response and surface it as last_message.

        Waits for Codex to finish processing (prompt returns), then grabs the
        pane text between the last command and the new prompt. Surfaces it in the
        session tile so it flows into the conversation as an assistant message.
        """
        await asyncio.sleep(1.5)  # give Codex time to process and print output
        info = self._sessions.get(session_id, {})
        tmux_target = info.get('tmux_target', '')
        if not tmux_target:
            return
        try:
            r = subprocess.run(
                [TMUX, 'capture-pane', '-t', tmux_target, '-p', '-S', '-60'],
                capture_output=True, text=True, timeout=5,
            )
        except Exception as e:
            _log(f'_capture_tui_result: {e}', 'WARN')
            return
        if r.returncode != 0:
            return
        raw = r.stdout
        # Strip ANSI escape sequences
        import re as _re
        clean = _re.sub(r'\x1b\[[0-9;]*[mGKHF]', '', raw)
        lines = clean.splitlines()
        # Walk backwards to find the output between the last two shell prompts
        # (prompts tend to end with '$', '❯', '▶', '%', or '#')
        prompt_re = _re.compile(r'[\$❯▶%#]\s*$')
        # Find the second-to-last prompt (start of the output we want)
        prompt_indices = [i for i, l in enumerate(lines) if prompt_re.search(l.rstrip())]
        if len(prompt_indices) >= 2:
            start = prompt_indices[-2] + 1
            end = prompt_indices[-1]
            output_lines = [l for l in lines[start:end] if l.strip()]
        elif prompt_indices:
            # Only one prompt found — take everything before it
            output_lines = [l for l in lines[:prompt_indices[-1]] if l.strip()]
        else:
            output_lines = [l for l in lines if l.strip()]

        output = '\n'.join(output_lines).strip()
        if not output or len(output) < 5:
            return  # nothing useful

        _log(f'TUI result for {session_id[:12]}: {len(output)} chars')
        info['last_message'] = output
        await self._emit_session_tile(session_id)

    async def _handle_notification(self, msg: dict):
        title = msg.get('title', 'Codex')
        body = msg.get('body', '')
        payload = {'title': title, 'body': body}
        block_id = f'codex2-notif-{uuid.uuid4().hex[:8]}'
        await self.emit_block(block_id, 'alert', payload, ttl=300)

    # ── MCP tool handlers (called by daemon) ──────────────────────────────────

    async def _tool_permission_request(self, args: dict) -> dict:
        tool = args.get('tool', '')
        input_data = args.get('input', {})
        session_id = args.get('session_id', list(self._sessions.keys())[0]
                               if self._sessions else 'unknown')

        block_id = self._permission_block_id(session_id, tool)
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pending_permissions[block_id] = fut

        # Build a readable preview of what Codex wants to run
        preview_parts = []
        if input_data.get('command'):
            preview_parts.append(f"`{input_data['command']}`")
        elif input_data.get('path'):
            preview_parts.append(input_data['path'])
        body = ', '.join(preview_parts) if preview_parts else json.dumps(input_data)[:120]

        payload = {
            'title': f'Allow {tool}?',
            'body': body,
            'confirm_label': 'Allow',
            'deny_label': 'Deny',
        }
        await self.emit_block(block_id, 'confirmation', payload, inbox=True)

        try:
            value = await asyncio.wait_for(fut, timeout=120.0)
            return {'approved': value == 'confirm', 'value': value}
        except asyncio.TimeoutError:
            return {'approved': False, 'value': 'timeout'}
        finally:
            self._pending_permissions.pop(block_id, None)

    async def _tool_session_active(self, args: dict) -> dict:
        asyncio.create_task(self._handle_session_active(args))
        return {'ok': True}

    async def _tool_session_stop(self, args: dict) -> dict:
        asyncio.create_task(self._handle_session_stop(args))
        return {'ok': True}

    async def _tool_reply(self, args: dict) -> dict:
        message = args.get('message', '').strip()
        requested_session_id = args.get('session_id', '')
        if not message:
            return {'error': 'message is required'}
        session_id = self._lookup_session_id(raw_id=requested_session_id)
        if not session_id:
            if not requested_session_id and len(self._sessions) == 1:
                session_id = next(iter(self._sessions))
            else:
                return {'error': 'unknown session'}
        ok = await self._send_session_text(session_id, message)
        if not ok:
            return {'error': 'session is not routable'}
        info = self._sessions.get(session_id)
        if info is not None:
            info['is_working'] = True
            info['current_prompt'] = message[:200]
            info['last_seen'] = datetime.datetime.now().timestamp()
            _save_sessions(self._sessions)
            self._schedule_session_tile(session_id)
        return {'ok': True}

    async def _tool_stop_session(self, args: dict) -> dict:
        requested_session_id = args.get('session_id', '')
        session_id = self._lookup_session_id(raw_id=requested_session_id)
        if not session_id:
            if not requested_session_id and len(self._sessions) == 1:
                session_id = next(iter(self._sessions))
            else:
                return {'error': 'unknown session'}
        ok = await self._send_session_key(session_id, 'ctrl_c')
        if not ok:
            return {'error': 'session is not routable'}
        _log(f'stop_session: sent C-c to {session_id}')
        if session_id in self._sessions:
            self._sessions[session_id]['is_working'] = False
            self._sessions[session_id]['last_seen'] = datetime.datetime.now().timestamp()
            _save_sessions(self._sessions)
            self._schedule_session_tile(session_id)
        return {'ok': True}

    async def _tool_notification(self, args: dict) -> dict:
        asyncio.create_task(self._handle_notification(args))
        return {'ok': True}

    async def _tool_tool_executed(self, args: dict) -> dict:
        tool = args.get('tool', '')
        # Resolve any permission blocks for this tool
        for block_id, fut in list(self._pending_permissions.items()):
            if f'-{tool}' in block_id and not fut.done():
                fut.set_result('executed')
                await self.clear_block(block_id)
        return {'ok': True}

    # ── Start session ─────────────────────────────────────────────────────────

    async def _emit_start_session_block(self, force: bool = False):
        """Emit the start-session block so the iPhone shows a + button."""
        repos = _find_repos()
        # Put recently used repos at the top
        recent = self._settings.get('recent_repos', [])
        def repo_sort_key(r):
            try:
                return recent.index(r[1])
            except ValueError:
                return len(recent)
        repos.sort(key=repo_sort_key)
        self._start_repos = {name: path for name, path in repos}
        repo_list = [{'name': name, 'path': path} for name, path in repos]
        if not repo_list:
            repo_list = [{'name': '(no repos found)', 'path': ''}]
        payload = {'repos': repo_list}
        await self.emit_block(START_SESSION_BLOCK_ID, 'start_session', payload,
                              ttl=600, force=force)

    async def _launch_codex(self, repo_path: str):
        """Launch Codex in a tmux session at repo_path."""
        project = os.path.basename(repo_path.rstrip('/'))
        # Expand ~ just in case
        repo_path = os.path.expanduser(repo_path)

        # Resolve codex binary — may not be on AskMac's restricted PATH
        codex_candidates = [
            os.path.expanduser('~/.local/bin/codex'),
            os.path.expanduser('~/.npm-global/bin/codex'),
        ]
        try:
            nvm_base = os.path.expanduser('~/.nvm/versions/node')
            if os.path.isdir(nvm_base):
                latest = sorted(os.listdir(nvm_base))[-1]
                codex_candidates.insert(0, os.path.join(nvm_base, latest, 'bin', 'codex'))
        except Exception:
            pass
        codex_bin = 'codex'
        for c in codex_candidates:
            if os.path.isfile(c):
                codex_bin = c
                break

        # Auto-trust the repo so Codex skips the interactive trust prompt.
        _ensure_repo_trusted(repo_path)

        # Re-install hooks immediately before launch so codex-2's hooks take
        # precedence over any other script (e.g. codex-controller) that may
        # have overwritten ~/.codex/hooks.json since startup.
        _install_hooks()

        _log(f'Launching Codex: project={project!r} cwd={repo_path!r} bin={codex_bin!r}')

        # Emit a provisional "Starting…" tile immediately so iPhone shows feedback.
        provisional_id = f'tmux-codex:{project}.0'
        if provisional_id not in self._sessions:
            self._sessions[provisional_id] = {
                'cwd': repo_path,
                'project': project,
                'tmux_target': f'codex:{project}.0',
                'pid': 0,
                'is_working': False,
                'is_headless': not self._settings.get('interactive', True),
                'last_message': 'Starting…',
            }
            await self._emit_session_tile(provisional_id, force=True)

        # Wrap in a login shell so ~/.zshrc / ~/.zprofile is sourced and
        # OPENAI_API_KEY and PATH are available (AskMac doesn't source shell profiles).
        # AskMac runs with a restricted PATH (/usr/bin:/bin:/usr/sbin:/sbin). Codex's
        # Node runtime needs 'node' in PATH for subprocess spawning, so prepend the
        # nvm bin dir and Homebrew explicitly before exec-ing codex.
        # Also force ASK_SOCKET_PATH so that hook scripts connect to codex-2's socket
        # regardless of which hook files are registered in hooks.json.
        shell = os.environ.get('SHELL', '/bin/zsh')
        node_bin_dir = shlex.quote(os.path.dirname(codex_bin))
        path_prefix = f'{node_bin_dir}:/opt/homebrew/bin:/usr/local/bin'
        shell_cmd = (
            f'export PATH={path_prefix}:$PATH; '
            f'export ASK_SOCKET_PATH={shlex.quote(SOCKET_PATH)}; '
            f'cd {shlex.quote(repo_path)} && exec {shlex.quote(codex_bin)}'
        )

        # All Codex projects share one 'codex' tmux session; each project gets its
        # own window named after the repo (e.g. codex:ask, codex:life).
        r = subprocess.run([TMUX, 'has-session', '-t', 'codex'],
                           capture_output=True, timeout=3)
        if r.returncode == 0:
            # Session exists — check if a window for this project already exists.
            lw = subprocess.run(
                [TMUX, 'list-windows', '-t', 'codex', '-F', '#{window_name}'],
                capture_output=True, text=True, timeout=3,
            )
            existing = lw.stdout.strip().splitlines() if lw.returncode == 0 else []
            if project not in existing:
                r2 = subprocess.run([
                    TMUX, 'new-window', '-t', 'codex', '-c', repo_path, '-n', project,
                    shell, '-l', '-c', shell_cmd,
                ], capture_output=True, text=True, timeout=5)
                _log(f'new-window rc={r2.returncode} stderr={r2.stderr.strip()!r}')
            else:
                _log(f'Window codex:{project} already exists — reusing')
            pane_target = f'codex:{project}.0'
        else:
            # Create the shared 'codex' session with this project as the first window.
            r2 = subprocess.run([
                TMUX, 'new-session', '-d', '-s', 'codex',
                '-c', repo_path, '-n', project,
                shell, '-l', '-c', shell_cmd,
            ], capture_output=True, text=True, timeout=5)
            pane_target = f'codex:{project}.0'
            _log(f'new-session rc={r2.returncode} stderr={r2.stderr.strip()!r}')

        _log(f'New window pane target: {pane_target!r}')

        # Clear the picker now that launch is underway
        try:
            await self.clear_block(START_SESSION_BLOCK_ID)
        except Exception:
            pass

        # Register the session immediately — don't wait for zsh login startup
        if pane_target:
            synth_id = f'tmux-{pane_target}'
            is_headless = not self._settings.get('interactive', True)
            if synth_id not in self._sessions:
                pid = _get_pane_pid(pane_target)
                await self._handle_session_active({
                    'session_id': synth_id,
                    'cwd': repo_path,
                    'tty': '',
                    'tmux_target': pane_target,
                    'pid': pid,
                })
            # Tag with the mode it was launched in (after _handle_session_active creates the entry)
            if synth_id in self._sessions:
                self._sessions[synth_id]['is_headless'] = is_headless
                await self._emit_session_tile(synth_id, force=True)

        # Open a Terminal.app window attached to the new pane if interactive mode is on
        if self._settings.get('interactive', True) and pane_target:
            try:
                win_target = pane_target.rsplit('.', 1)[0]
                # Select the window now (by name, before auto-rename kicks in),
                # then attach to the session — avoids "can't find window" errors.
                subprocess.run([TMUX, 'select-window', '-t', win_target],
                               capture_output=True, timeout=3)
                # Retry loop handles the race between tmux session creation and
                # Terminal.app launching. 'exit' closes the Terminal window when
                # the tmux session ends so windows don't accumulate.
                attach_cmd = (
                    'for i in 1 2 3 4 5; do '
                    'tmux attach-session -t codex && break; '
                    'sleep 1; done; exit'
                )
                osascript_script = f'tell application "Terminal" to do script "{attach_cmd}"'
                subprocess.Popen(['osascript', '-e', osascript_script],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                _log(f'Opened Terminal.app for {win_target}')
            except Exception as e:
                _log(f'Could not open Terminal.app: {e}', 'WARN')

        # Schedule a delayed pane snapshot to log what Codex shows on startup
        if pane_target:
            asyncio.create_task(self._log_pane_snapshot(pane_target, delay=8))

        # Update recent repos list and re-emit start-session block
        self._settings = _update_recent_repos(self._settings, repo_path)
        _save_settings_file(self._settings)

        # Re-emit the start-session block so the + button comes back immediately
        await self._emit_start_session_block(force=True)

    async def _log_pane_snapshot(self, pane_target: str, delay: float = 8):
        """After `delay` seconds, capture and log the pane content for diagnostics."""
        await asyncio.sleep(delay)
        try:
            r = subprocess.run(
                [TMUX, 'capture-pane', '-t', pane_target, '-p'],
                capture_output=True, text=True, timeout=3,
            )
            if r.returncode == 0:
                content = r.stdout.strip()[-500:]  # last 500 chars
                _log(f'Pane snapshot [{pane_target}]: {content!r}')
            else:
                _log(f'Pane snapshot [{pane_target}]: capture failed rc={r.returncode} (pane gone?)')
        except Exception as e:
            _log(f'Pane snapshot [{pane_target}]: error {e}', 'WARN')

    async def _tool_start_session(self, args: dict) -> dict:
        """MCP tool: iOS calls this to launch a Codex session.

        If repo_path is given, launch immediately; otherwise emit a repo picker.
        """
        repo_path = args.get('repo_path', '')
        if repo_path:
            asyncio.create_task(self._launch_codex(repo_path))
        else:
            await self._emit_start_session_block()
        return {'ok': True}

    # ── Unix socket server (receives hook events) ─────────────────────────────

    async def _handle_socket_client(self, reader, writer):
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=5.0)
            msg = json.loads(data.decode())
            t = msg.get('type', '')
            _log(f'Socket msg: type={t!r} session={msg.get("session_id","")[:12]!r}')
            if t == 'session_active':
                await self._handle_session_active(msg)
            elif t == 'session_stop':
                await self._handle_session_stop(msg)
            elif t == 'notification':
                await self._handle_notification(msg)
            elif t == 'tool_executed':
                tool = msg.get('tool_name', msg.get('tool', ''))
                raw_id = msg.get('session_id', '')
                session_id = self._lookup_session_id(
                    raw_id=raw_id,
                    cwd=msg.get('cwd', ''),
                    tmux_target=msg.get('tmux_target', ''),
                ) if raw_id else ''
                display_tool = _map_tool_name(tool)
                # Resolve any pending permission block for this tool
                for block_id, fut in list(self._pending_permissions.items()):
                    if self._sanitize_id(session_id[:16]) in block_id and not fut.done():
                        fut.set_result('executed')
                        asyncio.create_task(self.clear_block(block_id))
                # Update or register the session
                if session_id and session_id in self._sessions:
                    info = self._sessions[session_id]
                    info['is_working'] = True
                    info['last_seen'] = datetime.datetime.now().timestamp()
                    info['current_tool'] = display_tool
                    last_msg = msg.get('last_message', '')
                    if last_msg:
                        info['last_message'] = last_msg
                        info.pop('current_preview', None)  # clear stale preview when message arrives
                    WRITE_TOOLS = {'write_file', 'str_replace_editor', 'apply_patch',
                                   'edit_file', 'create_file', 'overwrite_file'}
                    if tool.lower() in WRITE_TOOLS:
                        file_path = msg.get('last_message', '') or msg.get('cwd', '')
                        project = info.get('project', session_id[:12])
                        await self._handle_notification({
                            'title': f'{project}: file changed',
                            'body': f'{_map_tool_name(tool)} completed',
                        })
                    _save_sessions(self._sessions)
                    self._schedule_session_tile(session_id)
                elif session_id:
                    await self._handle_session_active(msg)
            elif t in ('pre_tool_use', 'user_prompt_submit'):
                raw_id = msg.get('session_id', '')
                session_id = self._lookup_session_id(
                    raw_id=raw_id,
                    cwd=msg.get('cwd', ''),
                    tmux_target=msg.get('tmux_target', ''),
                ) if raw_id else ''
                if not session_id and raw_id:
                    await self._handle_session_active(msg)
                    session_id = self._lookup_session_id(
                        raw_id=raw_id,
                        cwd=msg.get('cwd', ''),
                        tmux_target=msg.get('tmux_target', ''),
                    )
                if session_id and session_id in self._sessions:
                    info = self._sessions[session_id]
                    info['is_working'] = True
                    info['last_seen'] = datetime.datetime.now().timestamp()
                    if t == 'pre_tool_use':
                        tool = msg.get('tool_name', msg.get('tool', ''))
                        if tool:
                            info['current_tool'] = _map_tool_name(tool)
                    if t == 'user_prompt_submit':
                        prompt = msg.get('prompt', '').strip()
                        if prompt:
                            info['current_prompt'] = prompt[:200]
                            info.pop('last_message', None)  # clear stale message when new prompt arrives
                    _save_sessions(self._sessions)
                    self._schedule_session_tile(session_id)
            elif t == 'permission_request':
                # Hook is blocking on a response -- emit confirmation, wait, reply.
                value = await self._handle_permission_from_hook(msg)
                writer.write(json.dumps({'value': value}).encode())
                await writer.drain()
            elif t == 'ui_respond':
                # Response from MockAskMac web UI — treat like iPhone response
                sid = msg.get('session_id', '')
                value = msg.get('value', '')
                if sid in self._sessions:
                    block_id = self._session_block_id(sid)
                    await self._handle_block_response(block_id, value)
                writer.write(json.dumps({'ok': True}).encode())
                await writer.drain()
        except Exception as e:
            _log(f'Socket client error: {e}', 'WARN')
        finally:
            writer.close()

    async def _handle_permission_from_hook(self, msg: dict) -> str:
        tool = msg.get('tool', 'Bash')
        preview = msg.get('preview', '')
        options = msg.get('options', ['Allow', 'Deny'])
        raw_id = msg.get('session_id', '')
        session_id = self._lookup_session_id(
            raw_id=raw_id,
            cwd=msg.get('cwd', ''),
            tmux_target=msg.get('tmux_target', ''),
        ) if raw_id else ''

        # If MCP isn't ready, fall through to Codex's built-in prompt rather
        # than hard-blocking with a spurious "denied" message.
        if not self._initialized:
            _log(f'Skipping permission block (not yet initialized) — allowing {tool!r}', 'WARN')
            return ''

        block_id = self._permission_block_id(session_id or 'unknown', tool)
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pending_permissions[block_id] = fut
        self._active_perm_blocks.add(block_id)
        _save_active_blocks(self._active_perm_blocks)

        payload = {
            'title': f'Allow {tool}?',
            'body': preview,
            'options': options,
        }
        if session_id:
            payload['session_id'] = session_id
        try:
            await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        except Exception as e:
            _log(f'emit_block for permission failed: {e} — allowing {tool!r}', 'WARN')
            self._pending_permissions.pop(block_id, None)
            self._active_perm_blocks.discard(block_id)
            _save_active_blocks(self._active_perm_blocks)
            # Fall through to Codex's built-in prompt rather than blocking
            return ''

        # Mark session as working while waiting for permission
        if session_id in self._sessions:
            info = self._sessions[session_id]
            info['is_working'] = True
            info['current_tool'] = _map_tool_name(tool)
            info['current_preview'] = preview[:100] if preview else ''
            info['last_seen'] = datetime.datetime.now().timestamp()
            _save_sessions(self._sessions)
            self._schedule_session_tile(session_id)

        _log(f'Waiting for permission: {tool!r} session={session_id[:12]!r}')
        try:
            value = await asyncio.wait_for(fut, timeout=120.0)
        except asyncio.TimeoutError:
            _log(f'Permission timed out for {tool!r} — allowing', 'WARN')
            value = ''
        finally:
            self._pending_permissions.pop(block_id, None)
            self._active_perm_blocks.discard(block_id)
            _save_active_blocks(self._active_perm_blocks)
            try:
                await self.clear_block(block_id)
            except Exception:
                pass

        _log(f'Permission resolved: {tool!r} => {value!r}')
        if value == 'Always Allow' and preview:
            _append_allowlist(preview)
        return value

    async def _start_socket_server(self):
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
        server = await asyncio.start_unix_server(
            self._handle_socket_client, path=SOCKET_PATH)
        _log(f'Unix socket listening at {SOCKET_PATH}')
        return server

    # ── MCP stdin loop ────────────────────────────────────────────────────────

    async def _handle_rpc_line(self, line: str):
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return

        rpc_id = msg.get('id')
        method = msg.get('method', '')

        # Responses to our own outbound calls
        if rpc_id is not None and ('result' in msg or 'error' in msg):
            fut = self._pending_calls.pop(rpc_id, None)
            if fut and not fut.done():
                if 'result' in msg:
                    fut.set_result(msg['result'])
                else:
                    fut.set_exception(Exception(str(msg['error'])))
            return

        # User response to a block (permission approval, picker choice)
        # or free-form chat message from the iOS compose bar.
        if method == 'notifications/message':
            params = msg.get('params', {})
            data = params.get('data', {})
            msg_type = data.get('type', '')

            if msg_type == 'user_response':
                block_id = data.get('blockId', '')
                value = data.get('value', '')
                _log(f'user_response: block={block_id!r} value={value!r}')
                fut = self._pending_permissions.get(block_id)
                if fut and not fut.done():
                    fut.set_result(value)
                # Also handle TUI picker responses
                await self._handle_picker_response(block_id, value)

            elif msg_type == 'chat_message':
                # Route free-form text to the Codex terminal via send_text.
                text = data.get('text', '').strip()
                requested_session_id = data.get('sessionId', '')
                session_id = self._lookup_session_id(raw_id=requested_session_id)
                if text and session_id:
                    _log(f'chat_message → session={session_id[:12]!r} text={text[:60]!r}')
                    ok = await self._send_session_text(session_id, text)
                    if ok and session_id in self._sessions:
                        self._sessions[session_id]['is_working'] = True
                        self._sessions[session_id]['current_prompt'] = text[:200]
                        self._sessions[session_id]['last_seen'] = datetime.datetime.now().timestamp()
                        _save_sessions(self._sessions)
                        self._schedule_session_tile(session_id)
                    elif not ok:
                        _log(f'chat_message: routing failed for sessionId={requested_session_id!r}', 'WARN')
                elif text:
                    _log(f'chat_message: no matching session for sessionId={requested_session_id!r}, dropping', 'WARN')
            return

        # Inbound tool calls from daemon
        if method == 'tools/call':
            params = msg.get('params', {})
            name = params.get('name', '')
            args = params.get('arguments', {})
            handler = getattr(self, f'_tool_{name}', None)
            if handler is None:
                self._write({'jsonrpc': '2.0', 'id': rpc_id,
                             'error': {'code': -32601, 'message': f'Unknown tool: {name}'}})
                return
            try:
                result = await handler(args)
                content = [{'type': 'text', 'text': json.dumps(result)}]
                self._write({'jsonrpc': '2.0', 'id': rpc_id,
                             'result': {'content': content}})
            except Exception as e:
                self._write({'jsonrpc': '2.0', 'id': rpc_id,
                             'error': {'code': -32603, 'message': str(e)}})
            return

        # Unknown method — ignore
        pass

    async def _handle_picker_response(self, block_id: str, value: str):
        """Route a TUI menu response to the terminal."""
        # Handle global blocks first — they don't belong to a session.
        if block_id == START_SESSION_BLOCK_ID:
            # value is the repo name/path sent by the iPhone picker
            path = self._start_repos.get(value, value)
            if path and path != '(no repos found)':
                project = os.path.basename(path.rstrip('/'))
                await self.clear_block(START_SESSION_BLOCK_ID)
                # If a mode is already saved, launch directly — no need to ask again.
                if 'interactive' in self._settings:
                    mode = 'Interactive' if self._settings['interactive'] else 'Headless'
                    _log(f'Launching {project!r} in saved mode: {mode}')
                    asyncio.create_task(self._launch_codex(path))
                else:
                    launch_id = str(uuid.uuid4())[:8]
                    mode_block_id = f'codex2-mode-{launch_id}'
                    self._pending_launches[mode_block_id] = path
                    await self.emit_block(mode_block_id, 'confirmation', {
                        'title': f'Start "{project}" as…',
                        'body': 'Interactive opens a Terminal window on this Mac.\nHeadless runs silently in the background.',
                        'options': ['Interactive', 'Headless'],
                    }, ttl=120)
            return

        if block_id in self._pending_launches:
            path = self._pending_launches.pop(block_id)
            self._settings['interactive'] = (value == 'Interactive')
            _save_settings_file(self._settings)
            _log(f'Session mode: {value!r} → launching {path!r}')
            await self.clear_block(block_id)
            if path:
                asyncio.create_task(self._launch_codex(path))
            return

        if value == '__switch_mode__':
            # Toggle saved interactive setting and re-emit start block
            self._settings['interactive'] = not self._settings.get('interactive', True)
            _save_settings_file(self._settings)
            mode = 'Interactive' if self._settings['interactive'] else 'Headless'
            _log(f'Switched mode to {mode}')
            await self._emit_start_session_block(force=True)
            return
        if value == '__permissions__':
            next_mode = 'supervised' if _load_permission_mode() == 'full-auto' else 'full-auto'
            _save_permission_mode(next_mode)
            _log(f'Switched permission mode to {next_mode}')
            for sid in list(self._sessions):
                self._schedule_session_tile(sid, delay=0.0)
            return

        # Find which session this block belongs to.
        # First try an exact match on the session block_id, then fall back to a
        # sanitized-prefix substring match for menu/slash/toggle blocks.
        session_id = None
        for sid in self._sessions:
            if block_id == self._session_block_id(sid):
                session_id = sid
                break
        if not session_id:
            for sid in self._sessions:
                sid_short = self._sanitize_id(sid[:8])
                if sid_short in block_id:
                    session_id = sid
                    break
        if not session_id:
            return

        if value == '__close_session__':
            info = self._sessions.get(session_id, {})
            tmux_target = info.get('tmux_target', '')
            if tmux_target:
                # Interrupt any running task then quit Codex CLI
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, 'C-c'],
                               capture_output=True, timeout=3)
                await asyncio.sleep(0.3)
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, 'C-c'],
                               capture_output=True, timeout=3)
                await asyncio.sleep(0.3)
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, '/quit', 'Enter'],
                               capture_output=True, timeout=3)
                _log(f'Sent C-c x2 + /quit to {tmux_target}')
            return
        elif value == '__go_interactive__':
            # User tapped the ghost button — open a Terminal.app window for this session
            info = self._sessions.get(session_id, {})
            tmux_target = info.get('tmux_target', '')
            if tmux_target:
                win_target = tmux_target.rsplit('.', 1)[0]
                # Select the window first (while name may still be valid),
                # then attach to the session to avoid "can't find window" errors.
                subprocess.run([TMUX, 'select-window', '-t', win_target],
                               capture_output=True, timeout=3)
                attach_cmd = (
                    'for i in 1 2 3 4 5; do '
                    'tmux attach-session -t codex && break; '
                    'sleep 1; done; exit'
                )
                osascript_script = f'tell application "Terminal" to do script "{attach_cmd}"'
                subprocess.Popen(['osascript', '-e', osascript_script],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                _log(f'Go interactive: opened Terminal.app for {win_target}')
                info['is_headless'] = False
                self._schedule_session_tile(session_id)
            return
        elif value == '__view_log__':
            info = self._sessions.get(session_id, {})
            tmux_target = info.get('tmux_target', '')
            if tmux_target:
                try:
                    r = subprocess.run(
                        [TMUX, 'capture-pane', '-t', tmux_target, '-p', '-S', '-50'],
                        capture_output=True, text=True, timeout=5,
                    )
                    log_text = r.stdout.strip() if r.returncode == 0 else '(no output)'
                except Exception as e:
                    log_text = f'(capture failed: {e})'
                block_id_log = f'codex2-log-{self._sanitize_id(session_id[:16])}'
                await self.emit_block(block_id_log, 'info_card', {
                    'title': info.get('project', session_id[:12]),
                    'pairs': [{'key': 'output', 'value': log_text[-2000:]}],
                }, ttl=60)
            return
        elif block_id == self._session_block_id(session_id):
            if value:
                ok = await self._send_session_text(session_id, value)
                if ok and session_id in self._sessions:
                    self._sessions[session_id]['is_working'] = True
                    self._sessions[session_id]['current_prompt'] = value[:200]
                    self._sessions[session_id]['last_seen'] = datetime.datetime.now().timestamp()
                    _save_sessions(self._sessions)
                    self._schedule_session_tile(session_id)
            return
        elif '-menu-' in block_id:
            # Value is "N  option text" — extract the leading number to send to tmux
            num = value.split()[0] if value else '1'
            await self._tm_send_text(session_id, num)
            asyncio.create_task(self._capture_tui_result(session_id))
        elif '-slash-' in block_id:
            # Value is the slash command string (e.g. "/model")
            await self._tm_send_text(session_id, value)
            asyncio.create_task(self._capture_tui_result(session_id))
        elif '-toggle-' in block_id:
            # Toggle: navigate to item and press space
            await self._tm_send_key(session_id, 'space')

        # Clear the picker block after responding
        try:
            await self.clear_block(block_id)
        except Exception:
            pass

    async def _read_stdin(self):
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
            if line:
                asyncio.create_task(self._handle_rpc_line(line))

    async def run(self):
        _log('codex-2 starting')
        _install_hooks()
        server = await self._start_socket_server()

        stdin_task = asyncio.create_task(self._read_stdin())

        try:
            # Script initiates the MCP handshake with AskMac
            await self._rpc('initialize', {
                'protocolVersion': '2024-11-05',
                'capabilities': {},
                'clientInfo': {'name': 'codex-2', 'version': '1.0'},
            })
            self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            self._initialized = True
            _log('MCP initialized')

            # Restore sessions persisted before daemon restart
            persisted = _load_sessions()
            for session_id, info in persisted.items():
                if session_id not in self._sessions:
                    self._sessions[session_id] = info
                    _log(f'Restored session {session_id} from disk')
                    await self._handle_session_active({
                        'session_id': session_id,
                        'cwd': info.get('cwd', ''),
                        'tty': info.get('tty', ''),
                        'tmux_target': info.get('tmux_target', ''),
                        'pid': info.get('pid', 0),
                    })

            # Clear any permission blocks orphaned by a previous crash.
            # Must run after MCP init so clear_block calls can reach AskMac.
            stale_blocks = _load_active_blocks()
            if stale_blocks:
                _log(f'Clearing {len(stale_blocks)} orphaned block(s) from previous run')
                for bid in stale_blocks:
                    try:
                        await self.clear_block(bid)
                    except Exception:
                        pass
                _save_active_blocks(set())

            await self.emit_block(TILE_ID, 'tile', {
                'label': 'No sessions',
                'status_color': 'blue',
                'action_required': False,
            }, ttl=600)
            # Emit the start-session block so the + button appears on iPhone
            await self._emit_start_session_block(force=True)
            # Discover any Codex sessions already running before we started
            await self._discover_active_sessions()
            # Check terminal-manager is reachable
            try:
                await asyncio.wait_for(self._call_tool('list_sessions', {}), timeout=5.0)
                _log('terminal-manager: reachable')
            except Exception as e:
                _log(f'terminal-manager: unreachable ({e})', 'WARN')
                await self.emit_block('codex2-tm-diagnostic', 'alert', {
                    'title': 'terminal-manager not running',
                    'body': 'TUI detection is unavailable. Start terminal-manager to enable interactive prompts on iPhone.',
                }, ttl=300, force=True)
        except Exception as e:
            _log(f'MCP initialize error: {e}', 'WARN')

        asyncio.create_task(self._session_heartbeat())

        async with server:
            await stdin_task


async def main():
    controller = CodexController()
    await controller.run()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.unlink(SOCKET_PATH)
        except Exception:
            pass
