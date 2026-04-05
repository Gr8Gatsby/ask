#!/usr/bin/env python3
"""
ollama — Ask daemon script
Chat with locally installed Ollama models and manage Ollama updates.
Communicates with AskMac via JSON-RPC 2.0 over stdio.
"""
import sys
import json
import asyncio
import subprocess
import urllib.request
import urllib.error
from typing import Optional

# CRITICAL: unbuffered stdout so JSON-RPC messages reach the daemon immediately.
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

OLLAMA_BASE_URL       = "http://localhost:11434"
UPDATE_CHECK_INTERVAL = 6 * 60 * 60  # 6 hours

# Resolve full paths at startup so the script works when launched by AskMac
# with a restricted PATH (no /opt/homebrew/bin or /usr/local/bin).
def _find_executable(name: str) -> Optional[str]:
    candidates = [
        f'/opt/homebrew/bin/{name}',
        f'/usr/local/bin/{name}',
        f'/usr/bin/{name}',
    ]
    import os
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

OLLAMA_BIN = _find_executable('ollama')
BREW_BIN   = _find_executable('brew')

# Block IDs
BLOCK_TILE           = 'ollama-tile'
BLOCK_STATUS         = 'ollama-status'
BLOCK_UPDATE         = 'ollama-update'
BLOCK_MODEL_SELECT   = 'ollama-model-select'
BLOCK_CHAT           = 'ollama-chat'
BLOCK_RESPONSE       = 'ollama-response'
BLOCK_CONTROLS       = 'ollama-controls'


# ---------------------------------------------------------------------------
# MCPClient — JSON-RPC 2.0 over stdio
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._id      = 0
        self._pending = {}   # id -> Future
        self._cbs     = {}   # blockId -> coroutine callback

    def _send(self, obj: dict):
        sys.stdout.write(json.dumps(obj) + '\n')

    async def _rpc(self, method: str, params: dict = None, timeout: float = 30) -> dict:
        self._id += 1
        rid  = self._id
        loop = asyncio.get_running_loop()
        fut  = loop.create_future()
        self._pending[rid] = fut
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params:
            msg['params'] = params
        self._send(msg)
        return await asyncio.wait_for(fut, timeout=timeout)

    async def initialize(self, client_name: str = 'script'):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': client_name, 'version': '1.0'},
        }, timeout=15)
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print(f'[{client_name}] MCP initialized', file=sys.stderr)

    async def emit_block(self, block_id: str, block_type: str, payload: dict, ttl: int = None, inbox: bool = False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id: str):
        try:
            await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}}, timeout=10)
        except Exception:
            pass

    def set_callback(self, block_id: str, coro_fn):
        """Register an async callback for when the user responds to block_id."""
        self._cbs[block_id] = coro_fn

    async def read_loop(self):
        # Use run_in_executor so the blocking readline() runs in a thread
        # and doesn't block the event loop, while still cooperating with asyncio.
        loop = asyncio.get_running_loop()
        stdin_buf = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, stdin_buf.readline)
            except Exception:
                break
            if not raw:  # EOF
                break
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._dispatch(msg)
        print('[mcp] stdin closed', file=sys.stderr)

    def _dispatch(self, msg: dict):
        rid = msg.get('id')
        if rid is not None and 'result' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return
        if rid is not None and 'error' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return
        if msg.get('method') == 'notifications/message':
            data     = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value    = data.get('value', '')
                cb = self._cbs.pop(block_id, None)
                if cb:
                    asyncio.create_task(cb(value))


# ---------------------------------------------------------------------------
# Ollama API helpers (all blocking — run via run_in_executor)
# ---------------------------------------------------------------------------

