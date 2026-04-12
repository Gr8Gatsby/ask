#!/usr/bin/env python3
"""
Claude Code PreToolUse hook for claude-3.
Sends live tool activity to the daemon so it can update the session block.
"""
import sys
import json
import socket
import os

SOCKET_PATH = os.environ.get('ASK_SOCKET_PATH', os.path.expanduser('~/.ask/sockets/claude-3.sock'))

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

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'pre_tool_use',
        'tool': tool_name,
        'preview': preview,
        'session_id': session_id,
        'cwd': cwd,
    }).encode())
    sock.close()
except Exception:
    pass

sys.exit(0)
