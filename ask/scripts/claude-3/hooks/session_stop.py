#!/usr/bin/env python3
"""
Claude Code Stop hook for claude-3.
Sends the final assistant message to the daemon so it can close the task feed.
"""
import sys
import json
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon


def _transcript_path(session_id: str, cwd: str) -> str:
    encoded = '-' + cwd.lstrip('/').replace('/', '-')
    return os.path.expanduser(f'~/.claude/projects/{encoded}/{session_id}.jsonl')


def _read_last_assistant_message(session_id: str, cwd: str, max_bytes: int = 50_000) -> str:
    """Return the most recent assistant text from the session transcript, or ''."""
    path = _transcript_path(session_id, cwd)
    if not os.path.exists(path):
        return ''
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            tail = f.read().decode('utf-8', errors='replace')
        for line in reversed(tail.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get('type') != 'assistant':
                continue
            content = (entry.get('message') or {}).get('content', [])
            if not isinstance(content, list):
                continue
            text_parts = [
                block['text'].strip()
                for block in content
                if isinstance(block, dict) and block.get('type') == 'text'
                and block.get('text', '').strip()
            ]
            if text_parts:
                return '\n\n'.join(text_parts)
    except Exception:
        pass
    return ''


data       = json.load(sys.stdin)
session_id = data.get('session_id', '')
cwd        = data.get('cwd', '') or os.getcwd()

if not session_id:
    sys.exit(0)

# Wait briefly so Claude Code finishes flushing the final assistant message
# to the session JSONL before we read it. Without this, the Stop hook fires
# before the transcript is updated and the final message is silently skipped.
import time
time.sleep(1)

last_text = _read_last_assistant_message(session_id, cwd)

send_to_daemon({
    'type': 'session_stop',
    'session_id': session_id,
    'cwd': cwd,
    'last_message': last_text,
})

sys.exit(0)
