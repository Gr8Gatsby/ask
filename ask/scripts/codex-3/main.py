#!/usr/bin/env python3
import asyncio
import datetime
import json
import os
import sys
import tempfile
import uuid

from registry import PendingPermission, SessionRegistry
from transport import (
    TMUX,
    find_repos,
    get_pane_pid,
    launch_codex,
    pane_exists,
    send_interrupt,
    send_quit,
    send_text,
)

sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/codex-3.sock'))
LOG_PATH = os.path.expanduser('~/.ask/logs/codex-3.log')
SETTINGS_PATH = os.environ.get('ASK_CODEX3_SETTINGS_PATH', os.path.expanduser('~/.ask/codex3-settings.json'))
SESSIONS_PATH = os.environ.get('ASK_CODEX3_SESSIONS_PATH', os.path.expanduser('~/.ask/codex3-sessions.json'))
ALLOWLIST_PATH = os.environ.get('ASK_CODEX3_ALLOWLIST_PATH', os.path.expanduser('~/.ask/codex3-allowlist.json'))
PERMISSION_MODE_PATH = os.environ.get('ASK_CODEX3_PERMISSION_MODE_PATH', os.path.expanduser('~/.ask/codex3-permission-mode.json'))
CODEX_HOOKS_PATH = os.environ.get('ASK_CODEX3_HOOKS_PATH', os.path.expanduser('~/.codex/hooks.json'))
CODEX_CONFIG_PATH = os.path.expanduser('~/.codex/config.toml')

START_SESSION_BLOCK_ID = 'codex3-start'
TILE_BLOCK_ID = 'codex-3-tile'
SESSION_TTL = 3600


