#!/usr/bin/env python3
"""
claude-3 — feed-first Claude Code session supervisor.

Architecture:
  - Unix socket server receives hook events from Claude Code (SessionStart,
    PreToolUse, PostToolUse, Stop, UserPromptSubmit, PermissionRequest,
    PreCompact, PostCompact)
  - MCP JSON-RPC over stdio connects to the Ask daemon for block/task emission
  - Terminal routing goes through terminal-manager (inject_tty / send_text)
  - Each session is backed by an A2A task (open_task / append_message /
    put_artifact) so history appears in the iOS Feed tab
  - One agent_session block per live session; permissions embedded inline
"""
import asyncio
import datetime
import json
import os
import shlex
import sys
import tempfile
import uuid
from typing import Optional

from registry import PendingPermission, SessionRecord, SessionRegistry
from transport import find_repos

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claude-3.sock'))
LOG_PATH = os.path.expanduser('~/.ask/logs/claude-3.log')
SESSIONS_PATH = os.environ.get('ASK_CLAUDE3_SESSIONS_PATH', os.path.expanduser('~/.ask/claude3-sessions.json'))
ALLOWLIST_PATH = os.environ.get('ASK_CLAUDE3_ALLOWLIST_PATH', os.path.expanduser('~/.ask/claude3-allowlist.json'))
PERMISSION_MODE_PATH = os.environ.get('ASK_CLAUDE3_PERMISSION_MODE_PATH', os.path.expanduser('~/.ask/claude3-permission-mode.json'))
CLAUDE_SETTINGS_PATH = os.path.expanduser('~/.claude/settings.json')

TILE_BLOCK_ID = 'claude-3-tile'
START_BLOCK_ID = 'claude3-start'
SESSION_TTL = 86400   # 24 hours — disk-persisted sessions
BLOCK_TTL = 3600      # agent_session block TTL in CloudKit
PERMISSION_TIMEOUT = 180.0  # seconds to wait for iPhone response

# Terminal-mirror feature: stream tmux pane scrollback into the chat as
# role="terminal" messages. Off by default; opt in with ASK_MIRROR=1 until
# clients render the new role.
MIRROR_ENABLED_GLOBAL = os.environ.get('ASK_MIRROR') == '1'
MIRROR_INTERVAL_SECS = 5
MIRROR_MAX_CHUNK_BYTES = 20_000
MIRROR_CAPTURE_LINES = 500   # rows of scrollback to capture per sample


# ---------------------------------------------------------------------------
# Logging / JSON helpers
# ---------------------------------------------------------------------------

