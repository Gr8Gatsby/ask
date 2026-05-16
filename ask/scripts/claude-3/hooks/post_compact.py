#!/usr/bin/env python3
"""
Claude Code PostCompact hook for claude-3.
Sends the compaction summary to the daemon so it can be recorded in the task feed.
"""
import sys
import json
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ipc import send_to_daemon

data       = json.load(sys.stdin)
session_id = data.get('session_id', '')
trigger    = data.get('trigger', 'auto')
summary    = data.get('summary', '').strip()[:1000]
cwd        = os.getcwd()

if not session_id or not summary:
    sys.exit(0)

send_to_daemon({
    'type': 'post_compact',
    'trigger': trigger,
    'summary': summary,
    'session_id': session_id,
    'cwd': cwd,
})

sys.exit(0)
