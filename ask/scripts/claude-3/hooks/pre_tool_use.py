#!/usr/bin/env python3
"""
Claude Code PreToolUse hook for claude-3.
Sends live tool activity and the last assistant message to the daemon.
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


data = json.load(sys.stdin)
session_id = data.get('session_id', '')
tool_name  = data.get('tool_name', '')
tool_input = data.get('tool_input', {})

if not session_id or not tool_name:
    sys.exit(0)

preview = ''
if tool_name == 'Bash':
    preview = str(tool_input.get('command', ''))[:500]
elif tool_name in ('Edit', 'Write', 'Read', 'NotebookEdit'):
    preview = str(tool_input.get('file_path', ''))
elif tool_name == 'Glob':
    preview = str(tool_input.get('pattern', ''))
elif tool_name == 'Grep':
    preview = str(tool_input.get('pattern', ''))
elif tool_name == 'Agent':
    preview = str(tool_input.get('description', ''))[:500]

cwd = os.getcwd()
last_message = _read_last_assistant_message(session_id, cwd)

send_to_daemon({
    'type': 'pre_tool_use',
    'tool': tool_name,
    'preview': preview,
    'session_id': session_id,
    'cwd': cwd,
    'last_message': last_message,
})

sys.exit(0)
