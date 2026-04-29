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
    suggestions: dict
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
            suggestions=raw.get('suggestions', {}),
            requested_at=float(raw.get('requested_at', time.time())),
        )


@dataclasses.dataclass
class SessionRecord:
    session_id: str       # stable claude3:{digest} ID used in block IDs
    task_id: str          # same value — used as A2A task ID
    raw_id: str           # Claude Code's own session UUID (used for terminal-manager routing)
    project: str
    cwd: str = ''
    tty: str = ''
    tmux_target: str = ''   # 'ask:<project>' when daemon owns the terminal
    state: str = 'starting'
    current_tool: str = ''
    preview: str = ''
    last_message: str = ''
    last_seen: float = 0.0
    is_transient: bool = False   # True for process-discovered sessions not from hooks
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
            raw_id=raw.get('raw_id', ''),
            project=raw.get('project', raw['session_id'][:8]),
            cwd=raw.get('cwd', ''),
            tty=raw.get('tty', ''),
            tmux_target=raw.get('tmux_target', ''),
            state=raw.get('state', 'starting'),
            current_tool=raw.get('current_tool', ''),
            preview=raw.get('preview', ''),
            last_message=raw.get('last_message', ''),
            last_seen=float(raw.get('last_seen', time.time())),
            is_transient=bool(raw.get('is_transient', False)),
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
        for session in self.sessions.values():
            self._index_aliases(session)

    @classmethod
    def from_dict(cls, raw: dict):
        sessions = {sid: SessionRecord.from_dict(info) for sid, info in raw.items()}
        return cls(sessions)

    def to_dict(self) -> dict:
        return {sid: s.to_dict() for sid, s in self.sessions.items()}

    def _alias_values(self, raw_id: str = '', tty: str = '') -> list[str]:
        vals = []
        if raw_id:
            vals.append(f'raw:{raw_id}')
        if tty:
            vals.append(f'tty:{tty}')
        return vals

    def _index_aliases(self, session: SessionRecord):
        for alias in self._alias_values(session.raw_id, session.tty):
            self.aliases[alias] = session.session_id

    def resolve(self, raw_id: str = '', tty: str = '', cwd: str = '') -> str:
        for alias in self._alias_values(raw_id, tty):
            if alias in self.aliases:
                return self.aliases[alias]
        if cwd and not (raw_id or tty):
            matches = [sid for sid, s in self.sessions.items()
                       if s.cwd == cwd and s.state != 'stopped']
            if len(matches) == 1:
                return matches[0]
        return ''

    def ensure(self, raw_id: str = '', tty: str = '', cwd: str = '',
               project: str = '', is_transient: bool = False) -> SessionRecord:
        sid = self.resolve(raw_id=raw_id, tty=tty, cwd=cwd)
        if sid:
            s = self.sessions[sid]
            if raw_id:
                s.raw_id = raw_id
            if tty:
                s.tty = tty
            if cwd:
                s.cwd = cwd
            if project:
                s.project = project
            s.touch()
            self._index_aliases(s)
            return s

        seed = raw_id or tty or cwd or str(time.time())
        digest = hashlib.sha1(seed.encode()).hexdigest()[:10]
        sid = f'claude3:{digest}'
        s = SessionRecord(
            session_id=sid,
            task_id=sid,
            raw_id=raw_id,
            project=project or (cwd.rstrip('/').split('/')[-1] if cwd else sid),
            cwd=cwd,
            tty=tty,
            last_seen=time.time(),
            is_transient=is_transient,
        )
        self.sessions[sid] = s
        self._index_aliases(s)
        return s

    def remove(self, session_id: str):
        s = self.sessions.pop(session_id, None)
        if not s:
            return
        for alias in self._alias_values(s.raw_id, s.tty):
            if self.aliases.get(alias) == session_id:
                self.aliases.pop(alias, None)
