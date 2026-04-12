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
import sys
import tempfile
import uuid

from registry import PendingPermission, SessionRecord, SessionRegistry
from transport import discover_claude_processes, find_repos, parse_tmux_prompt, tty_is_live

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
        self._initialized = False

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

    async def _call_tool(self, name: str, arguments: dict = None):
        result = await self._rpc('tools/call', {'name': name, 'arguments': arguments or {}})
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
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._call_tool('emit_block', args)

    async def clear_block(self, block_id: str):
        await self._call_tool('clear_block', {'blockId': block_id})

    async def open_task(self, task_id: str, title: str, status: str):
        await self._call_tool('open_task', {'taskId': task_id, 'title': title, 'status': status})

    async def append_message(self, task_id: str, role: str, text: str):
        await self._call_tool('append_message', {
            'taskId': task_id,
            'role': role,
            'parts': [{'type': 'text', 'text': text}],
        })

    async def put_artifact(self, task_id: str, artifact_id: str, filename: str,
                           mime_type: str, description: str, file_path: str):
        await self._call_tool('put_artifact', {
            'taskId': task_id,
            'artifactId': artifact_id,
            'filename': filename,
            'mimeType': mime_type,
            'description': description,
            'filePath': file_path,
        })

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
        if not states:
            label, color = 'No sessions', 'blue'
        elif any(s == 'waiting_permission' for s in states):
            label, color = 'Permission needed', 'orange'
        elif any(s in ('running_tool', 'awaiting_user', 'starting') for s in states):
            label, color = 'Working', 'blue'
        else:
            n = len(states)
            label, color = f'{n} session{"s" if n != 1 else ""}', 'gray'
        await self.emit_block(TILE_BLOCK_ID, 'tile', {
            'label': label,
            'status_color': color,
            'action_required': label == 'Permission needed',
        }, ttl=600)

    async def _emit_start_session_block(self):
        choices = []
        self._start_choices = {}
        repos = find_repos()
        settings_path = os.path.expanduser('~/.ask/claude3-settings.json')
        settings = _load_json(settings_path, {'recent_repos': []})
        recent = settings.get('recent_repos', [])
        repos.sort(key=lambda item: recent.index(item[1]) if item[1] in recent else len(recent))
        for name, path in repos:
            self._start_choices[path] = {'repo_path': path}
            choices.append({'name': name, 'path': path, 'value': path})
        payload = {'repos': choices or [{'name': '(no repos found)', 'path': '', 'value': ''}]}
        await self.emit_block(START_BLOCK_ID, 'start_session', payload, ttl=600)

    async def _emit_session_block(self, session: SessionRecord):
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
            'permission_mode': _load_permission_mode(),
            'tty': session.tty,
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
    # Terminal-manager routing
    # ------------------------------------------------------------------

    async def _tm_inject_tty(self, session: SessionRecord, text: str) -> bool:
        if not session.raw_id:
            return False
        try:
            await self._rpc('tools/call', {
                'name': 'inject_tty',
                'arguments': {'session_id': session.raw_id, 'text': text},
            }, timeout=5.0)
            return True
        except Exception as e:
            _log(f'inject_tty failed for {session.session_id}: {e}', 'WARN')
            return False

    async def _tm_send_text(self, session: SessionRecord, text: str) -> bool:
        if not session.raw_id:
            return False
        try:
            await self._rpc('tools/call', {
                'name': 'send_text',
                'arguments': {'session_id': session.raw_id, 'text': text},
            }, timeout=5.0)
            return True
        except Exception as e:
            _log(f'send_text failed for {session.session_id}: {e}', 'WARN')
            return False

    async def _tm_send_interrupt(self, session: SessionRecord) -> bool:
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
        if not session.raw_id or not session.tty:
            return
        try:
            await self._rpc('tools/call', {
                'name': 'register_session',
                'arguments': {
                    'session_id': session.raw_id,
                    'app_id': 'claude-3',
                    'tty': session.tty,
                    'tmux_target': '',
                },
            }, timeout=4.0)
            _log(f'tm_register {session.session_id[:12]} tty={session.tty!r}')
        except Exception as e:
            _log(f'tm_register failed: {e}', 'WARN')

    async def _route_text(self, session: SessionRecord, text: str) -> bool:
        """Send user text to a session. Try inject_tty first, fall back to send_text."""
        text_with_newline = text if text.endswith('\n') else text + '\n'
        ok = await self._tm_inject_tty(session, text_with_newline)
        if not ok:
            # If TTY is still unknown, try to discover it now from the process list.
            if not session.tty and session.cwd:
                for proc in discover_claude_processes():
                    if proc.get('cwd') == session.cwd and proc.get('tty'):
                        session.tty = proc['tty']
                        self._registry._index_aliases(session)
                        _log(f'late-discovered tty={session.tty!r} for session {session.session_id}')
                        break
            # Re-register and retry once
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
        await self._set_task_status(session, 'working')
        await self._append_structured_message(session, 'Session started', f'Launched in `{session.project}`.')
        await self._tm_register(session)
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)
        _log(f'session_start raw_id={raw_id[:8]} tty={tty} project={project}')

        # Start TTY monitor for interactive prompt detection
        if session.session_id not in self._tty_monitors:
            self._tty_monitors.add(session.session_id)
            asyncio.create_task(self._monitor_tty_session(session.session_id))

    async def _handle_pre_tool_use(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        session = self._registry.ensure(raw_id=raw_id, cwd=msg.get('cwd', ''))
        session.current_tool = msg.get('tool', '')
        session.preview = msg.get('preview', '')[:200]
        session.state = 'running_tool'

        last_msg = (msg.get('last_message', '') or '').strip()
        if last_msg and last_msg != session.last_message:
            session.last_message = last_msg
            await self.append_message(session.task_id, 'assistant', last_msg)
            await self._append_artifact_if_large(session, 'Assistant output', last_msg)

        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_tool_executed(self, msg: dict):
        raw_id = msg.get('session_id', '')
        if not raw_id:
            return
        session = self._registry.ensure(raw_id=raw_id, cwd=msg.get('cwd', ''))
        tool_name = msg.get('tool_name', '')
        session.current_tool = tool_name
        session.state = 'running_tool'

        last_msg = (msg.get('last_message', '') or '').strip()
        if last_msg and last_msg != session.last_message:
            session.last_message = last_msg
            await self.append_message(session.task_id, 'assistant', last_msg)
            await self._append_artifact_if_large(session, 'Assistant output', last_msg)

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
        session = self._registry.ensure(raw_id=raw_id, cwd=msg.get('cwd', ''))
        prompt = (msg.get('message', '') or '').strip()
        session.state = 'awaiting_user'
        session.preview = prompt[:200]
        session.last_prompt = prompt
        if prompt:
            await self.append_message(session.task_id, 'user', prompt)
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_session_stop(self, msg: dict):
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
            await self.append_message(session.task_id, 'assistant', last_msg)
            await self._append_artifact_if_large(session, 'Final response', last_msg)
        await self._append_structured_message(session, 'Session stopped', f'Claude Code exited in `{session.project}`.')
        session.state = 'stopped'
        session.stopped_at = datetime.datetime.now().timestamp()
        await self._set_task_status(session, 'completed')
        await self.clear_block(self._session_block_id(session.session_id))
        self._registry.remove(session.session_id)
        _save_registry(self._registry)
        await self._emit_tile()
        _log(f'session_stop raw_id={raw_id[:8]}')

    async def _handle_post_compact(self, msg: dict):
        raw_id = msg.get('session_id', '')
        summary = (msg.get('summary', '') or '').strip()
        if not raw_id or not summary:
            return
        session = self._registry.ensure(raw_id=raw_id, cwd=msg.get('cwd', ''))
        await self._append_structured_message(session, 'Context compacted', summary)
        _log(f'post_compact raw_id={raw_id[:8]} summary={summary[:60]}')

    async def _handle_permission_request(self, msg: dict) -> str:
        mode = _load_permission_mode()
        preview = msg.get('preview', '')

        if mode == 'full-auto':
            return 'Allow'
        if _is_allowlisted(preview):
            return 'Allow'

        raw_id = msg.get('session_id', '')
        session = self._registry.ensure(
            raw_id=raw_id,
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
            project=os.path.basename((msg.get('cwd', '') or '').rstrip('/')) if msg.get('cwd') else '',
        )
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

        await self._set_task_status(session, 'working')
        await self._append_structured_message(
            session,
            'Permission needed',
            f'`{request.tool}` wants to run:\n\n```\n{preview}\n```',
        )
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

        try:
            value = await asyncio.wait_for(fut, timeout=PERMISSION_TIMEOUT)
        except asyncio.TimeoutError:
            value = 'Deny'
        finally:
            self._pending_permissions.pop(request.request_id, None)

        await self._append_structured_message(session, 'Permission resolved', value)
        session.pending_permission = None
        session.state = 'running_tool' if value in ('Allow', 'Always Allow', 'executed') else 'idle'
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

        if value == 'Always Allow':
            _append_allowlist(preview)

        return value

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

            content = await self._tm_read_output(session, lines=40)
            if not content:
                continue

            parsed = parse_tmux_prompt(content)
            content_hash = _hl.md5(content.encode()).hexdigest()[:8]

            if parsed:
                if content_hash != last_hash:
                    last_hash = content_hash
                    body, options, reply_mode = parsed
                    active_options = options
                    # Embed as pending_confirmation in the session block
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
            else:
                if last_hash:
                    last_hash = ''
                    active_options = []
                    session.pending_permission = None
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
        processes = discover_claude_processes()
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
            choice = self._start_choices.get(value, {})
            repo_path = choice.get('repo_path', value)
            if repo_path:
                asyncio.create_task(self._launch(repo_path))
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
            await self._append_structured_message(session, 'Interrupted', 'Sent Ctrl-C to the session.')
            session.state = 'idle'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return

        # Close session
        if value == '__close_session__':
            await self._tm_inject_tty(session, '/quit\n')
            await self._append_structured_message(session, 'Stop requested', 'Sent quit to Claude Code.')
            session.state = 'stopping'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return

        # Pending permission response
        if session.pending_permission and value in session.pending_permission.options:
            fut = self._pending_permissions.get(session.pending_permission.request_id)
            if fut and not fut.done():
                fut.set_result(value)
            return

        # Free-text reply
        if value:
            ok = await self._route_text(session, value)
            _log(f'reply session={session.session_id!r} ok={ok} text={value[:80]!r}')
            if ok:
                await self.append_message(session.task_id, 'user', value)
                session.state = 'running_tool'
                session.preview = value[:200]
                await self._set_task_status(session, 'working')
                await self._emit_session_block(session)
                _save_registry(self._registry)

    # ------------------------------------------------------------------
    # Tool handlers (called by iOS via tools/call)
    # ------------------------------------------------------------------

    async def _tool_start_session(self, args: dict) -> dict:
        repo_path = args.get('repo_path', '').strip()
        if repo_path:
            asyncio.create_task(self._launch(repo_path))
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
        await self.append_message(session.task_id, 'user', text)
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

    # ------------------------------------------------------------------
    # Heartbeat — session liveness and block refresh
    # ------------------------------------------------------------------

    async def _refresh_sessions(self):
        for session in list(self._registry.sessions.values()):
            if session.state == 'stopped':
                continue
            # Re-register with terminal-manager on each cycle (it loses state on restart)
            if session.raw_id and session.tty:
                asyncio.create_task(self._tm_register(session))
            # Only evict if we have a known TTY and it is confirmed dead.
            # An empty TTY means we haven't resolved routing yet — keep the session alive.
            if session.tty and not tty_is_live(session.tty):
                _log(f'session {session.session_id} TTY gone — marking stopped')
                await self._append_structured_message(
                    session, 'Session ended', 'Terminal closed.')
                session.state = 'stopped'
                session.stopped_at = datetime.datetime.now().timestamp()
                await self._set_task_status(session, 'completed')
                await self.clear_block(self._session_block_id(session.session_id))
                self._registry.remove(session.session_id)
            else:
                # Reset transient working states on refresh so sessions don't get
                # stuck showing "Running Tool" after a daemon restart.
                if session.state in ('running_tool', 'awaiting_user') and not session.tty:
                    session.state = 'idle'
                    session.current_tool = ''
                    session.preview = ''
                await self._emit_session_block(session)
        _save_registry(self._registry)
        await self._emit_tile()

    async def _heartbeat(self):
        while True:
            await asyncio.sleep(15)
            try:
                await self._refresh_sessions()
            except Exception as exc:
                _log(f'heartbeat error: {exc}', 'WARN')

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
                if not self._initialized:
                    writer.write(json.dumps({'value': ''}).encode())
                    await writer.drain()
                    return
                value = await self._handle_permission_request(msg)
                writer.write(json.dumps({'value': value}).encode())
                await writer.drain()
        except Exception as exc:
            _log(f'socket client error: {exc}', 'WARN')
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
            ]
            self._write({'jsonrpc': '2.0', 'id': rpc_id, 'result': {'tools': tools}})
            return

        if method == 'tools/call':
            params = msg.get('params', {})
            name = params.get('name', '')
            args = params.get('arguments', {})
            if name == 'start_session':
                result = await self._tool_start_session(args)
            elif name == 'reply':
                result = await self._tool_reply(args)
            elif name == 'stop_session':
                result = await self._tool_stop_session(args)
            else:
                result = {'error': f'Unknown tool: {name}'}
            self._write({
                'jsonrpc': '2.0',
                'id': rpc_id,
                'result': {'content': [{'type': 'text', 'text': json.dumps(result)}]},
            })
            return

        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
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
            await self._handle_rpc_line(line)

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
            await self._emit_start_session_block()
            await self._refresh_sessions()
            await self._discover_active_processes()
            await stdin_task
        finally:
            if not stdin_task.done():
                stdin_task.cancel()


if __name__ == '__main__':
    try:
        asyncio.run(Claude3().run())
    except KeyboardInterrupt:
        pass
