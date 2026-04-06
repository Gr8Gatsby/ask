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
SETTINGS_BLOCK_ID     = 'codex2-settings'
SETTINGS_PATH         = os.path.expanduser('~/.ask/codex2-settings.json')
SESSION_TTL           = 300  # heartbeat refreshes every 30s; 300s gives buffer for MCP hiccups

# Common repo search roots — scanned by start_session picker
REPO_SEARCH_DIRS = [
    os.path.expanduser('~/Documents/code'),
    os.path.expanduser('~/code'),
    os.path.expanduser('~/projects'),
    os.path.expanduser('~/Developer'),
]

CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')
CODEX_HOOKS_PATH  = os.path.expanduser('~/.codex/hooks.json')

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
    hooks = {
        'hooks': {
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
    }
    os.makedirs(os.path.dirname(CODEX_HOOKS_PATH), exist_ok=True)
    try:
        with open(CODEX_HOOKS_PATH, 'w') as f:
            json.dump(hooks, f, indent=2)
        _log(f'Wrote hooks to {CODEX_HOOKS_PATH}')
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


# ── Helpers ───────────────────────────────────────────────────────────────────

def _find_tmux_target(session_name: str = 'codex') -> str:
    """Return 'session:window.pane' if a tmux session named 'codex' exists."""
    try:
        r = subprocess.run(
            [TMUX, 'list-panes', '-t', session_name, '-F',
             '#{session_name}:#{window_index}.#{pane_index}'],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0:
            first = r.stdout.strip().splitlines()[0]
            return first
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
        # Persistent settings (interactive mode, etc.)
        self._settings = _load_settings_file()
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
            return
        try:
            await self._call_tool('send_key', {'session_id': tm_sid, 'key': key})
        except Exception as e:
            _log(f'send_key error: {e}', 'WARN')

    async def _tm_send_text(self, session_id: str, text: str):
        tm_sid = self._tm_sessions.get(session_id)
        if not tm_sid:
            return
        try:
            await self._call_tool('send_text', {'session_id': tm_sid, 'text': text})
        except Exception as e:
            _log(f'send_text error: {e}', 'WARN')

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
        target = tmux_target or _find_tmux_target('codex')
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
        # Each button shows "N  <full option text>" so user can see what they're choosing.
        # On response, we parse the leading number to send to tmux.
        option_values = [f'{i+1}  {opt}' for i, opt in enumerate(options)]
        block_id = f'codex2-menu-{self._sanitize_id(session_id[:8])}'
        payload = {
            'title': cmd_title or 'Select an option',
            'body': '',
            'options': option_values,
            'session_id': session_id,
        }
        await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        return block_id

    async def _emit_slash_menu(self, session_id: str, result: dict):
        commands = result.get('commands', [])
        if not commands:
            return None
        body = '\n'.join(f"{c['cmd']}  {c.get('desc', '')}" for c in commands)
        options = [c['cmd'] for c in commands]
        block_id = f'codex2-slash-{self._sanitize_id(session_id[:8])}'
        payload = {
            'title': 'Slash commands',
            'body': body,
            'options': options,
            'session_id': session_id,
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

            await asyncio.sleep(2.0)

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
                # Look for panes running node (Codex) in a session named 'codex'
                if session_name.lower() != 'codex' or cmd.lower() not in ('node', 'codex'):
                    continue
                # Generate a stable synthetic session_id from the tmux target
                synth_id = f'tmux-{target}'
                if synth_id in self._sessions:
                    continue
                # Skip if a real (non-synthetic) session already covers this tmux target.
                # This prevents duplicate sessions after codex-2 reloads while Codex is running.
                target_prefix = target.split('.')[0]  # e.g. "codex:0"
                real_exists = any(
                    not sid.startswith('tmux-') and
                    info.get('tmux_target', '').split('.')[0] == target_prefix
                    for sid, info in self._sessions.items()
                )
                if real_exists:
                    _log(f'Skipping discovery for {target} — real session already registered')
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
        except Exception as e:
            _log(f'Session discovery error: {e}', 'WARN')

    async def _session_heartbeat(self):
        """Periodically rediscover sessions, validate PIDs, and refresh TTLs."""
        while True:
            await asyncio.sleep(30)
            try:
                # Validate existing sessions — clean up any whose process died
                for session_id in list(self._sessions.keys()):
                    info = self._sessions.get(session_id, {})
                    pid = info.get('pid', 0)
                    if pid and not _pid_running(pid):
                        _log(f'PID {pid} gone — cleaning up session {session_id[:12]}')
                        asyncio.create_task(self._handle_session_stop(
                            {'session_id': session_id, 'last_message': 'Session ended'}))
                        continue
                    # Refresh session block TTL so it doesn't expire while we're running.
                    # Use force=True to bypass dedup — content may be unchanged but
                    # CloudKit needs the TTL refreshed or the record disappears.
                    if session_id in self._sessions:
                        await self._emit_session_tile(session_id, force=True)

                await self._discover_active_sessions()

                if not self._sessions:
                    await self.emit_block(TILE_ID, 'tile', {
                        'label': 'No sessions',
                        'status_color': 'blue',
                        'action_required': False,
                    }, ttl=600)
                # Always refresh persistent blocks to prevent TTL expiry
                await self._emit_start_session_block(force=True)
                await self._emit_settings_block(force=True)
            except Exception:
                pass

    async def _handle_session_active(self, msg: dict):
        raw_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        raw_tty = msg.get('tty', '')
        if not raw_id:
            return

        tty = _tty_to_dev(raw_tty)
        tmux_target = msg.get('tmux_target') or _find_tmux_target('codex')

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
        # Resolve to stable ID; fall back to raw_id if tmux is already gone
        tmux_target = _find_tmux_target('codex')
        session_id = self._stable_id(raw_id, tmux_target) if raw_id in self._sessions or not raw_id.startswith('tmux-') else raw_id
        if session_id not in self._sessions:
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
        self._start_repos = {name: path for name, path in repos}
        repo_list = [{'name': name, 'path': path} for name, path in repos]
        if not repo_list:
            repo_list = [{'name': '(no repos found)', 'path': ''}]
        payload = {'repos': repo_list}
        await self.emit_block(START_SESSION_BLOCK_ID, 'start_session', payload,
                              ttl=600, force=force)

    async def _emit_settings_block(self, force: bool = False):
        """Emit the interactive-mode settings block so the user can toggle it from iPhone."""
        interactive = self._settings.get('interactive', True)
        mode_label = 'Interactive' if interactive else 'Headless'
        payload = {
            'title': 'Session Mode',
            'body': f'New sessions open in: {mode_label}\n\nInteractive opens a Terminal window.\nHeadless runs silently in the background.',
            'options': ['Interactive', 'Headless'],
        }
        await self.emit_block(SETTINGS_BLOCK_ID, 'confirmation', payload, ttl=600, force=force)

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

        r = subprocess.run([TMUX, 'has-session', '-t', 'codex'],
                           capture_output=True, timeout=3)
        if r.returncode == 0:
            # Session exists — open Codex in a new window.
            # -P -F prints the new window index atomically (no name lookup needed).
            r2 = subprocess.run([
                TMUX, 'new-window', '-t', 'codex', '-c', repo_path, '-n', project,
                '-P', '-F', '#{window_index}',
                shell, '-l', '-c', shell_cmd,
            ], capture_output=True, text=True, timeout=5)
            win_idx = r2.stdout.strip()
            pane_target = f'codex:{win_idx}.0' if win_idx else ''
            _log(f'new-window rc={r2.returncode} win_idx={win_idx!r} stderr={r2.stderr.strip()!r}')
        else:
            # Create a new detached tmux session; window index is always 0.
            r2 = subprocess.run([
                TMUX, 'new-session', '-d', '-s', 'codex',
                '-c', repo_path, '-n', project,
                shell, '-l', '-c', shell_cmd,
            ], capture_output=True, text=True, timeout=5)
            pane_target = 'codex:0.0'
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
            if synth_id not in self._sessions:
                pid = _get_pane_pid(pane_target)
                await self._handle_session_active({
                    'session_id': synth_id,
                    'cwd': repo_path,
                    'tty': '',
                    'tmux_target': pane_target,
                    'pid': pid,
                })

        # Open a Terminal.app window attached to the new pane if interactive mode is on
        if self._settings.get('interactive', True) and pane_target:
            try:
                # Target the specific window (e.g. 'codex:2' from 'codex:2.0')
                win_target = pane_target.rsplit('.', 1)[0]
                attach_cmd = f'tmux attach-session -t {win_target}'
                osascript_script = f'tell application "Terminal" to do script "{attach_cmd}"'
                subprocess.Popen(['osascript', '-e', osascript_script],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                _log(f'Opened Terminal.app for {win_target}')
            except Exception as e:
                _log(f'Could not open Terminal.app: {e}', 'WARN')

        # Schedule a delayed pane snapshot to log what Codex shows on startup
        if pane_target:
            asyncio.create_task(self._log_pane_snapshot(pane_target, delay=8))

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
                session_id = self._stable_id(raw_id) if raw_id else ''
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
                    info['current_tool'] = display_tool
                    last_msg = msg.get('last_message', '')
                    if last_msg:
                        info['last_message'] = last_msg
                        info.pop('current_preview', None)  # clear stale preview when message arrives
                    self._schedule_session_tile(session_id)
                elif session_id:
                    await self._handle_session_active(msg)
            elif t in ('pre_tool_use', 'user_prompt_submit'):
                raw_id = msg.get('session_id', '')
                session_id = self._stable_id(raw_id) if raw_id else ''
                if session_id and session_id in self._sessions:
                    info = self._sessions[session_id]
                    info['is_working'] = True
                    if t == 'pre_tool_use':
                        tool = msg.get('tool_name', msg.get('tool', ''))
                        if tool:
                            info['current_tool'] = _map_tool_name(tool)
                    self._schedule_session_tile(session_id)
            elif t == 'permission_request':
                # Hook is blocking on a response -- emit confirmation, wait, reply.
                value = await self._handle_permission_from_hook(msg)
                writer.write(json.dumps({'value': value}).encode())
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
        # Always resolve to stable tmux-based ID
        session_id = self._stable_id(raw_id) if raw_id else next(iter(self._sessions), 'unknown')
        if session_id not in self._sessions:
            session_id = next(iter(self._sessions), 'unknown')

        block_id = self._permission_block_id(session_id, tool)
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pending_permissions[block_id] = fut

        payload = {
            'title': f'Allow {tool}?',
            'body': preview,
            'options': options,
            'session_id': session_id,
        }
        try:
            await self.emit_block(block_id, 'confirmation', payload, inbox=True)
        except Exception as e:
            _log(f'emit_block for permission failed: {e}', 'WARN')
            self._pending_permissions.pop(block_id, None)
            return 'Deny'

        # Mark session as working while waiting for permission
        if session_id in self._sessions:
            info = self._sessions[session_id]
            info['is_working'] = True
            info['current_tool'] = _map_tool_name(tool)
            info['current_preview'] = preview[:100] if preview else ''
            self._schedule_session_tile(session_id)

        _log(f'Waiting for permission: {tool!r} session={session_id[:12]!r}')
        try:
            value = await asyncio.wait_for(fut, timeout=120.0)
        except asyncio.TimeoutError:
            _log(f'Permission timed out for {tool!r}', 'WARN')
            value = 'Deny'
        finally:
            self._pending_permissions.pop(block_id, None)
            try:
                await self.clear_block(block_id)
            except Exception:
                pass

        _log(f'Permission resolved: {tool!r} => {value!r}')
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
                session_id = data.get('sessionId', '')
                if text and session_id:
                    _log(f'chat_message → session={session_id[:12]!r} text={text[:60]!r}')
                    await self._tm_send_text(session_id, text)
                elif text:
                    # Fall back to first session if sessionId not matched
                    sid = next(iter(self._sessions), None)
                    if sid:
                        _log(f'chat_message (fallback) → session={sid[:12]!r} text={text[:60]!r}')
                        await self._tm_send_text(sid, text)
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
        if block_id == SETTINGS_BLOCK_ID:
            self._settings['interactive'] = (value == 'Interactive')
            _save_settings_file(self._settings)
            mode = 'Interactive' if self._settings['interactive'] else 'Headless'
            _log(f'Session mode set to: {mode}')
            await self._emit_settings_block(force=True)
            return

        if block_id == START_SESSION_BLOCK_ID:
            # value is the repo path sent by the iPhone picker
            path = self._start_repos.get(value, value)
            if path and path != '(no repos found)':
                asyncio.create_task(self._launch_codex(path))
            return

        # Find which session this block belongs to (match sanitized prefix)
        session_id = None
        for sid in self._sessions:
            sid_short = self._sanitize_id(sid[:8])
            if sid_short in block_id:
                session_id = sid
                break
        if not session_id:
            return

        if value == '__close_session__':
            # User tapped Stop — send Ctrl+C twice to interrupt and exit Codex
            info = self._sessions.get(session_id, {})
            tmux_target = info.get('tmux_target', '')
            if tmux_target:
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, 'C-c'],
                               capture_output=True, timeout=3)
                await asyncio.sleep(0.3)
                subprocess.run([TMUX, 'send-keys', '-t', tmux_target, 'C-c'],
                               capture_output=True, timeout=3)
                _log(f'Sent C-c x2 to {tmux_target}')
            return
        elif '-menu-' in block_id:
            # Value is "N  option text" — extract the leading number to send to tmux
            num = value.split()[0] if value else '1'
            await self._tm_send_text(session_id, num)
        elif '-slash-' in block_id:
            # Value is the slash command string (e.g. "/model")
            await self._tm_send_text(session_id, value)
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
            await self.emit_block(TILE_ID, 'tile', {
                'label': 'No sessions',
                'status_color': 'blue',
                'action_required': False,
            }, ttl=600)
            # Emit the start-session block so the + button appears on iPhone
            await self._emit_start_session_block(force=True)
            # Emit the interactive-mode settings block
            await self._emit_settings_block(force=True)
            # Discover any Codex sessions already running before we started
            await self._discover_active_sessions()
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