def _http_get(url: str, timeout: float = 10) -> dict:
    req = urllib.request.Request(url, headers={'User-Agent': 'ask-ollama/1.0'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _http_post(url: str, body: dict, timeout: float = 300) -> dict:
    data = json.dumps(body).encode()
    req  = urllib.request.Request(url, data=data, headers={
        'Content-Type': 'application/json',
        'User-Agent':   'ask-ollama/1.0',
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def get_installed_models() -> list[str]:
    data = _http_get(f"{OLLAMA_BASE_URL}/api/tags")
    return [m['name'] for m in data.get('models', [])]


def get_ollama_local_version() -> str:
    """Read version via CLI — works even if the server is not running."""
    if not OLLAMA_BIN:
        return 'unknown'
    result = subprocess.run(
        [OLLAMA_BIN, '--version'],
        capture_output=True, text=True, stdin=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        # Output: "ollama version 0.6.2"
        parts = result.stdout.strip().split()
        return parts[-1] if parts else 'unknown'
    return 'unknown'


def get_latest_ollama_version() -> str:
    data = _http_get("https://api.github.com/repos/ollama/ollama/releases/latest")
    tag  = data.get('tag_name', '')
    return tag.lstrip('v')


def _parse_version(v: str) -> tuple:
    try:
        return tuple(int(x) for x in v.split('.') if x.isdigit())
    except Exception:
        return (0,)


def is_update_available(current: str, latest: str) -> bool:
    return _parse_version(latest) > _parse_version(current)


def is_brew_ollama() -> bool:
    if not BREW_BIN:
        return False
    result = subprocess.run(
        [BREW_BIN, 'list', '--formula', 'ollama'],
        capture_output=True, stdin=subprocess.DEVNULL,
    )
    return result.returncode == 0


def run_brew_upgrade() -> tuple[bool, str]:
    if not BREW_BIN:
        return False, 'brew not found'
    try:
        result = subprocess.run(
            [BREW_BIN, 'upgrade', 'ollama'],
            capture_output=True, text=True, stdin=subprocess.DEVNULL,
            timeout=300,
        )
        if result.returncode == 0:
            return True, result.stdout.strip() or 'Upgrade complete'
        return False, (result.stderr.strip() or result.stdout.strip() or 'Unknown error')
    except subprocess.TimeoutExpired:
        return False, 'Brew upgrade timed out after 5 minutes'


def run_direct_upgrade() -> tuple[bool, str]:
    """Update ollama via the official install script (non-brew installs)."""
    try:
        result = subprocess.run(
            'curl -fsSL https://ollama.com/install.sh | sh',
            shell=True, capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=300,
        )
        if result.returncode == 0:
            return True, 'Upgrade complete'
        return False, (result.stderr.strip() or result.stdout.strip() or 'Unknown error')
    except subprocess.TimeoutExpired:
        return False, 'Install script timed out after 5 minutes'


def chat_completion(model: str, messages: list[dict]) -> str:
    data = _http_post(f"{OLLAMA_BASE_URL}/api/chat", {
        'model':    model,
        'messages': messages,
        'stream':   False,
    })
    return data.get('message', {}).get('content', '').strip()


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------

class AppState:
    def __init__(self):
        self.selected_model: Optional[str]    = None
        self.history:        list[dict]    = []   # [{role, content}, ...]
        self.ollama_running: bool          = False


# ---------------------------------------------------------------------------
# Tile helper
# ---------------------------------------------------------------------------

async def update_tile(mcp: MCPClient, label: str, color: str, body: str = None, action_required: bool = False):
    """Update the home-screen tile block."""
    payload: dict = {'label': label[:50], 'status_color': color, 'action_required': action_required}
    if body:
        payload['body'] = body
    try:
        await mcp.emit_block(BLOCK_TILE, 'tile', payload)
    except Exception as e:
        print(f'[ollama] tile update failed: {e}', file=sys.stderr)


# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

async def show_model_selector(mcp: MCPClient, state: AppState, models: list[str] = None):
    if models is None:
        try:
            loop   = asyncio.get_running_loop()
            models = await loop.run_in_executor(None, get_installed_models)
        except Exception as e:
            print(f'[ollama] failed to list models: {e}', file=sys.stderr)
            await mcp.emit_block(BLOCK_STATUS, 'status', {
                'label':  'Cannot List Models',
                'detail': 'Is Ollama running?',
                'icon':   'xmark.circle',
                'color':  'red',
            }, ttl=120)
            return

    if not models:
        await mcp.emit_block(BLOCK_MODEL_SELECT, 'status', {
            'label':  'No Models Installed',
            'detail': 'Run: ollama pull llama3',
            'icon':   'exclamationmark.triangle',
            'color':  'orange',
        }, ttl=3600)
        return

    async def on_selected(value: str):
        state.selected_model = value
        state.history        = []
        await mcp.clear_block(BLOCK_MODEL_SELECT)
        await show_chat(mcp, state)

    await update_tile(mcp, 'Select a model', 'orange',
                      body=f'{len(models)} model(s) available')
    mcp.set_callback(BLOCK_MODEL_SELECT, on_selected)
    await mcp.emit_block(BLOCK_MODEL_SELECT, 'picker', {
        'title':    'Select Model',
        'options':  models,
        'selected': models[0] if models else None,
    })


async def show_chat(mcp: MCPClient, state: AppState):
    model = state.selected_model

    payload: dict = {
        'title':       f'Chat · {model}',
        'placeholder': 'Type a message…',
        'multiline':   True,
    }

    # Show last assistant reply as context bubble
    last_reply = next(
        (m['content'] for m in reversed(state.history) if m['role'] == 'assistant'),
        None,
    )
    if last_reply:
        preview = last_reply[:300] + ('…' if len(last_reply) > 300 else '')
        payload['context'] = preview

    async def on_message(text: str):
        text = text.strip()
        if not text:
            await show_chat(mcp, state)
            return
        await handle_message(mcp, state, text)

    mcp.set_callback(BLOCK_CHAT, on_message)
    await mcp.emit_block(BLOCK_CHAT, 'chat_prompt', payload)
    await show_controls(mcp, state)


async def show_controls(mcp: MCPClient, state: AppState):
    exchanges = len(state.history) // 2
    body      = f'Model: {state.selected_model}'
    if exchanges:
        body += f'\nExchanges: {exchanges}'

    async def on_control(value: str):
        if value == 'Change Model':
            state.selected_model = None
            state.history        = []
            await mcp.clear_block(BLOCK_CHAT)
            await mcp.clear_block(BLOCK_RESPONSE)
            await mcp.clear_block(BLOCK_CONTROLS)
            await mcp.clear_block(BLOCK_MODEL_SELECT)
            await show_model_selector(mcp, state)
        elif value == 'Clear History':
            state.history = []
            await mcp.clear_block(BLOCK_RESPONSE)
            # Re-show chat and controls (resets context bubble)
            await show_chat(mcp, state)

    mcp.set_callback(BLOCK_CONTROLS, on_control)
    await mcp.emit_block(BLOCK_CONTROLS, 'confirmation', {
        'title':   'Session',
        'body':    body,
        'options': ['Change Model', 'Clear History'],
    })


async def handle_message(mcp: MCPClient, state: AppState, message: str):
    model = state.selected_model

    state.history.append({'role': 'user', 'content': message})

    await update_tile(mcp, f'Thinking… · {model}', 'blue')
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label':  'Thinking…',
        'detail': model,
        'icon':   'ellipsis.bubble',
        'color':  'blue',
    })

    loop = asyncio.get_running_loop()
    try:
        history_snapshot = list(state.history)
        response = await loop.run_in_executor(
            None, lambda: chat_completion(model, history_snapshot)
        )
        state.history.append({'role': 'assistant', 'content': response})
    except Exception as e:
        print(f'[ollama] chat error: {e}', file=sys.stderr)
        state.history.pop()  # remove the user message we added
        await mcp.emit_block(BLOCK_STATUS, 'status', {
            'label':  'Chat Error',
            'detail': str(e)[:150],
            'icon':   'xmark.circle',
            'color':  'red',
        }, ttl=60)
        await show_chat(mcp, state)
        return

    # Restore running status
    version = await loop.run_in_executor(None, get_ollama_local_version)
    exchanges = len(state.history) // 2
    label = f'{model} · {exchanges} exchange(s)'
    await update_tile(mcp, label, 'green', body=response[:300])
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label':  f'Ollama {version}',
        'detail': f'{model} · {exchanges} exchange(s)',
        'icon':   'cpu',
        'color':  'green',
    })

    # Show the response card
    await mcp.emit_block(BLOCK_RESPONSE, 'info_card', {
        'title': f'{model} responded',
        'pairs': [
            {'key': 'Reply', 'value': response},
        ],
    })

    # Prompt for the next message
    await show_chat(mcp, state)


# ---------------------------------------------------------------------------
# Update checker
# ---------------------------------------------------------------------------

async def check_updates(mcp: MCPClient):
    print('[ollama] checking for updates…', file=sys.stderr)
    loop = asyncio.get_running_loop()

    current = await loop.run_in_executor(None, get_ollama_local_version)
    if current == 'unknown':
        print('[ollama] ollama not found in PATH, skipping update check', file=sys.stderr)
        return

    try:
        latest = await loop.run_in_executor(None, get_latest_ollama_version)
    except Exception as e:
        print(f'[ollama] failed to fetch latest version: {e}', file=sys.stderr)
        return

    if not is_update_available(current, latest):
        print(f'[ollama] up to date ({current})', file=sys.stderr)
        await mcp.clear_block(BLOCK_UPDATE)
        return

    print(f'[ollama] update available: {current} → {latest}', file=sys.stderr)

    async def on_update(value: str):
        await mcp.clear_block(BLOCK_UPDATE)
        if value == 'Update Now':
            await do_brew_update(mcp, current, latest)

    mcp.set_callback(BLOCK_UPDATE, on_update)
    await mcp.emit_block(BLOCK_UPDATE, 'confirmation', {
        'title':   'Ollama Update Available',
        'body':    f'Current: {current}\nLatest:  {latest}',
        'options': ['Update Now', 'Skip'],
    }, ttl=UPDATE_CHECK_INTERVAL, inbox=True)


async def do_brew_update(mcp: MCPClient, current: str, latest: str):
    loop = asyncio.get_running_loop()

    # Try brew first
    await mcp.emit_block(BLOCK_UPDATE, 'status', {
        'label':  f'Updating to {latest}…',
        'detail': 'Running brew upgrade ollama',
        'icon':   'arrow.down.circle',
        'color':  'blue',
    }, ttl=360)
    success, output = await loop.run_in_executor(None, run_brew_upgrade)

    # If brew doesn't manage ollama, fall back to the official install script
    if not success and 'not installed' in output.lower():
        await mcp.emit_block(BLOCK_UPDATE, 'status', {
            'label':  f'Updating to {latest}…',
            'detail': 'Running install script',
            'icon':   'arrow.down.circle',
            'color':  'blue',
        }, ttl=360)
        success, output = await loop.run_in_executor(None, run_direct_upgrade)

    if success:
        await mcp.emit_block(BLOCK_UPDATE, 'status', {
            'label':  f'Updated to Ollama {latest}',
            'detail': 'Restart Ollama to use the new version',
            'icon':   'checkmark.circle',
            'color':  'green',
        }, ttl=UPDATE_CHECK_INTERVAL)
    else:
        await mcp.emit_block(BLOCK_UPDATE, 'status', {
            'label':  'Update Failed',
            'detail': output[:150],
            'icon':   'xmark.circle',
            'color':  'red',
        }, ttl=3600)


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

async def startup(mcp: MCPClient, state: AppState):
    await update_tile(mcp, 'Connecting…', 'blue')
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label': 'Connecting to Ollama…',
        'icon':  'arrow.clockwise',
        'color': 'blue',
    })

    loop = asyncio.get_running_loop()

    try:
        models = await loop.run_in_executor(None, get_installed_models)
        state.ollama_running = True
    except Exception as e:
        print(f'[ollama] not reachable: {e}', file=sys.stderr)
        state.ollama_running = False
        await update_tile(mcp, 'Not Running', 'red',
                          body='Start Ollama, then restart this script')
        await mcp.emit_block(BLOCK_STATUS, 'status', {
            'label':  'Ollama Not Running',
            'detail': 'Start Ollama, then restart this script',
            'icon':   'xmark.circle',
            'color':  'red',
        }, ttl=UPDATE_CHECK_INTERVAL)
        return

    version = await loop.run_in_executor(None, get_ollama_local_version)
    await update_tile(mcp, f'Ollama {version}', 'green',
                      body=f'{len(models)} model(s) installed')
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label':  f'Ollama {version}',
        'detail': f'{len(models)} model(s) installed',
        'icon':   'cpu',
        'color':  'green',
    })

    await show_model_selector(mcp, state, models)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

async def run(mcp: MCPClient, test_mode: bool):
    state = AppState()
    runs  = 0

    await startup(mcp, state)

    while True:
        try:
            await check_updates(mcp)
        except Exception as e:
            print(f'[ollama] update check error: {e}', file=sys.stderr)

        runs += 1
        if test_mode and runs >= 1:
            print('[ollama] test mode complete', file=sys.stderr)
            await asyncio.sleep(60)
            return

        await asyncio.sleep(UPDATE_CHECK_INTERVAL)


async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[ollama] running in test mode', file=sys.stderr)

    mcp = MCPClient()
    # read_loop must be running before initialize() so the response from AskMac
    # can be dispatched to fulfill the pending RPC future.
    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='ollama')
    await run(mcp, test_mode=test_mode)


if __name__ == '__main__':
    asyncio.run(main())
