#!/usr/bin/env python3
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from _common import get_tmux_target, get_tty, send_event

data = json.load(sys.stdin)
session_id = data.get('session_id', '')

if not session_id:
    sys.exit(0)

try:
    send_event({
        'type': 'user_prompt_submit',
        'session_id': session_id,
        'cwd': data.get('cwd', '') or os.getcwd(),
        'tty': get_tty(),
        'tmux_target': get_tmux_target(),
        'prompt': data.get('prompt', ''),
    })
except Exception:
    pass

sys.exit(0)