def _log(message: str, level: str = 'INFO'):
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [{level}] {message}"
    print(line, file=sys.stderr, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as fh:
            fh.write(line + '\n')
    except Exception:
        pass


def _load_json(path: str, fallback):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return fallback


def _save_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        json.dump(data, fh, indent=2)


# ---------------------------------------------------------------------------
# Permission mode helpers
# ---------------------------------------------------------------------------

def _load_permission_mode() -> str:
    raw = _load_json(PERMISSION_MODE_PATH, {'mode': 'supervised'})
    mode = raw.get('mode', 'supervised')
    return mode if mode in ('supervised', 'full-auto') else 'supervised'


def _save_permission_mode(mode: str):
    _save_json(PERMISSION_MODE_PATH, {'mode': mode})


# ---------------------------------------------------------------------------
# Allowlist helpers
# ---------------------------------------------------------------------------

def _is_allowlisted(preview: str) -> bool:
    if not preview:
        return False
    data = _load_json(ALLOWLIST_PATH, {'patterns': []})
    return preview in data.get('patterns', [])


def _append_allowlist(preview: str):
    if not preview:
        return
    data = _load_json(ALLOWLIST_PATH, {'patterns': []})
    patterns = data.setdefault('patterns', [])
    if preview not in patterns:
        patterns.append(preview)
        _save_json(ALLOWLIST_PATH, data)


# ---------------------------------------------------------------------------
# Session persistence helpers
# ---------------------------------------------------------------------------

def _load_registry() -> SessionRegistry:
    raw = _load_json(SESSIONS_PATH, {})
    now = datetime.datetime.now().timestamp()
    active = {
        sid: info for sid, info in raw.items()
        if (now - float(info.get('last_seen', now))) < SESSION_TTL
        and info.get('state') != 'stopped'
        and not info.get('is_transient', False)
    }
    return SessionRegistry.from_dict(active)


def _save_registry(registry: SessionRegistry):
    # Never persist transient process-discovered sessions
    to_save = {
        sid: s.to_dict() for sid, s in registry.sessions.items()
        if not s.is_transient
    }
    _save_json(SESSIONS_PATH, to_save)


# ---------------------------------------------------------------------------
# Hook installation
# ---------------------------------------------------------------------------

HOOK_MAP = {
    'PreToolUse':        'pre_tool_use.py',
    'PostToolUse':       'post_tool_use.py',
    'PermissionRequest': 'permission_request.py',
    'Stop':              'session_stop.py',
    'UserPromptSubmit':  'user_prompt_submit.py',
    'SessionStart':      'session_start.py',
    'PreCompact':        'pre_compact.py',
    'PostCompact':       'post_compact.py',
}


def _install_hooks():
    hooks_dir = os.path.join(SCRIPT_DIR, 'hooks')
    os.makedirs(os.path.dirname(CLAUDE_SETTINGS_PATH), exist_ok=True)
    settings = _load_json(CLAUDE_SETTINGS_PATH, {})
    settings.setdefault('hooks', {})
    changed = False
    for event, filename in HOOK_MAP.items():
        script_path = os.path.join(hooks_dir, filename)
        if not os.path.exists(script_path):
            continue
        existing = settings['hooks'].setdefault(event, [])
        already = any(
            script_path in hook.get('command', '')
            for block in existing
            for hook in block.get('hooks', [])
        )
        if already:
            continue
        target = next((b for b in existing if b.get('matcher') == ''), None)
        if target is None:
            target = {'matcher': '', 'hooks': []}
            existing.append(target)
        target.setdefault('hooks', [])
        target['hooks'].append({'type': 'command', 'command': script_path})
        changed = True
    if changed:
        with open(CLAUDE_SETTINGS_PATH, 'w') as fh:
            json.dump(settings, fh, indent=4)
        _log('Claude Code hooks installed')


# ---------------------------------------------------------------------------
# Main controller
# ---------------------------------------------------------------------------

class Claude3:

    def __init__(self):
        self._next_id = 0
        self._pending_calls: dict[int, asyncio.Future] = {}
        self._registry = _load_registry()
        self._pending_permissions: dict[str, asyncio.Future] = {}
        self._start_choices: dict[str, dict] = {}
        self._tty_monitors: set[str] = set()  # session_ids with running monitors
        self._pending_tmux_by_cwd: dict[str, str] = {}  # cwd → tmux_target for in-flight launches
        self._initialized = False
        self._emitted_payloads: dict[str, str] = {}  # block_id → last serialized payload
        self._post_restart_reset_done = False  # reset transient states once after restart
        self._mirror_tasks: dict[str, asyncio.Task] = {}  # session_id → terminal-mirror task

    # ------------------------------------------------------------------
    # MCP JSON-RPC primitives
    # ------------------------------------------------------------------

    def _id(self) -> int:
        self._next_id += 1
        return self._next_id

    def _write(self, obj: dict):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method: str, params: dict = None, timeout: float = 15.0):
        rpc_id = self._id()
        fut = asyncio.get_running_loop().create_future()
        self._pending_calls[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._write(msg)
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending_calls.pop(rpc_id, None)
            raise

    async def _call_tool(self, name: str, arguments: dict = None, timeout: float = 15.0):
        result = await self._rpc('tools/call', {'name': name, 'arguments': arguments or {}}, timeout=timeout)
        if isinstance(result, dict) and 'content' not in result:
            return result
        try:
            return json.loads(result['content'][0]['text'])
        except Exception:
            return result

    # ------------------------------------------------------------------
    # Block / task primitives
    # ------------------------------------------------------------------

    async def emit_block(self, block_id: str, block_type: str, payload: dict,
                         ttl: int = None, inbox: bool = False):
        serialized = json.dumps(payload, sort_keys=True)
        if self._emitted_payloads.get(block_id) == serialized:
            return  # nothing changed — skip the emit
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._call_tool('emit_block', args)
        self._emitted_payloads[block_id] = serialized  # only cache after successful emit

    async def clear_block(self, block_id: str):
        await self._call_tool('clear_block', {'blockId': block_id})

    # A2A calls involve CloudKit writes and can be slow.  Give them a generous
    # timeout and fire them as background tasks so handlers never block on them.
    _A2A_TIMEOUT = 60.0

    def _fire_a2a(self, coro) -> None:
        """Schedule an A2A write as a background task; the caller continues immediately."""
        async def _run():
            try:
                await coro
            except Exception as exc:
                _log(f'a2a write failed: {exc!r}', 'WARN')
        asyncio.create_task(_run())

    async def open_task(self, task_id: str, title: str, status: str):
        await self._call_tool('open_task', {'taskId': task_id, 'title': title, 'status': status},
                              timeout=self._A2A_TIMEOUT)

    async def append_message(self, task_id: str, role: str, text: str):
        await self._call_tool('append_message', {
            'taskId': task_id,
            'role': role,
            'parts': [{'type': 'text', 'text': text}],
        }, timeout=self._A2A_TIMEOUT)

    async def put_artifact(self, task_id: str, artifact_id: str, filename: str,
                           mime_type: str, description: str, file_path: str):
        await self._call_tool('put_artifact', {
            'taskId': task_id,
            'artifactId': artifact_id,
            'filename': filename,
            'mimeType': mime_type,
            'description': description,
            'filePath': file_path,
        }, timeout=self._A2A_TIMEOUT)

    # ------------------------------------------------------------------
    # Block IDs
    # ------------------------------------------------------------------

    def _session_block_id(self, session_id: str) -> str:
        return f'claude3-session-{session_id.split(":")[-1]}'

    # ------------------------------------------------------------------
    # Block emission
    # ------------------------------------------------------------------

    async def _emit_tile(self):
        states = [s.state for s in self._registry.sessions.values() if s.state != 'stopped']
        session_ids = [s.session_id for s in self._registry.sessions.values()]
        _log(f'_emit_tile: sessions={session_ids} states={states}')
        if not states:
            label, color = 'No sessions', 'blue'
        elif any(s == 'waiting_permission' for s in states):
            label, color = 'Permission needed', 'orange'
        elif any(s in ('running_tool', 'awaiting_user', 'starting') for s in states):
            label, color = 'Working', 'blue'
        else:
            n = len(states)
            label, color = f'{n} session{"s" if n != 1 else ""}', 'gray'
        _log(f'_emit_tile: emitting label={label!r}')
        await self.emit_block(TILE_BLOCK_ID, 'tile', {
            'label': label,
            'status_color': color,
            'action_required': label == 'Permission needed',
        }, ttl=600)

    async def _emit_start_session_block(self, scan: bool = False):
        """Emit the repo picker block.

        By default, does NOT walk the filesystem to find repos — that triggers a
        macOS Documents-folder TCC prompt on every daemon startup, which is poor
        UX. Instead, on first launch we emit an empty picker with a "scan" CTA;
        the user explicitly opts in to scanning by clicking it (which triggers
        `__scan_repos__` → `_emit_start_session_block(scan=True)`).

        After a successful scan, the result is cached at `~/.ask/claude3-repos.json`
        and used directly on subsequent emits — no rescan needed unless the user
        asks for one.
        """
        cache_path = os.path.expanduser('~/.ask/claude3-repos.json')
        cached = _load_json(cache_path, {}).get('repos', [])
        if scan:
            try:
                discovered = await asyncio.wait_for(asyncio.to_thread(find_repos), timeout=3.0)
                _save_json(cache_path, {'repos': [{'name': n, 'path': p} for n, p in discovered],
                                        'scanned_at': datetime.datetime.now().timestamp()})
                cached = [{'name': n, 'path': p} for n, p in discovered]
                _log(f'find_repos scan: {len(cached)} repos cached')
            except Exception as exc:
                _log(f'find_repos scan failed ({exc!r})', 'WARN')

        choices = []
        self._start_choices = {}
        settings_path = os.path.expanduser('~/.ask/claude3-settings.json')
        settings = _load_json(settings_path, {'recent_repos': []})
        recent = settings.get('recent_repos', [])
        cached.sort(key=lambda r: recent.index(r['path']) if r['path'] in recent else len(recent))
        for r in cached:
            self._start_choices[r['path']] = {'repo_path': r['path']}
            choices.append({'name': r['name'], 'path': r['path'], 'value': r['path']})

        payload: dict = {'repos': choices}
        if not choices:
            # No cached repos yet — surface a scan CTA. The block UI sends
            # `__scan_repos__` when the user clicks it.
            payload['needs_scan'] = True
            payload['scan_action'] = {'id': '__scan_repos__', 'label': 'Scan ~/Documents/code for repos'}
        else:
            # Repos cached; offer a rescan affordance for when the user has
            # added a new repo since the last scan.
            payload['rescan_action'] = {'id': '__scan_repos__', 'label': 'Rescan for new repos'}
        # Clear dedup cache so TTL refreshes on every emit (block expires if not refreshed)
        self._emitted_payloads.pop(START_BLOCK_ID, None)
        await self.emit_block(START_BLOCK_ID, 'start_session', payload, ttl=3600)
        _log(f'emitted start_session block with {len(choices)} repos (cached, scan={scan})')

    async def _emit_session_block(self, session: SessionRecord):
        is_tmux = bool(session.tmux_target)
        payload = {
            'session_id': session.session_id,
            'task_id': session.task_id,
            'agent_name': 'Claude 3',
            'brand_color': '#D97757',
            'placeholder': 'Message Claude 3…',
            'project': session.project,
            'cwd': session.cwd,
            'is_working': session.state in ('starting', 'awaiting_user', 'running_tool', 'waiting_permission'),
            'is_headless': False,
            'is_tmux': is_tmux,
            'permission_mode': _load_permission_mode(),
            'tty': session.tty,
            'tmux_target': session.tmux_target or None,
            'current_tool': session.current_tool or None,
            'current_preview': session.preview or None,
            'last_message': session.last_message or None,
            'status_text': session.state.replace('_', ' ').title(),
            'preview': session.preview or None,
        }
        if session.pending_permission:
            payload['pending_confirmation'] = {
                'request_id': session.pending_permission.request_id,
                'title': f'Allow {session.pending_permission.tool}?',
                'body': session.pending_permission.preview,
                'options': session.pending_permission.options,
            }
        # Offer migrate action for terminal-observed sessions that have a raw_id
        if not is_tmux and session.raw_id:
            payload['actions'] = [{'id': '__migrate_to_tmux__', 'label': 'Move to tmux'}]
        _log(f'_emit_session_block: {session.session_id} state={session.state} tty={session.tty!r} tmux={session.tmux_target!r}')
        await self.emit_block(
            self._session_block_id(session.session_id),
            'agent_session',
            payload,
            ttl=BLOCK_TTL,
        )

    # ------------------------------------------------------------------
    # Task feed helpers
    # ------------------------------------------------------------------

    async def _set_task_status(self, session: SessionRecord, status: str):
        title = f'Claude 3 · {session.project}'
        await self.open_task(session.task_id, title, status)

    async def _append_structured_message(self, session: SessionRecord, kind: str,
                                         body: str, role: str = 'assistant'):
        if not body:
            return
        text = f'### {kind}\n{body}'
        await self.append_message(session.task_id, role, text)

    async def _append_artifact_if_large(self, session: SessionRecord, title: str, text: str):
        if len(text) < 1600:
            return
        fd, path = tempfile.mkstemp(prefix='claude3-', suffix='.md')
        os.close(fd)
        with open(path, 'w') as fh:
            fh.write(text)
        await self.put_artifact(
            session.task_id,
            f'artifact-{uuid.uuid4().hex[:8]}',
            f'{session.project}-{title.lower().replace(" ", "-")}.md',
            'text/markdown',
            title,
            path,
        )

    # ------------------------------------------------------------------
    # Terminal mirror — periodically capture tmux pane and emit as messages
    # ------------------------------------------------------------------

    @staticmethod
    def _diff_frame(old: str, new: str) -> str:
        """Return the substring of `new` that's content NOT already in `old`.

        Strategy: find the longest prefix of `new` that matches a suffix of
        `old`; everything after that prefix is the new content. Covers two
        common cases:
          - Append: `new = old + appended` → emit just `appended`
          - Scroll: `old = top + middle`, `new = middle + bottom` → emit just
            `bottom`

        Edits in the middle of the window (cursor moves up, rewrites a line)
        produce no overlap match and fall back to emitting the whole frame.
        """
        if not old:
            return new
        if old == new:
            return ''
        old_lines = old.splitlines()
        new_lines = new.splitlines()
        max_overlap = min(len(old_lines), len(new_lines))
        for k in range(max_overlap, 0, -1):
            if new_lines[:k] == old_lines[-k:]:
                tail = new_lines[k:]
                return '\n'.join(tail)
        return new

    async def _capture_pane(self, target: str) -> tuple[str, str]:
        """Returns (text, error) — error is '' on success, otherwise a code.

        Codes: 'pane_gone', 'timeout', 'rpc_error'.
        """
        try:
            result = await self._call_tool(
                'capture_pane',
                {'target': target, 'lines': MIRROR_CAPTURE_LINES},
                timeout=4.0,
            )
        except asyncio.TimeoutError:
            return '', 'timeout'
        except Exception as exc:
            _log(f'capture_pane rpc error for {target}: {exc!r}', 'WARN')
            return '', 'rpc_error'
        if not isinstance(result, dict):
            return '', 'rpc_error'
        if result.get('error') == 'pane_gone':
            return '', 'pane_gone'
        return result.get('text', '') or '', ''

    async def _emit_terminal_chunk(self, session: SessionRecord, text: str):
        """Append a terminal-mirror message, splitting if larger than the cap."""
        if not text.strip():
            return
        if len(text.encode('utf-8')) <= MIRROR_MAX_CHUNK_BYTES:
            await self.append_message(session.task_id, 'terminal', text)
            return
        # Split on line boundaries to stay under the limit
        lines = text.splitlines()
        buf: list[str] = []
        buf_bytes = 0
        for line in lines:
            line_bytes = len(line.encode('utf-8')) + 1
            if buf_bytes + line_bytes > MIRROR_MAX_CHUNK_BYTES and buf:
                await self.append_message(session.task_id, 'terminal', '\n'.join(buf))
                buf = []
                buf_bytes = 0
            buf.append(line)
            buf_bytes += line_bytes
        if buf:
            await self.append_message(session.task_id, 'terminal', '\n'.join(buf))

    async def _mirror_loop(self, session_id: str):
        """Sample tmux pane every MIRROR_INTERVAL_SECS, emit new content.

        Runs until the session is stopped, mirroring is disabled, the pane
        reports gone, or the task is cancelled. The loop never raises out —
        all errors are logged and the loop sleeps to the next tick.
        """
        _log(f'mirror_loop start session={session_id}')
        while True:
            await asyncio.sleep(MIRROR_INTERVAL_SECS)
            session = self._registry.sessions.get(session_id)
            if session is None or session.state == 'stopped':
                _log(f'mirror_loop exit (session gone) session={session_id}')
                return
            if not session.tmux_target or not session.mirror_enabled:
                _log(f'mirror_loop exit (no target / disabled) session={session_id}')
                return
            text, err = await self._capture_pane(session.tmux_target)
            if err == 'pane_gone':
                _log(f'mirror_loop exit (pane gone) session={session_id}')
                return
            if err:
                # transient error — try again next tick
                continue
            diff = self._diff_frame(session.mirror_last_frame, text)
            # Always advance the baseline, even on emit failure, to avoid
            # amplification of identical chunks across ticks.
            session.mirror_last_frame = text
            if not diff:
                continue
            try:
                await self._emit_terminal_chunk(session, diff)
            except Exception as exc:
                _log(f'mirror_loop emit failed for {session_id}: {exc!r}', 'WARN')

    def _ensure_mirror_task(self, session: SessionRecord):
        """Start a mirror loop for this session if eligible and not already running."""
        if not MIRROR_ENABLED_GLOBAL:
            return
        if not session.tmux_target or not session.mirror_enabled:
            return
        existing = self._mirror_tasks.get(session.session_id)
        if existing is not None and not existing.done():
            return
        task = asyncio.create_task(self._mirror_loop(session.session_id))
        self._mirror_tasks[session.session_id] = task

    def _cancel_mirror_task(self, session_id: str):
        task = self._mirror_tasks.pop(session_id, None)
        if task is not None and not task.done():
            task.cancel()

    # ------------------------------------------------------------------
    # Terminal-manager routing
    # ------------------------------------------------------------------

    async def _tm_inject_tty(self, session: SessionRecord, text: str) -> bool:
        if not session.raw_id:
            return False
        try:
            await self._rpc('tools/call', {
                'name': 'inject_tty',
                'arguments': {'session_id': session.raw_id, 'text': text},
            }, timeout=20.0)
            return True
        except Exception as e:
            _log(f'inject_tty failed for {session.session_id}: {e}', 'WARN')
            return False

    async def _tm_send_text(self, session: SessionRecord, text: str) -> bool:
        if session.tmux_target:
            args = {'target': session.tmux_target, 'text': text}
        elif session.raw_id:
            args = {'session_id': session.raw_id, 'text': text}
        else:
            return False
        try:
            await self._rpc('tools/call', {
                'name': 'send_text',
                'arguments': args,
            }, timeout=20.0)
            return True
        except Exception as e:
            _log(f'send_text failed for {session.session_id}: {e}', 'WARN')
            return False

    async def _tm_send_interrupt(self, session: SessionRecord) -> bool:
        if session.tmux_target:
            try:
                await self._call_tool('send_interrupt', {'target': session.tmux_target}, timeout=5.0)
                return True
            except Exception as e:
                _log(f'send_interrupt(tmux) failed for {session.session_id}: {e}', 'WARN')
                return False
        if not session.raw_id:
            return False
        try:
            await self._rpc('tools/call', {
                'name': 'inject_tty',
                'arguments': {'session_id': session.raw_id, 'text': '\x03'},
            }, timeout=3.0)
            return True
        except Exception as e:
            _log(f'send_interrupt failed for {session.session_id}: {e}', 'WARN')
            return False

    async def _tm_read_output(self, session: SessionRecord, lines: int = 40) -> str:
        if not session.raw_id:
            return ''
        try:
            result = await self._rpc('tools/call', {
                'name': 'read_output',
                'arguments': {'session_id': session.raw_id, 'lines': lines},
            }, timeout=4.0)
            if isinstance(result, dict):
                return '\n'.join(result.get('lines', []))
        except Exception:
            pass
        return ''

    async def _tm_register(self, session: SessionRecord):
        """Register this session with terminal-manager so inject_tty/send_text work."""
        if not session.raw_id:
            return
        if not session.tty and not session.tmux_target:
            return
        args: dict = {
            'session_id': session.raw_id,
            'app_id': 'claude-3',
            'tty': session.tty,
            'tmux_target': session.tmux_target,
        }
        if session.pid:
            args['pid'] = session.pid
        # For TTY sessions, register the interactive_prompt detector so
        # detect_tui can replace the local parse_tmux_prompt call.
        if session.tty and not session.tmux_target:
            args['hook'] = {
                'scan_lines': 40,
                'patterns': [
                    {'id': 'interactive_prompt', 'detect': {'type': 'interactive_prompt'}},
                ],
            }
        try:
            await self._rpc('tools/call', {
                'name': 'register_session',
                'arguments': args,
            }, timeout=4.0)
            _log(f'tm_register {session.session_id[:12]} tty={session.tty!r} '
                 f'tmux={session.tmux_target!r} pid={session.pid}')
        except Exception as e:
            _log(f'tm_register failed: {e!r}', 'WARN')

    async def _route_text(self, session: SessionRecord, text: str) -> bool:
        """Send user text to a session. Uses tmux send-keys for managed sessions,
        inject_tty/send_text fallback for terminal-observed sessions."""
        if session.tmux_target:
            # Wait for idle prompt, then send
            try:
                await self._call_tool('wait_for_pattern', {
                    'target': session.tmux_target,
                    'pattern': r'^[>❯]',
                    'timeout': 10.0,
                    'stable_count': 2,
                }, timeout=12.0)
            except Exception as e:
                _log(f'wait_for_pattern timed out for {session.session_id}: {e}', 'WARN')
            return await self._tm_send_text(session, text)

        text_with_newline = text if text.endswith('\n') else text + '\n'
        had_tty = bool(session.tty)
        ok = await self._tm_inject_tty(session, text_with_newline)
        if had_tty:
            return ok
        # TTY was unknown — try to discover it, re-register, and retry once.
        if session.cwd:
            discovered = await self._call_tool('discover_sessions', {'executable': 'claude'})
            for proc in (discovered or {}).get('sessions', []):
                if proc.get('cwd') == session.cwd and proc.get('tty'):
                    session.tty = proc['tty']
                    self._registry._index_aliases(session)
                    _log(f'late-discovered tty={session.tty!r} for session {session.session_id}')
                    break
        await self._tm_register(session)
        ok = await self._tm_inject_tty(session, text_with_newline)
        if not ok:
            ok = await self._tm_send_text(session, text)
        return ok

    # ------------------------------------------------------------------
    # Session launch
    # ------------------------------------------------------------------

    async def _launch(self, repo_path: str):
        repo_path = os.path.expanduser(repo_path)
        project = os.path.basename(repo_path.rstrip('/'))
        socket_quoted = SOCKET_PATH.replace("'", "'\\''")
        repo_quoted = repo_path.replace("'", "'\\''")
        shell_cmd = (
            f"cd '{repo_quoted}' && "
            f"ASK_SOCKET_PATH='{socket_quoted}' claude"
        )
        script = (
            f'tell application "Terminal"\n'
            f'    activate\n'
            f'    do script "{shell_cmd.replace(chr(34), chr(92)+chr(34))}"\n'
            f'end tell'
        )
        try:
            proc = await asyncio.create_subprocess_exec(
                'osascript', '-e', script,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=10.0)
        except Exception as e:
            _log(f'launch failed for {project}: {e}', 'WARN')
            return

        # Update recent repos setting
        settings_path = os.path.expanduser('~/.ask/claude3-settings.json')
        settings = _load_json(settings_path, {'recent_repos': []})
        recent = [repo_path] + [p for p in settings.get('recent_repos', []) if p != repo_path]
        settings['recent_repos'] = recent[:5]
        _save_json(settings_path, settings)

        await self.clear_block(START_BLOCK_ID)
        _log(f'Launched Claude Code in {project}')

    async def _launch_in_tmux(self, repo_path: str) -> Optional[str]:
        """Launch Claude Code inside a tmux window owned by the daemon.

        Returns the tmux target string ('ask:<project>') or None on failure.
        """
        repo_path = os.path.expanduser(repo_path)
        project = os.path.basename(repo_path.rstrip('/'))
        shell = os.environ.get('SHELL', '/bin/zsh')
        shell_cmd = (
            f'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '
            f'export ASK_SOCKET_PATH={shlex.quote(SOCKET_PATH)}; '
            f'cd {shlex.quote(repo_path)} && exec claude'
        )
        env_cmd = f'{shell} -l -c {shlex.quote(shell_cmd)}'
        try:
            result = await self._call_tool('create_window', {
                'session': 'ask',
                'window_name': project,
                'command': env_cmd,
                'cwd': repo_path,
            }, timeout=30.0)
            tmux_target = result.get('target', f'ask:{project}') if isinstance(result, dict) else f'ask:{project}'
        except Exception as e:
            _log(f'launch_in_tmux failed for {project}: {e}', 'WARN')
            return None

        # Track the cwd→target so _handle_session_start can backfill tmux_target
        self._pending_tmux_by_cwd[repo_path] = tmux_target

        settings_path = os.path.expanduser('~/.ask/claude3-settings.json')
        settings = _load_json(settings_path, {'recent_repos': []})
        recent = [repo_path] + [p for p in settings.get('recent_repos', []) if p != repo_path]
        settings['recent_repos'] = recent[:5]
        _save_json(settings_path, settings)

        # Don't clear START_BLOCK_ID here — _handle_session_start re-emits it once
        # the session connects. If we clear it now and the hook is delayed, the "+"
        # button disappears permanently.
        _log(f'Launched Claude Code in tmux for {project}: {tmux_target}')
        return tmux_target

    # ------------------------------------------------------------------
    # Hook event handlers
    # ------------------------------------------------------------------

    async def _handle_session_start(self, msg: dict):
        raw_id = msg.get('session_id', '')
        cwd = msg.get('cwd', '')
        tty = msg.get('tty', '') or ''
        project = msg.get('project', '') or (os.path.basename(cwd.rstrip('/')) if cwd else '')
        if not raw_id:
            return

        # Clean up any stale transient sessions that overlap with this session
        # by TTY or CWD so they don't linger as duplicates.
        for sid, s in list(self._registry.sessions.items()):
            if not s.is_transient:
                continue
            if (tty and s.tty == tty) or (cwd and s.cwd == cwd):
                _log(f'removing stale transient {sid} (tty={s.tty} cwd={s.cwd!r}) — superseded by hook session')
                await self.clear_block(self._session_block_id(sid))
                self._registry.remove(sid)

        session = self._registry.ensure(raw_id=raw_id, tty=tty, cwd=cwd, project=project)
        session.state = 'idle'
        session.permission_mode = _load_permission_mode()

        # Backfill tmux_target from the hook (preferred) or _pending_tmux_by_cwd fallback
        if not session.tmux_target:
            tmux_target = msg.get('tmux_target', '') or (self._pending_tmux_by_cwd.pop(cwd, '') if cwd else '')
            if tmux_target:
                session.tmux_target = tmux_target
                _log(f'backfilled tmux_target={tmux_target!r} for raw_id={raw_id[:8]}')

        # Register with terminal-manager FIRST so messaging works even if A2A
        # writes are slow. Without this, a flood of pending MCP calls (e.g.
        # supervisor session firing pre_tool_use storms) can stall this handler
        # before _tm_register runs, leaving send_text with "Unknown session".
        await self._tm_register(session)
        _save_registry(self._registry)
        _log(f'session_start raw_id={raw_id[:8]} tty={tty} tmux={session.tmux_target!r} project={project}')

        # A2A writes to AskMac don't gate routing — fire and forget.
        self._fire_a2a(self._set_task_status(session, 'working'))
        self._fire_a2a(self._append_structured_message(session, 'Session started', f'Launched in `{session.project}`.'))
        await self._emit_session_block(session)
        await self._emit_tile()
        await self._emit_start_session_block()

        # Start TTY monitor for interactive prompt detection
        if session.session_id not in self._tty_monitors:
            self._tty_monitors.add(session.session_id)
            asyncio.create_task(self._monitor_tty_session(session.session_id))

        # Start terminal-mirror loop for tmux sessions (no-op if not opted in)
        self._ensure_mirror_task(session)

    async def _handle_pre_tool_use(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        session = self._registry.ensure(raw_id=raw_id)
        session.current_tool = msg.get('tool', '')
        session.preview = msg.get('preview', '')[:200]
        session.state = 'running_tool'

        last_msg = (msg.get('last_message', '') or '').strip()
        if last_msg and last_msg != session.last_message:
            # Update the live block's preview so the UI shows the latest text,
            # but DON'T append to chat history here. _handle_session_stop is
            # the single writer for the assistant turn — otherwise every
            # text-tool-text-tool segment within one Claude turn becomes a
            # separate row in the transcript.
            session.last_message = last_msg

        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_tool_executed(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        session = self._registry.ensure(raw_id=raw_id)
        tool_name = msg.get('tool_name', '')
        session.current_tool = tool_name
        session.state = 'running_tool'

        last_msg = (msg.get('last_message', '') or '').strip()
        if last_msg and last_msg != session.last_message:
            # Live preview only — see _handle_pre_tool_use comment above.
            # _handle_session_stop is the single writer for the assistant turn.
            session.last_message = last_msg

        # Resolve any pending permission that was waiting for this tool
        if session.pending_permission and session.pending_permission.tool == tool_name:
            fut = self._pending_permissions.pop(session.pending_permission.request_id, None)
            if fut and not fut.done():
                fut.set_result('executed')
            session.pending_permission = None

        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_user_prompt(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        session = self._registry.ensure(raw_id=raw_id)
        prompt = (msg.get('message', '') or '').strip()
        session.state = 'awaiting_user'
        session.preview = prompt[:200]
        session.last_prompt = prompt
        if prompt:
            self._fire_a2a(self.append_message(session.task_id, 'user', prompt))
        self._fire_a2a(self._set_task_status(session, 'working'))
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_session_stop(self, msg: dict):
        """Called at end of each assistant turn (not process exit). Transition to idle."""
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        sid = self._registry.resolve(raw_id=raw_id)
        if not sid:
            return
        session = self._registry.sessions[sid]
        last_msg = (msg.get('last_message', '') or '').strip()
        if last_msg and last_msg != session.last_message:
            session.last_message = last_msg
            self._fire_a2a(self.append_message(session.task_id, 'assistant', last_msg))
            self._fire_a2a(self._append_artifact_if_large(session, 'Final response', last_msg))
        # session_stop fires at end of every turn — keep the session alive so it
        # remains visible in the UI while Claude is waiting for the next user message.
        session.state = 'idle'
        session.current_tool = ''
        session.preview = ''
        _save_registry(self._registry)
        await self._emit_session_block(session)
        await self._emit_tile()
        _log(f'session_stop (turn end, staying idle) raw_id={raw_id[:8]}')

    async def _handle_post_compact(self, msg: dict):
        raw_id = msg.get('session_id', '')
        summary = (msg.get('summary', '') or '').strip()
        if not raw_id or not summary:
            return
        session = self._registry.ensure(raw_id=raw_id)
        self._fire_a2a(self._append_structured_message(session, 'Context compacted', summary))
        _log(f'post_compact raw_id={raw_id[:8]} summary={summary[:60]}')

    async def _handle_permission_request(self, msg: dict):
        """Surface a permission request on iPhone and return immediately.

        The hook has already exited — Claude Code shows its native terminal
        prompt. If the user responds on iPhone, _inject_permission_response
        injects the answer via tmux send-keys. If they respond in the terminal,
        Claude Code resolves natively and the TTY monitor clears the card.
        """
        mode = _load_permission_mode()
        preview = msg.get('preview', '')

        raw_id = msg.get('session_id', '')
        session = self._registry.ensure(
            raw_id=raw_id,
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
            project=os.path.basename((msg.get('cwd', '') or '').rstrip('/')) if msg.get('cwd') else '',
        )

        if mode == 'full-auto' or _is_allowlisted(preview):
            # Auto-approve: inject 'y\n' directly for tmux sessions
            if session.tmux_target:
                asyncio.create_task(self._inject_permission_response(session, 'Allow', ['Allow', 'Deny']))
            return

        options = list(msg.get('options', ['Allow', 'Deny']))
        suggestions = msg.get('suggestions', {})
        request = PendingPermission(
            request_id=f'perm:{uuid.uuid4().hex[:8]}',
            tool=msg.get('tool', 'Bash'),
            preview=preview,
            options=options,
            suggestions=suggestions,
            requested_at=datetime.datetime.now().timestamp(),
        )
        session.pending_permission = request
        session.state = 'waiting_permission'
        session.current_tool = request.tool
        session.preview = preview[:200]
        session.permission_mode = mode

        fut = asyncio.get_running_loop().create_future()
        self._pending_permissions[request.request_id] = fut

        self._fire_a2a(self._set_task_status(session, 'working'))
        self._fire_a2a(self._append_structured_message(
            session,
            'Permission needed',
            f'`{request.tool}` wants to run:\n\n```\n{preview}\n```',
        ))
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

        # Background: wait for iPhone response and inject it into the tmux pane
        asyncio.create_task(self._await_and_inject_permission(session, request, fut))

    async def _await_and_inject_permission(self, session: SessionRecord,
                                           request: PendingPermission, fut: asyncio.Future):
        """Wait for iPhone permission response and inject it into the terminal."""
        try:
            value = await asyncio.wait_for(fut, timeout=PERMISSION_TIMEOUT)
        except asyncio.TimeoutError:
            value = None
        finally:
            self._pending_permissions.pop(request.request_id, None)

        session.pending_permission = None

        if value is None:
            # Timeout — leave Claude Code to resolve natively (user at terminal)
            session.state = 'idle'
            await self._emit_session_block(session)
            return

        self._fire_a2a(self._append_structured_message(session, 'Permission resolved', value))
        session.state = 'running_tool' if value in ('Allow', 'Always Allow', 'executed') else 'idle'
        self._fire_a2a(self._set_task_status(session, 'working'))
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

        if value == 'Always Allow':
            _append_allowlist(request.preview)

        # Inject response into tmux pane so the native terminal prompt resolves
        if session.tmux_target and value not in ('executed',):
            await self._inject_permission_response(session, value, request.options)

    async def _inject_permission_response(self, session: SessionRecord,
                                          value: str, options: list):
        """Inject a permission response into the tmux pane to answer the native prompt."""
        if not session.tmux_target:
            return
        # Map to the keystrokes that satisfy Claude Code's numbered permission prompt
        if value in ('Allow', 'Yes'):
            text = 'y'
        elif value in ('Deny', 'No'):
            text = 'n'
        elif value in options:
            idx = options.index(value)
            text = str(idx + 1)
        else:
            text = 'y'
        try:
            await self._call_tool('send_text', {
                'session_id': session.raw_id,
                'text': text,
            }, timeout=5.0)
        except Exception as e:
            _log(f'inject_permission_response failed for {session.session_id}: {e}', 'WARN')

    # ------------------------------------------------------------------
    # TTY monitoring — interactive prompt detection
    # ------------------------------------------------------------------

    async def _monitor_tty_session(self, session_id: str):
        """Poll terminal-manager for terminal output and detect interactive prompts."""
        import hashlib as _hl
        last_hash = ''
        active_options: list = []

        await asyncio.sleep(2)

        while True:
            await asyncio.sleep(1)
            session = self._registry.sessions.get(session_id)
            if not session or session.state == 'stopped':
                break

            # Suppress detection while Claude is actively streaming
            if session.state in ('running_tool', 'awaiting_user'):
                if last_hash:
                    last_hash = ''
                    active_options = []
                    session.pending_confirmation_tty = None
                continue

            tui = await self._call_tool('detect_tui', {'session_id': session.raw_id})
            if not tui or tui.get('pattern_id') != 'interactive_prompt':
                if last_hash:
                    last_hash = ''
                    active_options = []
                    session.pending_permission = None
                    await self._emit_session_block(session)
                continue

            prompt_result = tui.get('result') or {}
            prompt_hash = _hl.md5(str(prompt_result).encode()).hexdigest()[:8]

            if prompt_hash == last_hash:
                continue  # same prompt still showing, already surfaced

            last_hash = prompt_hash
            ptype = prompt_result.get('type', 'numbered')
            if ptype == 'binary':
                options = ['Yes', 'No']
                reply_mode = 'yn'
                body = prompt_result.get('prompt_text', 'Continue?')
            else:
                options = prompt_result.get('options', [])
                reply_mode = ptype  # 'numbered' or 'arrow'
                body = 'Choose an option'
            active_options = options

            session.pending_permission = PendingPermission(
                request_id=f'tty:{uuid.uuid4().hex[:8]}',
                tool='Terminal prompt',
                preview=body,
                options=options,
                suggestions={},
                requested_at=datetime.datetime.now().timestamp(),
            )
            session.state = 'waiting_permission'
            fut = asyncio.get_running_loop().create_future()
            self._pending_permissions[session.pending_permission.request_id] = fut
            await self._emit_session_block(session)
            _log(f'TTY prompt surfaced for {session_id[:8]}: {body[:60]}')
            try:
                value = await asyncio.wait_for(fut, timeout=PERMISSION_TIMEOUT)
            except asyncio.TimeoutError:
                value = None
            finally:
                self._pending_permissions.pop(session.pending_permission.request_id, None)

            if value is not None and value in active_options and reply_mode in ('numbered', 'arrow'):
                idx = active_options.index(value)
                down_seq = '\x1b[B' * idx
                await self._tm_inject_tty(session, down_seq + '\n')
            elif value == 'Yes' and reply_mode == 'yn':
                await self._tm_inject_tty(session, 'y\n')
            elif value == 'No' and reply_mode == 'yn':
                await self._tm_inject_tty(session, 'n\n')

            last_hash = ''
            active_options = []
            session.pending_permission = None
            session.state = 'idle'
            await self._emit_session_block(session)

        self._tty_monitors.discard(session_id)

    # ------------------------------------------------------------------
    # Process discovery
    # ------------------------------------------------------------------

    async def _discover_active_processes(self):
        """Scan running processes and backfill TTY for hook-registered sessions
        that started before the daemon could capture their terminal.

        Matching priority:
        1. TTY alias — session is already fully tracked, nothing to do.
        2. CWD match — session exists but its TTY was never captured (hook
           failed to detect the terminal). Link the discovered TTY to that
           session so routing and liveness checks work.

        Unknown processes (no TTY or CWD match) are ignored — they will
        self-register via hook events when their next tool or prompt fires.
        """
        discovered = await self._call_tool('discover_sessions', {'executable': 'claude'})
        processes = (discovered or {}).get('sessions', [])
        for proc in processes:
            tty = proc['tty']
            cwd = proc.get('cwd', '')

            # 1. Already tracked by TTY?
            if self._registry.resolve(tty=tty):
                continue

            # 2. Match an existing session by CWD when TTY is missing.
            if cwd:
                sid = self._registry.resolve(cwd=cwd)
                if sid:
                    session = self._registry.sessions[sid]
                    if not session.tty:
                        # Backfill TTY so routing and liveness checks work.
                        session.tty = tty
                        self._registry._index_aliases(session)
                        _log(f'linked tty={tty} to session {sid} via cwd={cwd!r}')
                        # Register with terminal-manager immediately so the
                        # first send attempt succeeds without needing a retry.
                        asyncio.create_task(self._tm_register(session))
                    await self._emit_session_block(session)
                    continue

            # Unknown process — skip. Hook events will register it properly.
            _log(f'process discovery: skipping unmatched pid={proc["pid"]} tty={tty} cwd={cwd!r}')
        await self._emit_tile()

    # ------------------------------------------------------------------
    # Block response handler (called when user taps on iPhone/Mac)
    # ------------------------------------------------------------------

    async def _handle_block_response(self, block_id: str, value: str):
        _log(f'block response block_id={block_id!r} value={value[:80]!r}')

        if block_id == START_BLOCK_ID:
            # Explicit user opt-in to scan ~/Documents/code etc. Triggers the
            # one and only Documents-folder TCC prompt. After this returns,
            # _emit_start_session_block(scan=True) re-emits the block with the
            # found repos, and the cached list is reused on subsequent launches.
            if value == '__scan_repos__':
                asyncio.create_task(self._emit_start_session_block(scan=True))
                return
            choice = self._start_choices.get(value, {})
            repo_path = choice.get('repo_path', value)
            if repo_path:
                asyncio.create_task(self._launch_in_tmux(repo_path))
            return

        session = next(
            (s for s in self._registry.sessions.values()
             if self._session_block_id(s.session_id) == block_id),
            None,
        )
        if not session:
            return

        # Permission toggle
        if value == '__permissions__':
            next_mode = 'supervised' if _load_permission_mode() == 'full-auto' else 'full-auto'
            _save_permission_mode(next_mode)
            for s in self._registry.sessions.values():
                s.permission_mode = next_mode
                await self._emit_session_block(s)
            return

        # Interrupt
        if value == '__interrupt__':
            ok = await self._tm_send_interrupt(session)
            _log(f'interrupt session={session.session_id!r} ok={ok}')
            self._fire_a2a(self._append_structured_message(session, 'Interrupted', 'Sent Ctrl-C to the session.'))
            session.state = 'idle'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return

        # Migrate terminal session to tmux
        if value == '__migrate_to_tmux__':
            asyncio.create_task(self._do_migrate_to_tmux(session))
            return

        # Close session
        if value == '__close_session__':
            if session.tmux_target:
                # Interrupt any running tool first (works even mid-run), then quit
                try:
                    await self._call_tool('send_interrupt', {'target': session.tmux_target}, timeout=5.0)
                except Exception as e:
                    _log(f'send_interrupt for close failed: {e!r}', 'WARN')
                await asyncio.sleep(0.5)
                try:
                    await self._call_tool('send_text', {'target': session.tmux_target, 'text': '/quit'}, timeout=5.0)
                except Exception as e:
                    _log(f'send_text /quit for close failed: {e!r}', 'WARN')
            else:
                await self._tm_inject_tty(session, '/quit\n')
            self._fire_a2a(self._append_structured_message(session, 'Stop requested', 'Sent quit to Claude Code.'))
            session.state = 'stopping'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return

        # Pending permission response
        if session.pending_permission and value in session.pending_permission.options:
            fut = self._pending_permissions.get(session.pending_permission.request_id)
            if fut and not fut.done():
                fut.set_result(value)
            # For non-tmux sessions (TTY prompt), inject directly here
            elif session.tmux_target and session.pending_permission:
                asyncio.create_task(self._inject_permission_response(
                    session, value, session.pending_permission.options))
            return

        # Free-text reply
        if value:
            ok = await self._route_text(session, value)
            _log(f'reply session={session.session_id!r} ok={ok} text={value[:80]!r}')
            if ok:
                session.state = 'running_tool'
                session.preview = value[:200]
                self._fire_a2a(self._set_task_status(session, 'working'))
                await self._emit_session_block(session)
                _save_registry(self._registry)

    # ------------------------------------------------------------------
    # Tool handlers (called by iOS via tools/call)
    # ------------------------------------------------------------------

    async def _tool_start_session(self, args: dict) -> dict:
        repo_path = args.get('repo_path', '').strip()
        if repo_path:
            asyncio.create_task(self._launch_in_tmux(repo_path))
        else:
            await self._emit_start_session_block()
        return {'ok': True}

    async def _tool_reply(self, args: dict) -> dict:
        session_id = args.get('session_id', '')
        text = args.get('message', '').strip()
        session = self._registry.sessions.get(session_id)
        if not session or not text:
            return {'error': 'unknown session or empty message'}
        ok = await self._route_text(session, text)
        if not ok:
            return {'error': 'session is not routable'}
        session.state = 'running_tool'
        session.preview = text[:200]
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        _save_registry(self._registry)
        return {'ok': True}

    async def _tool_stop_session(self, args: dict) -> dict:
        session = self._registry.sessions.get(args.get('session_id', ''))
        if not session:
            return {'error': 'unknown session'}
        ok = await self._tm_send_interrupt(session)
        if not ok:
            return {'error': 'session is not routable'}
        await self._append_structured_message(session, 'Interrupted', 'Sent Ctrl-C to the session.')
        session.state = 'idle'
        await self._emit_session_block(session)
        _save_registry(self._registry)
        return {'ok': True}

    async def _do_migrate_to_tmux(self, session: SessionRecord):
        """Migrate a terminal-observed session into a tmux window."""
        if not session.raw_id:
            return
        try:
            result = await self._call_tool('migrate_to_tmux', {
                'session_id': session.raw_id,
                'session': 'ask',
                'window_name': session.project,
            }, timeout=20.0)
            if isinstance(result, dict) and result.get('tmux_target'):
                session.tmux_target = result['tmux_target']
                await self._tm_register(session)
                self._fire_a2a(self._append_structured_message(
                    session, 'Moved to tmux', f'Session now running in `{session.tmux_target}`.'))
                await self._emit_session_block(session)
                _save_registry(self._registry)
                _log(f'migrated {session.session_id} to tmux: {session.tmux_target}')
                self._ensure_mirror_task(session)
            else:
                _log(f'migrate_to_tmux returned unexpected result: {result}', 'WARN')
        except Exception as e:
            _log(f'migrate_to_tmux failed for {session.session_id}: {e}', 'WARN')

    async def _tool_migrate_to_tmux(self, args: dict) -> dict:
        session_id = args.get('session_id', '')
        session = self._registry.sessions.get(session_id)
        if not session:
            return {'error': 'unknown session'}
        await self._do_migrate_to_tmux(session)
        return {'ok': True, 'tmux_target': session.tmux_target}

    # ------------------------------------------------------------------
    # Heartbeat — session liveness and block refresh
    # ------------------------------------------------------------------

    async def _refresh_sessions(self):
        # Stale-no-routing GC: collect live `claude` process CWDs once per cycle
        # so we can evict sessions whose underlying process is gone but never
        # emitted a session_stop event (e.g. claude crashed, or the host app
        # spawned a one-off claude that exited before any hook fired).
        # Supervisor session (cwd='') is never matched here so it's preserved.
        live_cwds: set[str] = set()
        try:
            discovered = await self._call_tool('discover_sessions', {'executable': 'claude'}, timeout=4.0)
            for proc in (discovered or {}).get('sessions', []):
                if proc.get('cwd'):
                    live_cwds.add(proc['cwd'])
        except Exception as exc:
            _log(f'discover_sessions failed in refresh: {exc!r}', 'WARN')

        now = datetime.datetime.now().timestamp()
        NO_ROUTING_STALE_SECS = 600  # 10 min — give startup hooks a fair chance to register

        for session in list(self._registry.sessions.values()):
            if session.state == 'stopped':
                continue
            # Re-register with terminal-manager on each cycle (it loses state on restart)
            if session.raw_id and (session.tty or session.tmux_target):
                asyncio.create_task(self._tm_register(session))
            # For tmux sessions, check pane liveness
            if session.tmux_target:
                try:
                    result = await self._call_tool('pane_alive', {'target': session.tmux_target}, timeout=5.0)
                    if isinstance(result, dict) and not result.get('alive', True):
                        _log(f'tmux pane gone for {session.session_id} — marking stopped')
                        self._cancel_mirror_task(session.session_id)
                        session.state = 'stopped'
                        session.stopped_at = datetime.datetime.now().timestamp()
                        self._registry.remove(session.session_id)
                        try:
                            await self._append_structured_message(session, 'Session ended', 'tmux pane exited.')
                            await self._set_task_status(session, 'completed')
                            await self.clear_block(self._session_block_id(session.session_id))
                        except Exception as exc:
                            _log(f'tmux-gone cleanup error for {session.session_id}: {exc}', 'WARN')
                        continue
                except Exception:
                    pass
            # Sessions with no routing (no tty, no tmux_target) can't have their
            # liveness verified live, but they include the supervisor Claude Code
            # session that is the parent of this daemon — by design it has no
            # tmux/tty routing and goes idle indefinitely between user prompts.
            # Don't evict here; SESSION_TTL (24h) at registry-load filters out
            # genuinely abandoned no-routing sessions on the next daemon restart.
            # Only evict TTY sessions if the TTY is confirmed dead.
            if not session.tmux_target and session.tty:
                alive_result = await self._call_tool('session_alive', {'session_id': session.raw_id})
                tty_dead = not (alive_result or {}).get('alive', True)
            else:
                tty_dead = False
            # Stale no-routing GC: session has neither tty nor tmux and has been
            # idle past the threshold. Evict to stop the registry from growing
            # without bound when host apps (e.g. Agentic Engineering Manager)
            # spawn-and-exit claude rapidly, leaving zombie session records.
            #
            # The supervisor session — the parent claude that spawned this
            # daemon — also has no routing. If the user is actively using it
            # last_seen stays fresh and it survives this check. If the user
            # has been idle past the threshold, eviction is harmless: the next
            # hook event will recreate the record via _registry.ensure().
            #
            # Sessions with an unknown cwd (host app didn't propagate it) are
            # still eligible for GC — they're just as zombie as any other.
            no_routing_stale = (
                not session.tty
                and not session.tmux_target
                and (now - float(session.last_seen)) > NO_ROUTING_STALE_SECS
                and (not session.cwd or session.cwd not in live_cwds)
            )

            if not session.tmux_target and session.tty and tty_dead:
                _log(f'session {session.session_id} TTY gone — marking stopped')
                self._cancel_mirror_task(session.session_id)
                session.state = 'stopped'
                session.stopped_at = datetime.datetime.now().timestamp()
                self._registry.remove(session.session_id)
                try:
                    await self._append_structured_message(
                        session, 'Session ended', 'Terminal closed.')
                    await self._set_task_status(session, 'completed')
                    await self.clear_block(self._session_block_id(session.session_id))
                except Exception as exc:
                    _log(f'TTY-gone cleanup error for {session.session_id}: {exc!r}', 'WARN')
            elif no_routing_stale:
                idle_min = int((now - float(session.last_seen)) / 60)
                _log(f'session {session.session_id} no-routing + no live process for {idle_min}m at {session.cwd!r} — evicting')
                self._cancel_mirror_task(session.session_id)
                session.state = 'stopped'
                session.stopped_at = now
                self._registry.remove(session.session_id)
                try:
                    await self.clear_block(self._session_block_id(session.session_id))
                except Exception as exc:
                    _log(f'no-routing-stale cleanup error for {session.session_id}: {exc!r}', 'WARN')
            else:
                # On the first refresh after a daemon restart, reset all transient
                # working states — they can't be re-hydrated from saved state alone.
                if not self._post_restart_reset_done:
                    if session.state in ('running_tool', 'awaiting_user', 'starting'):
                        session.state = 'idle'
                        session.current_tool = ''
                        session.preview = ''
                await self._emit_session_block(session)
        self._post_restart_reset_done = True
        _save_registry(self._registry)
        await self._emit_tile()
        try:
            await self._emit_start_session_block()
        except Exception as exc:
            _log(f'start_session emit error: {exc!r}', 'WARN')

    async def _heartbeat(self):
        cycles = 0
        while True:
            await asyncio.sleep(15)
            cycles += 1
            try:
                # Every 4 cycles (~1 min), drop the emit dedup cache so any
                # block AskMac silently dropped (TTL prune, restart, etc.)
                # gets re-pushed on this refresh. Cheap insurance against the
                # "block disappeared from UI" symptom.
                if cycles % 4 == 0:
                    self._emitted_payloads.clear()
                await self._refresh_sessions()
            except Exception as exc:
                _log(f'heartbeat error: {exc!r}', 'WARN')

    # ------------------------------------------------------------------
    # Unix socket server (receives hook events)
    # ------------------------------------------------------------------

    async def _handle_socket_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=5.0)
            msg = json.loads(data.decode())
            msg_type = msg.get('type', '')
            _log(f"socket event type={msg_type!r} session={msg.get('session_id', '')[:12]!r}")

            if msg_type == 'session_start':
                await self._handle_session_start(msg)
            elif msg_type == 'pre_tool_use':
                await self._handle_pre_tool_use(msg)
            elif msg_type == 'tool_executed':
                await self._handle_tool_executed(msg)
            elif msg_type == 'user_prompt':
                await self._handle_user_prompt(msg)
            elif msg_type == 'session_stop':
                await self._handle_session_stop(msg)
            elif msg_type == 'post_compact':
                await self._handle_post_compact(msg)
            elif msg_type == 'permission_request':
                # Acknowledge immediately — hook exits, Claude Code shows native prompt.
                # iPhone card is surfaced in the background; response injected via tmux.
                writer.write(json.dumps({'value': ''}).encode())
                await writer.drain()
                if self._initialized:
                    asyncio.create_task(self._handle_permission_request(msg))
            elif msg_type == 'ui_respond':
                # Response from MockAskMac web UI (dev tool) — treat like iPhone response
                sid = msg.get('session_id', '')
                value = msg.get('value', '')
                session = self._registry.sessions.get(sid)
                if session:
                    block_id = self._session_block_id(sid)
                    await self._handle_block_response(block_id, value)
                else:
                    # sid may be a block_id directly (e.g. claude3-start for start_session)
                    await self._handle_block_response(sid, value)
                writer.write(json.dumps({'ok': True}).encode())
                await writer.drain()
        except Exception as exc:
            _log(f'socket client error: {exc!r}', 'WARN')
        finally:
            writer.close()

    async def _start_socket_server(self):
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
        server = await asyncio.start_unix_server(self._handle_socket_client, path=SOCKET_PATH)
        _log(f'Unix socket listening at {SOCKET_PATH}')
        return server

    # ------------------------------------------------------------------
    # MCP stdin/stdout RPC loop
    # ------------------------------------------------------------------

    async def _handle_rpc_line(self, line: str):
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return

        # Response to one of our outbound calls
        if 'result' in msg and 'id' in msg and msg['id'] in self._pending_calls:
            fut = self._pending_calls.pop(msg['id'])
            if not fut.done():
                fut.set_result(msg['result'])
            return

        method = msg.get('method', '')
        rpc_id = msg.get('id')

        if method == 'initialize':
            self._write({
                'jsonrpc': '2.0',
                'id': rpc_id,
                'result': {
                    'protocolVersion': '2024-11-05',
                    'capabilities': {'tools': {}},
                    'serverInfo': {'name': 'claude-3', 'version': '0.1.0'},
                },
            })
            return

        if method == 'notifications/initialized':
            self._initialized = True
            await self._emit_start_session_block()
            await self._refresh_sessions()
            return

        if method == 'tools/list':
            tools = [
                {
                    'name': 'start_session',
                    'description': 'Launch a new Claude Code session or show repo picker',
                    'inputSchema': {
                        'type': 'object',
                        'properties': {'repo_path': {'type': 'string'}},
                    },
                },
                {
                    'name': 'reply',
                    'description': 'Send a message to a live Claude Code session',
                    'inputSchema': {
                        'type': 'object',
                        'properties': {
                            'session_id': {'type': 'string'},
                            'message': {'type': 'string'},
                        },
                        'required': ['session_id', 'message'],
                    },
                },
                {
                    'name': 'stop_session',
                    'description': 'Interrupt a live Claude Code session',
                    'inputSchema': {
                        'type': 'object',
                        'properties': {'session_id': {'type': 'string'}},
                        'required': ['session_id'],
                    },
                },
                {
                    'name': 'migrate_to_tmux',
                    'description': 'Move a terminal-observed session into a tmux window for full control',
                    'inputSchema': {
                        'type': 'object',
                        'properties': {'session_id': {'type': 'string'}},
                        'required': ['session_id'],
                    },
                },
            ]
            self._write({'jsonrpc': '2.0', 'id': rpc_id, 'result': {'tools': tools}})
            return

        if method == 'tools/call':
            # Spawn as background task so _read_stdin immediately reads the next
            # line — critical because tool handlers call _rpc, whose responses
            # arrive via stdin and must not be blocked waiting for this handler.
            asyncio.create_task(self._dispatch_tool_call(rpc_id, msg.get('params', {})))
            return

        if method == 'notifications/message':
            # Same: block responses and chat messages call _rpc internally.
            asyncio.create_task(self._dispatch_notification(msg.get('params', {}).get('data', {})))

    async def _dispatch_tool_call(self, rpc_id, params: dict):
        name = params.get('name', '')
        args = params.get('arguments', {})
        if name == 'start_session':
            result = await self._tool_start_session(args)
        elif name == 'reply':
            result = await self._tool_reply(args)
        elif name == 'stop_session':
            result = await self._tool_stop_session(args)
        elif name == 'migrate_to_tmux':
            result = await self._tool_migrate_to_tmux(args)
        else:
            result = {'error': f'Unknown tool: {name}'}
        self._write({
            'jsonrpc': '2.0',
            'id': rpc_id,
            'result': {'content': [{'type': 'text', 'text': json.dumps(result)}]},
        })

    async def _dispatch_notification(self, data: dict):
        msg_type = data.get('type', '')
        if msg_type == 'user_response':
            await self._handle_block_response(data.get('blockId', ''), data.get('value', ''))
        elif msg_type == 'chat_message':
            await self._tool_reply({
                'session_id': data.get('sessionId', ''),
                'message': data.get('text', ''),
            })

    async def _read_stdin(self):
        loop = asyncio.get_running_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            # Don't await — _handle_rpc_line must return quickly for slow handlers
            # so this loop can immediately start reading the next line (e.g. _rpc
            # responses that arrive while a handler is running).
            asyncio.create_task(self._handle_rpc_line(line))

    # ------------------------------------------------------------------
    # Entry point
    # ------------------------------------------------------------------

    async def run(self):
        _log('claude-3 starting')
        _install_hooks()
        await self._start_socket_server()
        asyncio.create_task(self._heartbeat())
        stdin_task = asyncio.create_task(self._read_stdin())
        try:
            await self._rpc('initialize', {
                'protocolVersion': '2024-11-05',
                'capabilities': {'tools': {}},
                'clientInfo': {'name': 'claude-3', 'version': '0.1.0'},
            })
            self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            self._initialized = True
            _log('MCP initialized')
            await self._refresh_sessions()
            # Resume terminal-mirror loops for any tmux sessions that survived
            # the registry load. _ensure_mirror_task is a no-op when ASK_MIRROR
            # isn't set or the session isn't tmux-routed, so this is safe to
            # call indiscriminately.
            for s in list(self._registry.sessions.values()):
                if s.tmux_target and s.state != 'stopped':
                    self._ensure_mirror_task(s)
            # Do not block startup on these — they each fan out to filesystem
            # (find_repos walks Documents) or external tool calls. If anything
            # stalls (TCC, slow disk, terminal-manager startup), the event loop
            # gets starved and incoming socket events queue forever.
            asyncio.create_task(self._discover_active_processes())
            asyncio.create_task(self._emit_start_session_block())
            await stdin_task
        finally:
            if not stdin_task.done():
                stdin_task.cancel()


def _install_parent_watchdog():
    """Exit if our parent (AskMac) goes away. Without this, a force-quit of
    AskMac leaves the daemon reparented to launchd, retaining AskMac's TCC
    identity and triggering ghost prompts on Documents/etc. access."""
    import threading, time
    def _watch():
        while True:
            time.sleep(5)
            if os.getppid() == 1:
                _log('parent (AskMac) gone — exiting', 'WARN')
                os._exit(0)
    threading.Thread(target=_watch, daemon=True).start()


if __name__ == '__main__':
    _install_parent_watchdog()
    try:
        asyncio.run(Claude3().run())
    except KeyboardInterrupt:
        pass
