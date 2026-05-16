#!/usr/bin/env python3
"""
Claude Code PostToolUse hook for claude-3.
Notifies the daemon that a tool ran so it can clear any pending permission
block that was waiting for a terminal response.
"""
import sys
import json
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon

data = json.load(sys.stdin)
session_id = data.get('session_id', '')
tool_name  = data.get('tool_name', '')
cwd        = data.get('cwd', '') or os.getcwd()

if not session_id or not tool_name:
    sys.exit(0)

send_to_daemon({
    'type': 'tool_executed',
    'session_id': session_id,
    'tool_name': tool_name,
    'cwd': cwd,
})

sys.exit(0)
