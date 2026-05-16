#!/usr/bin/env python3
"""
Claude Code PreCompact hook for claude-3.
Notifies the daemon that context compaction is about to start.
"""
import sys
import json
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon

data       = json.load(sys.stdin)
session_id = data.get('session_id', '')
trigger    = data.get('trigger', 'auto')
cwd        = os.getcwd()

if not session_id:
    sys.exit(0)

send_to_daemon({
    'type': 'pre_compact',
    'trigger': trigger,
    'session_id': session_id,
    'cwd': cwd,
})

sys.exit(0)
