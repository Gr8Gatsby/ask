#!/usr/bin/env python3
import dataclasses
import hashlib
import time
from typing import Optional


@dataclasses.dataclass
class PendingPermission:
    request_id: str
    tool: str
    preview: str
    options: list[str]
    requested_at: float

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, raw: Optional[dict]):
        if not raw:
            return None
        return cls(
            request_id=raw.get('request_id', ''),
            tool=raw.get('tool', 'Bash'),
            preview=raw.get('preview', ''),
            options=list(raw.get('options', ['Allow', 'Deny'])),
            requested_at=float(raw.get('requested_at', time.time())),
        )


@dataclasses.dataclass
class SessionRecord:
    session_id: str
    task_id: str
    project: str
    cwd: str = ''
    raw_id: str = ''
    tmux_target: str = ''
    tty: str = ''
    state: str = 'starting'
    current_tool: str = ''
    preview: str = ''
    last_message: str = ''
    last_seen: float = 0.0
    is_headless: bool = False
    permission_mode: str = 'supervised'
    pending_permission: Optional[PendingPermission] = None
    stopped_at: float = 0.0
    last_prompt: str = ''

    def touch(self):
        self.last_seen = time.time()

    def to_dict(self) -> dict:
        raw = dataclasses.asdict(self)
        if self.pending_permission is not None:
            raw['pending_permission'] = self.pending_permission.to_dict()
        return raw

    @classmethod
    def from_dict(cls, raw: dict):
        record = cls(
            session_id=raw['session_id'],
            task_id=raw.get('task_id', raw['session_id']),
            project=raw.get('project', raw['session_id'][:8]),
            cwd=raw.get('cwd', ''),
            raw_id=raw.get('raw_id', ''),
            tmux_target=raw.get('tmux_target', ''),
            tty=raw.get('tty', ''),
            state=raw.get('state', 'starting'),
            current_tool=raw.get('current_tool', ''),
            preview=raw.get('preview', ''),
            last_message=raw.get('last_message', ''),
            last_seen=float(raw.get('last_seen', time.time())),
            is_headless=bool(raw.get('is_headless', False)),
            permission_mode=raw.get('permission_mode', 'supervised'),
            stopped_at=float(raw.get('stopped_at', 0.0)),
            last_prompt=raw.get('last_prompt', ''),
        )
        record.pending_permission = PendingPermission.from_dict(raw.get('pending_permission'))
        return record


class SessionRegistry:
    def __init__(self, sessions: Optional[dict] = None):
        self.sessions: dict[str, SessionRecord] = sessions or {}
        self.aliases: dict[str, str] = {}
        for sid, session in self.sessions.items():
            self._index_aliases(session)

    @classmethod
    def from_dict(cls, raw: dict):
        sessions = {sid: SessionRecord.from_dict(info) for sid, info in raw.items()}
        return cls(sessions)

    def to_dict(self) -> dict:
        return {sid: session.to_dict() for sid, session in self.sessions.items()}

    def _alias_values(self, raw_id: str = '', tmux_target: str = '', tty: str = '') -> list[str]:
        values = []
        if raw_id:
            values.append(f'raw:{raw_id}')
        if tmux_target:
            values.append(f'tmux:{tmux_target}')
        if tty:
            values.append(f'tty:{tty}')
        return values

    def _index_aliases(self, session: SessionRecord):
        for alias in self._alias_values(session.raw_id, session.tmux_target, session.tty):
            self.aliases[alias] = session.session_id

    def resolve(self, raw_id: str = '', tmux_target: str = '', tty: str = '', cwd: str = '') -> str:
        for alias in self._alias_values(raw_id, tmux_target, tty):
            if alias in self.aliases:
                return self.aliases[alias]
        if cwd and not (raw_id or tmux_target or tty):
            matches = [sid for sid, session in self.sessions.items() if session.cwd == cwd and session.state != 'stopped']
            if len(matches) == 1:
                return matches[0]
        return ''

    def ensure(self, raw_id: str = '', tmux_target: str = '', tty: str = '', cwd: str = '', project: str = '') -> SessionRecord:
        sid = self.resolve(raw_id=raw_id, tmux_target=tmux_target, tty=tty, cwd=cwd)
        if sid:
            session = self.sessions[sid]
            if raw_id:
                session.raw_id = raw_id
            if tmux_target:
                session.tmux_target = tmux_target
            if tty:
                session.tty = tty
            if cwd:
                session.cwd = cwd
            if project:
                session.project = project
            session.touch()
            self._index_aliases(session)
            return session

        seed = raw_id or tmux_target or tty or cwd or str(time.time())
        digest = hashlib.sha1(seed.encode()).hexdigest()[:10]
        sid = f'codex3:{digest}'
        session = SessionRecord(
            session_id=sid,
            task_id=sid,
            project=project or (cwd.rstrip('/').split('/')[-1] if cwd else sid),
            cwd=cwd,
            raw_id=raw_id,
            tmux_target=tmux_target,
            tty=tty,
            last_seen=time.time(),
        )
        self.sessions[sid] = session
        self._index_aliases(session)
        return session

    def remove(self, session_id: str):
        session = self.sessions.pop(session_id, None)
        if not session:
            return
        for alias in self._alias_values(session.raw_id, session.tmux_target, session.tty):
            if self.aliases.get(alias) == session_id:
                self.aliases.pop(alias, None)