def _log(message: str, level: str = 'INFO'):
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [{level}] {message}"
    print(line, file=sys.stderr, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as handle:
            handle.write(line + '\n')
    except Exception:
        pass


def _load_json(path: str, fallback):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return fallback


def _save_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as handle:
        json.dump(data, handle, indent=2)


def _load_settings() -> dict:
    return _load_json(SETTINGS_PATH, {'interactive': True, 'recent_repos': []})


def _save_settings(settings: dict):
    _save_json(SETTINGS_PATH, settings)


def _load_permission_mode() -> str:
    raw = _load_json(PERMISSION_MODE_PATH, {'mode': 'supervised'})
    mode = raw.get('mode', 'supervised')
    return mode if mode in ('supervised', 'full-auto') else 'supervised'


def _save_permission_mode(mode: str):
    _save_json(PERMISSION_MODE_PATH, {'mode': mode})


def _append_allowlist(preview: str):
    if not preview:
        return
    data = _load_json(ALLOWLIST_PATH, {'patterns': []})
    patterns = data.setdefault('patterns', [])
    if preview not in patterns:
        patterns.append(preview)
        _save_json(ALLOWLIST_PATH, data)


def _load_registry() -> SessionRegistry:
    raw = _load_json(SESSIONS_PATH, {})
    now = datetime.datetime.now().timestamp()
    active = {
        sid: info for sid, info in raw.items()
        if (now - float(info.get('last_seen', now))) < SESSION_TTL and info.get('state') != 'stopped'
    }
    return SessionRegistry.from_dict(active)


def _save_registry(registry: SessionRegistry):
    _save_json(SESSIONS_PATH, registry.to_dict())


def _ensure_config_flag():
    try:
        content = open(CODEX_CONFIG_PATH).read() if os.path.exists(CODEX_CONFIG_PATH) else ''
    except Exception:
        content = ''
    if 'codex_hooks' not in content:
        os.makedirs(os.path.dirname(CODEX_CONFIG_PATH), exist_ok=True)
        with open(CODEX_CONFIG_PATH, 'a') as handle:
            handle.write('\n[features]\ncodex_hooks = true\n')


def _install_hooks():
    _ensure_config_flag()
    py = sys.executable
    hooks_dir = os.path.join(SCRIPT_DIR, 'hooks')
    our_hooks = {
        'SessionStart': [{'hooks': [{'type': 'command', 'command': f'{py} {os.path.join(hooks_dir, "session_start.py")}'}]}],
        'PreToolUse': [{'hooks': [{'type': 'command', 'command': f'{py} {os.path.join(hooks_dir, "pre_tool_use.py")}'}]}],
        'PostToolUse': [{'hooks': [{'type': 'command', 'command': f'{py} {os.path.join(hooks_dir, "post_tool_use.py")}'}]}],
        'Stop': [{'hooks': [{'type': 'command', 'command': f'{py} {os.path.join(hooks_dir, "session_stop.py")}'}]}],
        'UserPromptSubmit': [{'hooks': [{'type': 'command', 'command': f'{py} {os.path.join(hooks_dir, "user_prompt_submit.py")}'}]}],
    }
    existing = _load_json(CODEX_HOOKS_PATH, {}).get('hooks', {})
    merged = dict(existing)
    for event, hook_list in our_hooks.items():
        our_cmd = hook_list[0]['hooks'][0]['command']
        current = existing.get(event, [])
        already = any(
            hook.get('command') == our_cmd
            for entry in current
            for hook in entry.get('hooks', [])
        )
        if not already:
            merged[event] = hook_list + current
    os.makedirs(os.path.dirname(CODEX_HOOKS_PATH), exist_ok=True)
    with open(CODEX_HOOKS_PATH, 'w') as handle:
        json.dump({'hooks': merged}, handle, indent=2)


class Codex3:
    def __init__(self):
        self._next_id = 0
        self._pending_calls = {}
        self._registry = _load_registry()
        self._settings = _load_settings()
        self._pending_permission_futures: dict[str, asyncio.Future] = {}
        self._start_repos: dict[str, str] = {}
        self._initialized = False

    def _id(self):
        self._next_id += 1
        return self._next_id

    def _write(self, obj: dict):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    async def _rpc(self, method: str, params: dict = None):
        rpc_id = self._id()
        fut = asyncio.get_running_loop().create_future()
        self._pending_calls[rpc_id] = fut
        msg = {'jsonrpc': '2.0', 'id': rpc_id, 'method': method}
        if params:
            msg['params'] = params
        self._write(msg)
        return await asyncio.wait_for(fut, timeout=15.0)

    async def _call_tool(self, name: str, arguments: dict = None):
        result = await self._rpc('tools/call', {'name': name, 'arguments': arguments or {}})
        if isinstance(result, dict) and 'content' not in result:
            return result
        try:
            return json.loads(result['content'][0]['text'])
        except Exception:
            return result

    async def emit_block(self, block_id: str, block_type: str, payload: dict, ttl: int = None, inbox: bool = False):
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

    async def put_artifact(self, task_id: str, artifact_id: str, filename: str, mime_type: str, description: str, file_path: str):
        await self._call_tool('put_artifact', {
            'taskId': task_id,
            'artifactId': artifact_id,
            'filename': filename,
            'mimeType': mime_type,
            'description': description,
            'filePath': file_path,
        })

    def _session_block_id(self, session_id: str) -> str:
        return f'codex3-session-{session_id.split(":")[-1]}'

    async def _emit_tile(self):
        states = [s.state for s in self._registry.sessions.values() if s.state != 'stopped']
        label = 'No sessions'
        color = 'blue'
        if states:
            if any(state == 'waiting_permission' for state in states):
                label = 'Permission needed'
                color = 'orange'
            elif any(state in ('running_tool', 'awaiting_user', 'starting') for state in states):
                label = 'Working'
                color = 'blue'
            else:
                label = f'{len(states)} session{"s" if len(states) != 1 else ""}'
                color = 'gray'
        await self.emit_block(TILE_BLOCK_ID, 'tile', {
            'label': label,
            'status_color': color,
            'action_required': label == 'Permission needed',
        }, ttl=600)

    async def _emit_start_session_block(self):
        repos = find_repos()
        recent = self._settings.get('recent_repos', [])
        repos.sort(key=lambda item: recent.index(item[1]) if item[1] in recent else len(recent))
        self._start_repos = {name: path for name, path in repos}
        payload = {'repos': [{'name': name, 'path': path} for name, path in repos] or [{'name': '(no repos found)', 'path': ''}]}
        await self.emit_block(START_SESSION_BLOCK_ID, 'start_session', payload, ttl=600)

    async def _set_task_status(self, session, status: str):
        title = f'Codex · {session.project}'
        await self.open_task(session.task_id, title, status)

    async def _append_structured_message(self, session, kind: str, body: str, role: str = 'assistant'):
        if not body:
            return
        text = f'### {kind}\n{body}'
        await self.append_message(session.task_id, role, text)

    async def _append_output_artifact_if_large(self, session, title: str, text: str):
        if len(text) < 1600:
            return
        fd, path = tempfile.mkstemp(prefix='codex3-', suffix='.md')
        os.close(fd)
        with open(path, 'w') as handle:
            handle.write(text)
        await self.put_artifact(
            session.task_id,
            f'artifact-{uuid.uuid4().hex[:8]}',
            f'{session.project}-{title.lower().replace(" ", "-")}.md',
            'text/markdown',
            title,
            path,
        )

    async def _emit_session_block(self, session):
        payload = {
            'session_id': session.session_id,
            'project': session.project,
            'cwd': session.cwd,
            'is_working': session.state in ('starting', 'awaiting_user', 'running_tool', 'waiting_permission'),
            'is_headless': session.is_headless,
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
                'options': session.pending_permission.options,
            }
        await self.emit_block(self._session_block_id(session.session_id), 'agent_session', payload, ttl=SESSION_TTL)

    async def _refresh_sessions(self):
        for session in list(self._registry.sessions.values()):
            if session.tmux_target and pane_exists(session.tmux_target):
                await self._emit_session_block(session)
            elif session.state != 'stopped':
                session.state = 'stopped'
                session.stopped_at = datetime.datetime.now().timestamp()
                await self._set_task_status(session, 'completed')
                await self._append_structured_message(session, 'Session stopped', 'The tmux pane closed.')
                await self.clear_block(self._session_block_id(session.session_id))
                self._registry.remove(session.session_id)
        _save_registry(self._registry)
        await self._emit_tile()

    async def _heartbeat(self):
        while True:
            await asyncio.sleep(15)
            try:
                await self._refresh_sessions()
            except Exception as exc:
                _log(f'heartbeat error: {exc}', 'WARN')

    async def _handle_session_active(self, msg: dict):
        cwd = msg.get('cwd', '')
        project = os.path.basename(cwd.rstrip('/')) if cwd else ''
        session = self._registry.ensure(
            raw_id=msg.get('session_id', ''),
            tmux_target=msg.get('tmux_target', ''),
            tty=msg.get('tty', '') or '',
            cwd=cwd,
            project=project,
        )
        session.is_headless = session.is_headless or False
        session.permission_mode = _load_permission_mode()
        if msg.get('last_message'):
            session.last_message = msg['last_message']
        if msg.get('is_working') is False:
            session.state = 'idle'
            session.current_tool = ''
            session.preview = ''
        elif session.state == 'starting':
            session.state = 'idle'
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_user_prompt(self, msg: dict):
        session = self._registry.ensure(
            raw_id=msg.get('session_id', ''),
            tmux_target=msg.get('tmux_target', ''),
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
            project=os.path.basename((msg.get('cwd', '') or '').rstrip('/')) if msg.get('cwd') else '',
        )
        prompt = (msg.get('prompt', '') or '').strip()
        session.state = 'awaiting_user'
        session.preview = prompt[:200]
        session.last_prompt = prompt
        await self._set_task_status(session, 'working')
        if prompt:
            await self.append_message(session.task_id, 'user', prompt)
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_tool_executed(self, msg: dict):
        session = self._registry.ensure(
            raw_id=msg.get('session_id', ''),
            tmux_target=msg.get('tmux_target', ''),
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
        )
        session.current_tool = msg.get('tool_name', '')
        session.state = 'running_tool'
        last_message = (msg.get('last_message') or '').strip()
        if last_message and last_message != session.last_message:
            session.last_message = last_message
            await self.append_message(session.task_id, 'assistant', last_message)
            await self._append_output_artifact_if_large(session, 'Assistant output', last_message)
        if session.pending_permission and session.pending_permission.tool == session.current_tool:
            fut = self._pending_permission_futures.pop(session.pending_permission.request_id, None)
            if fut and not fut.done():
                fut.set_result('executed')
            session.pending_permission = None
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_session_idle(self, msg: dict):
        session = self._registry.ensure(
            raw_id=msg.get('session_id', ''),
            tmux_target=msg.get('tmux_target', ''),
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
        )
        session.state = 'idle'
        session.current_tool = ''
        session.preview = ''
        last_message = (msg.get('last_message') or '').strip()
        if last_message and last_message != session.last_message:
            session.last_message = last_message
            await self.append_message(session.task_id, 'assistant', last_message)
            await self._append_output_artifact_if_large(session, 'Assistant output', last_message)
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _handle_permission_request(self, msg: dict) -> str:
        mode = _load_permission_mode()
        if mode == 'full-auto':
            return 'Allow'

        session = self._registry.ensure(
            raw_id=msg.get('session_id', ''),
            tmux_target=msg.get('tmux_target', ''),
            tty=msg.get('tty', '') or '',
            cwd=msg.get('cwd', ''),
            project=os.path.basename((msg.get('cwd', '') or '').rstrip('/')) if msg.get('cwd') else '',
        )
        request = PendingPermission(
            request_id=f'perm:{uuid.uuid4().hex[:8]}',
            tool=msg.get('tool', 'Bash'),
            preview=msg.get('preview', ''),
            options=list(msg.get('options', ['Allow', 'Deny'])),
            requested_at=datetime.datetime.now().timestamp(),
        )
        session.pending_permission = request
        session.state = 'waiting_permission'
        session.current_tool = request.tool
        session.preview = request.preview[:200]
        session.permission_mode = mode
        fut = asyncio.get_running_loop().create_future()
        self._pending_permission_futures[request.request_id] = fut

        await self._set_task_status(session, 'working')
        await self._append_structured_message(
            session,
            'Permission needed',
            f'`{request.tool}` wants to run:\n\n```\n{request.preview}\n```',
        )
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)
        try:
            value = await asyncio.wait_for(fut, timeout=180.0)
        except asyncio.TimeoutError:
            value = 'Deny'
        finally:
            self._pending_permission_futures.pop(request.request_id, None)

        await self._append_structured_message(session, 'Permission resolved', value)
        session.pending_permission = None
        session.state = 'running_tool' if value in ('Allow', 'Always Allow', 'executed') else 'idle'
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)
        if value == 'Always Allow':
            _append_allowlist(request.preview)
        return value

    async def _launch(self, repo_path: str):
        info = launch_codex(repo_path, SOCKET_PATH, _install_hooks, interactive=self._settings.get('interactive', True))
        self._settings['recent_repos'] = [repo_path] + [p for p in self._settings.get('recent_repos', []) if p != repo_path]
        self._settings['recent_repos'] = self._settings['recent_repos'][:5]
        _save_settings(self._settings)
        session = self._registry.ensure(raw_id=info['tmux_target'], tmux_target=info['tmux_target'], cwd=info['cwd'], project=info['project'])
        session.tmux_target = info['tmux_target']
        session.is_headless = info['is_headless']
        session.state = 'starting'
        await self._set_task_status(session, 'working')
        await self._append_structured_message(session, 'Session started', f'Launched Codex in `{session.project}`.')
        await self.clear_block(START_SESSION_BLOCK_ID)
        await self._emit_session_block(session)
        await self._emit_tile()
        _save_registry(self._registry)

    async def _tool_start_session(self, args: dict) -> dict:
        repo_path = args.get('repo_path', '')
        if repo_path:
            asyncio.create_task(self._launch(repo_path))
        else:
            await self._emit_start_session_block()
        return {'ok': True}

    async def _tool_reply(self, args: dict) -> dict:
        session_id = args.get('session_id', '')
        session = self._registry.sessions.get(session_id)
        text = args.get('message', '').strip()
        if not session or not text:
            return {'error': 'unknown session'}
        ok = send_text(session.tmux_target, text)
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
        ok = send_interrupt(session.tmux_target)
        if not ok:
            return {'error': 'session is not routable'}
        await self._append_structured_message(session, 'Interrupted', 'Sent Ctrl-C to the session.')
        session.state = 'idle'
        await self._set_task_status(session, 'working')
        await self._emit_session_block(session)
        _save_registry(self._registry)
        return {'ok': True}

    async def _handle_block_response(self, block_id: str, value: str):
        if block_id == START_SESSION_BLOCK_ID:
            repo_path = self._start_repos.get(value, value)
            if repo_path:
                asyncio.create_task(self._launch(repo_path))
            return

        session = next((s for s in self._registry.sessions.values() if self._session_block_id(s.session_id) == block_id), None)
        if not session:
            return

        if value == '__permissions__':
            next_mode = 'supervised' if _load_permission_mode() == 'full-auto' else 'full-auto'
            _save_permission_mode(next_mode)
            for current in self._registry.sessions.values():
                current.permission_mode = next_mode
                await self._emit_session_block(current)
            return
        if value == '__interrupt__':
            send_interrupt(session.tmux_target)
            await self._append_structured_message(session, 'Interrupted', 'Sent Ctrl-C to the session.')
            session.state = 'idle'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return
        if value == '__close_session__':
            send_quit(session.tmux_target)
            await self._append_structured_message(session, 'Stop requested', 'Sent quit sequence to Codex.')
            session.state = 'stopping'
            await self._emit_session_block(session)
            _save_registry(self._registry)
            return
        if session.pending_permission and value in session.pending_permission.options:
            fut = self._pending_permission_futures.get(session.pending_permission.request_id)
            if fut and not fut.done():
                fut.set_result(value)
            return
        if value:
            ok = send_text(session.tmux_target, value)
            if ok:
                await self.append_message(session.task_id, 'user', value)
                session.state = 'running_tool'
                session.preview = value[:200]
                await self._set_task_status(session, 'working')
                await self._emit_session_block(session)
                _save_registry(self._registry)

    async def _handle_socket_client(self, reader, writer):
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=5.0)
            msg = json.loads(data.decode())
            msg_type = msg.get('type', '')
            _log(f"socket event type={msg_type!r} session={msg.get('session_id', '')[:12]!r}")
            if msg_type == 'session_active':
                await self._handle_session_active(msg)
            elif msg_type == 'user_prompt_submit':
                await self._handle_user_prompt(msg)
            elif msg_type == 'tool_executed':
                await self._handle_tool_executed(msg)
            elif msg_type == 'session_idle':
                await self._handle_session_idle(msg)
            elif msg_type == 'permission_request':
                value = await self._handle_permission_request(msg)
                writer.write(json.dumps({'value': value}).encode())
                await writer.drain()
        except Exception as exc:
            _log(f'socket error: {exc}', 'WARN')
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

    async def _handle_rpc_line(self, line: str):
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return
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
                    'serverInfo': {'name': 'codex-3', 'version': '0.1.0'},
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
                {'name': 'start_session', 'description': 'Launch a Codex session', 'inputSchema': {'type': 'object', 'properties': {'repo_path': {'type': 'string'}}}},
                {'name': 'reply', 'description': 'Send a message to a live session', 'inputSchema': {'type': 'object', 'properties': {'session_id': {'type': 'string'}, 'message': {'type': 'string'}}, 'required': ['session_id', 'message']}},
                {'name': 'stop_session', 'description': 'Interrupt a live session', 'inputSchema': {'type': 'object', 'properties': {'session_id': {'type': 'string'}}, 'required': ['session_id']}},
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
            self._write({'jsonrpc': '2.0', 'id': rpc_id, 'result': {'content': [{'type': 'text', 'text': json.dumps(result)}]}})
            return
        if method == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            msg_type = data.get('type', '')
            if msg_type == 'user_response':
                await self._handle_block_response(data.get('blockId', ''), data.get('value', ''))
            elif msg_type == 'chat_message':
                await self._tool_reply({'session_id': data.get('sessionId', ''), 'message': data.get('text', '')})

    async def _read_stdin(self):
        loop = asyncio.get_running_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            await self._handle_rpc_line(line)

    async def run(self):
        _log('codex-3 starting')
        _install_hooks()
        await self._start_socket_server()
        asyncio.create_task(self._heartbeat())
        stdin_task = asyncio.create_task(self._read_stdin())
        try:
            await self._rpc('initialize', {
                'protocolVersion': '2024-11-05',
                'capabilities': {'tools': {}},
                'clientInfo': {'name': 'codex-3', 'version': '0.1.0'},
            })
            self._write({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            self._initialized = True
            _log('MCP initialized')
            await self._emit_start_session_block()
            await self._refresh_sessions()
            await stdin_task
        finally:
            if not stdin_task.done():
                stdin_task.cancel()


if __name__ == '__main__':
    try:
        asyncio.run(Codex3().run())
    except KeyboardInterrupt:
        pass
