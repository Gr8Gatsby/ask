#!/usr/bin/env python3
"""
Integration tests for codex-controller/main.py.

Starts the script as a subprocess and drives it via:
  - stdin / stdout: JSON-RPC (daemon ↔ script)
  - Unix socket:    hook events (hooks → script)

Usage:
  python3 tests/test_main.py
  python3 tests/test_main.py -v   # verbose — show all stdout lines
"""
import json
import os
import socket as socket_lib
import subprocess
import sys
import threading
import time
from typing import Optional

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'main.py')
TEST_SOCKET = '/tmp/test-codex-controller.sock'

VERBOSE = '-v' in sys.argv

PASS_COUNT = 0
FAIL_COUNT = 0


def ok(name: str):
    global PASS_COUNT
    PASS_COUNT += 1
    print(f'  \033[32m✓\033[0m {name}')


def fail(name: str, reason: str = ''):
    global FAIL_COUNT
    FAIL_COUNT += 1
    msg = f'  \033[31m✗\033[0m {name}'
    if reason:
        msg += f'\n      reason: {reason}'
    print(msg)


# ─── Test harness ─────────────────────────────────────────────────────────────

class TestHarness:
    """Runs main.py as a subprocess; feeds stdin, captures stdout, fires socket events."""

    def __init__(self):
        self.proc: Optional[subprocess.Popen] = None
        self._stdout_lines: list[dict] = []
        self._lock = threading.Lock()
        self._reader: Optional[threading.Thread] = None
        self._auto_respond = False

    def start(self, wait_for_socket=True):
        env = os.environ.copy()
        env['ASK_SOCKET_PATH'] = TEST_SOCKET
        env['ASK_SESSIONS_PATH'] = '/tmp/test-codex-sessions.json'
        env['ASK_SKIP_DISCOVERY'] = '1'
        self.proc = subprocess.Popen(
            [sys.executable, SCRIPT],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        if wait_for_socket:
            self._wait_for_socket()

    def enable_auto_respond(self):
        self._auto_respond = True

    def _read_stdout(self):
        for raw in self.proc.stdout:
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            if VERBOSE:
                print(f'    [stdout] {line}')
            try:
                msg = json.loads(line)
                with self._lock:
                    self._stdout_lines.append(msg)
                if msg.get('method') == 'tools/call' and 'id' in msg and self._auto_respond:
                    self.send_rpc_response(msg['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
            except json.JSONDecodeError:
                pass

    def _wait_for_socket(self, timeout=3.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(TEST_SOCKET):
                return
            time.sleep(0.05)
        raise RuntimeError('Socket did not appear in time')

    def send_rpc_response(self, rpc_id, result=None, error=None):
        msg: dict = {'jsonrpc': '2.0', 'id': rpc_id}
        if error:
            msg['error'] = error
        else:
            msg['result'] = result if result is not None else {}
        self.proc.stdin.write((json.dumps(msg) + '\n').encode())
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout=3.0, description='') -> Optional[dict]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for msg in self._stdout_lines:
                    if predicate(msg):
                        return msg
            time.sleep(0.05)
        if VERBOSE and description:
            print(f'    [timeout waiting for: {description}]')
        return None

    def messages_since(self, index: int) -> list[dict]:
        with self._lock:
            return list(self._stdout_lines[index:])

    @property
    def message_count(self) -> int:
        with self._lock:
            return len(self._stdout_lines)

    def socket_send(self, payload: dict) -> Optional[dict]:
        sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        sock.settimeout(5)
        try:
            sock.connect(TEST_SOCKET)
            sock.sendall(json.dumps(payload).encode())
            sock.shutdown(socket_lib.SHUT_WR)
            try:
                data = sock.recv(4096)
                return json.loads(data) if data else None
            except Exception:
                return None
        finally:
            sock.close()

    def do_handshake(self) -> bool:
        init_msg = self.wait_for(
            lambda m: m.get('method') == 'initialize' and 'id' in m,
            timeout=3.0,
            description='initialize request'
        )
        if not init_msg:
            fail('handshake: script sends initialize request', 'no message received')
            return False
        self.enable_auto_respond()
        self.send_rpc_response(
            init_msg['id'],
            {'protocolVersion': '2024-11-05', 'capabilities': {}, 'serverInfo': {'name': 'test', 'version': '0.1'}}
        )
        tile_call = self.wait_for(is_tile_emit, timeout=3.0, description='tile emit after init')
        return tile_call is not None

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if os.path.exists(TEST_SOCKET):
            try:
                os.unlink(TEST_SOCKET)
            except Exception:
                pass
        for f in ['/tmp/test-codex-sessions.json']:
            if os.path.exists(f):
                try:
                    os.unlink(f)
                except Exception:
                    pass


# ─── Helpers ──────────────────────────────────────────────────────────────────

def is_session_emit(m: dict) -> bool:
    return (m.get('method') == 'tools/call' and
            m.get('params', {}).get('name') == 'emit_block' and
            m.get('params', {}).get('arguments', {}).get('blockType') == 'agent_session')


def is_tile_emit(m: dict) -> bool:
    return (m.get('method') == 'tools/call' and
            m.get('params', {}).get('name') == 'emit_block' and
            m.get('params', {}).get('arguments', {}).get('blockType') == 'tile')


# ─── Tests ────────────────────────────────────────────────────────────────────

def test_handshake_and_tile():
    print('\nTest 1: MCP handshake + initial tile emit')
    h = TestHarness()
    h.start()

    init_msg = h.wait_for(lambda m: m.get('method') == 'initialize' and 'id' in m, timeout=3.0)
    if init_msg:
        ok('script sends initialize request')
    else:
        fail('script sends initialize request'); h.stop(); return

    params = init_msg.get('params', {})
    if params.get('protocolVersion') == '2024-11-05':
        ok('initialize uses correct protocol version')
    else:
        fail('initialize uses correct protocol version', f"got {params.get('protocolVersion')!r}")

    h.send_rpc_response(
        init_msg['id'],
        {'protocolVersion': '2024-11-05', 'capabilities': {}, 'serverInfo': {'name': 'test', 'version': '0.1'}}
    )

    notif = h.wait_for(lambda m: m.get('method') == 'notifications/initialized', timeout=2.0)
    if notif:
        ok('script sends notifications/initialized')
    else:
        fail('script sends notifications/initialized')

    tile_call = h.wait_for(is_tile_emit, timeout=3.0)
    if tile_call:
        ok('tile block emitted after init')
        args = tile_call['params']['arguments']
        payload = args.get('payload', {})
        if payload.get('status_color') == 'blue':
            ok('initial tile status is blue (Ready)')
        else:
            fail('initial tile status is blue', f"got {payload.get('status_color')!r}")
        h.send_rpc_response(tile_call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('tile block emitted after init')

    h.stop()


def test_tool_executed_emits_session():
    print('\nTest 2: tool_executed → agent_session block emitted with Codex branding')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'abc123-test-session-001'
    cwd = '/Users/kevin/Documents/code/myproject'

    h.socket_send({
        'type': 'tool_executed',
        'session_id': session_id,
        'tool_name': 'Bash',
        'cwd': cwd,
    })

    call = h.wait_for(is_session_emit, timeout=3.0)
    if call:
        ok('agent_session block emitted after tool_executed')
        args = call['params']['arguments']
        payload = args.get('payload', {})

        if payload.get('session_id') == session_id:
            ok('payload.session_id matches')
        else:
            fail('payload.session_id matches', f"got {payload.get('session_id')!r}")

        project = payload.get('project', '')
        if 'myproject' in project:
            ok('payload.project includes cwd basename')
        else:
            fail('payload.project includes cwd basename', f"got {project!r}")

        if payload.get('agent_name') == 'Codex':
            ok('payload.agent_name is Codex')
        else:
            fail('payload.agent_name is Codex', f"got {payload.get('agent_name')!r}")

        if payload.get('brand_color') == '#74AA9C':
            ok('payload.brand_color is OpenAI teal (#74AA9C)')
        else:
            fail('payload.brand_color is OpenAI teal', f"got {payload.get('brand_color')!r}")

        ttl = args.get('ttl')
        if isinstance(ttl, (int, float)) and ttl >= 3600:
            ok(f'session block has TTL ≥ 3600s (got {ttl}s)')
        else:
            fail('session block has TTL ≥ 3600s', f"got {ttl!r}")

        block_id = args.get('blockId', '')
        if 'session' in block_id and session_id[:8] in block_id:
            ok(f'block_id contains session prefix ({block_id})')
        else:
            fail('block_id contains session prefix', f"got {block_id!r}")

        h.send_rpc_response(call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('agent_session block emitted after tool_executed', 'timed out')

    h.stop()


def test_session_active_emits_session():
    print('\nTest 3: session_active (SessionStart hook) → agent_session block emitted')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'start-hook-sess-001'
    cwd = '/Users/kevin/Documents/code/startproject'

    h.socket_send({
        'type': 'session_active',
        'session_id': session_id,
        'cwd': cwd,
    })

    call = h.wait_for(
        lambda m: is_session_emit(m) and
                  m['params']['arguments']['payload'].get('session_id') == session_id,
        timeout=3.0
    )
    if call:
        ok('agent_session block emitted on session_active')
        payload = call['params']['arguments'].get('payload', {})
        if 'startproject' in payload.get('project', ''):
            ok('payload.project reflects cwd')
        else:
            fail('payload.project reflects cwd', f"got {payload.get('project')!r}")
        h.send_rpc_response(call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('agent_session block emitted on session_active', 'timed out')

    h.stop()


def test_initialized_guard():
    print('\nTest 4: _initialized guard — socket events before handshake')
    h = TestHarness()
    h.start()

    session_id = 'early-xyz-789'
    h.socket_send({
        'type': 'tool_executed',
        'session_id': session_id,
        'tool_name': 'Bash',
        'cwd': '/tmp/early-test',
    })

    time.sleep(0.2)

    init_msg = h.wait_for(lambda m: m.get('method') == 'initialize' and 'id' in m, timeout=3.0)

    with h._lock:
        premature = [m for m in h._stdout_lines if is_session_emit(m)]
    if not premature:
        ok('no session block emitted before handshake completes')
    else:
        fail('no session block emitted before handshake completes',
             f'{len(premature)} premature block(s) detected')

    if not init_msg:
        fail('script still sends initialize after early socket event'); h.stop(); return
    ok('script still sends initialize correctly')

    h.enable_auto_respond()
    h.send_rpc_response(
        init_msg['id'],
        {'protocolVersion': '2024-11-05', 'capabilities': {}, 'serverInfo': {'name': 'test', 'version': '0.1'}}
    )

    h.wait_for(is_tile_emit, timeout=3.0)
    post_init_session = h.wait_for(is_session_emit, timeout=3.0)
    if post_init_session:
        ok('pre-registered session block emitted after handshake completes')
        payload = post_init_session['params']['arguments'].get('payload', {})
        if payload.get('session_id') == session_id:
            ok('correct session_id in post-init block')
        else:
            fail('correct session_id in post-init block', f"got {payload.get('session_id')!r}")
    else:
        fail('pre-registered session block emitted after handshake completes', 'timed out')

    h.stop()


def test_session_stop():
    print('\nTest 5: session_stop → agent_session block updated with last_message')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'stop-test-sess-222'
    last_msg = 'Done! All files updated successfully.'

    h.socket_send({
        'type': 'session_stop',
        'session_id': session_id,
        'cwd': '/Users/kevin/project',
        'last_message': last_msg,
    })

    call = h.wait_for(is_session_emit, timeout=3.0)
    if call:
        ok('agent_session block emitted on session_stop')
        payload = call['params']['arguments'].get('payload', {})
        if payload.get('last_message') == last_msg:
            ok('payload.last_message matches')
        else:
            fail('payload.last_message matches', f"got {payload.get('last_message')!r}")
        if payload.get('session_id') == session_id:
            ok('payload.session_id matches')
        else:
            fail('payload.session_id matches', f"got {payload.get('session_id')!r}")
        if payload.get('is_working') == False:
            ok('is_working is False after session_stop')
        else:
            fail('is_working is False after session_stop', f"got {payload.get('is_working')!r}")
        h.send_rpc_response(call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('agent_session block emitted on session_stop', 'timed out')

    h.stop()


def test_ttl_rate_limit():
    print('\nTest 6: TTL rate-limit — no re-emit within 300s for same session')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'rate-limit-sess-333'

    h.socket_send({'type': 'tool_executed', 'session_id': session_id, 'tool_name': 'Bash', 'cwd': '/tmp'})
    first = h.wait_for(is_session_emit, timeout=3.0)
    if first:
        ok('first tool_executed emits session block')
        h.send_rpc_response(first['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('first tool_executed emits session block'); h.stop(); return

    idx = h.message_count
    h.socket_send({'type': 'tool_executed', 'session_id': session_id, 'tool_name': 'Bash', 'cwd': '/tmp'})
    time.sleep(0.5)

    new_session_emits = [m for m in h.messages_since(idx) if is_session_emit(m)]
    if not new_session_emits:
        ok('second tool_executed within 300s does NOT re-emit (rate limited)')
    else:
        fail('second tool_executed within 300s does NOT re-emit', f'{len(new_session_emits)} extra emit(s)')

    h.stop()


def test_multiple_sessions():
    print('\nTest 7: multiple concurrent sessions each get their own block')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    sessions = [
        ('sess-aaa-111', '/Users/kevin/projectA'),
        ('sess-bbb-222', '/Users/kevin/projectB'),
        ('sess-ccc-333', '/Users/kevin/projectC'),
    ]

    emitted_ids: set[str] = set()

    for session_id, cwd in sessions:
        h.socket_send({'type': 'tool_executed', 'session_id': session_id, 'tool_name': 'Bash', 'cwd': cwd})
        call = h.wait_for(
            lambda m, sid=session_id: (is_session_emit(m) and
                                       m['params']['arguments']['payload'].get('session_id') == sid),
            timeout=3.0
        )
        if call:
            emitted_ids.add(session_id)
            h.send_rpc_response(call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
        else:
            fail(f'session block emitted for {session_id[:8]}', 'timed out')

    if len(emitted_ids) == len(sessions):
        ok(f'all {len(sessions)} sessions emitted distinct blocks')
    else:
        fail(f'all {len(sessions)} sessions emitted blocks', f'only {len(emitted_ids)} emitted')

    with h._lock:
        session_calls = [m for m in h._stdout_lines if is_session_emit(m)]
    block_ids = [m['params']['arguments'].get('blockId') for m in session_calls]
    if len(set(block_ids)) == len(sessions):
        ok('each session has a unique blockId')
    else:
        fail('each session has a unique blockId', f'block_ids: {block_ids}')

    h.stop()


def test_permission_block():
    print('\nTest 8: permission_request → confirmation block + iOS response → Allow')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'perm-sess-444'
    tool = 'Bash'
    preview = 'rm -rf /tmp/test'

    perm_result: list = []

    def send_perm():
        resp = h.socket_send({
            'type': 'permission_request',
            'session_id': session_id,
            'tool': tool,
            'preview': preview,
            'options': ['Allow', 'Deny'],
        })
        perm_result.append(resp)

    t = threading.Thread(target=send_perm)
    t.start()

    conf_call = h.wait_for(
        lambda m: (m.get('method') == 'tools/call' and
                   m.get('params', {}).get('name') == 'emit_block' and
                   m.get('params', {}).get('arguments', {}).get('blockType') == 'confirmation'),
        timeout=3.0
    )

    if conf_call:
        ok('confirmation block emitted for permission request')
        payload = conf_call['params']['arguments'].get('payload', {})
        if tool in payload.get('title', ''):
            ok(f'title mentions tool name ({tool})')
        else:
            fail('title mentions tool name', f"got {payload.get('title')!r}")
        if preview in payload.get('body', ''):
            ok('body contains preview')
        else:
            fail('body contains preview', f"got {payload.get('body')!r}")
        if payload.get('session_id') == session_id:
            ok('confirmation payload includes session_id for iOS grouping')
        else:
            fail('confirmation payload includes session_id', f"got {payload.get('session_id')!r}")

        block_id = conf_call['params']['arguments']['blockId']
        h.send_rpc_response(conf_call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})

        user_response = {
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {
                'level': 'info',
                'data': {
                    'type': 'user_response',
                    'blockId': block_id,
                    'value': 'Allow',
                }
            }
        }
        h.proc.stdin.write((json.dumps(user_response) + '\n').encode())
        h.proc.stdin.flush()

        t.join(timeout=3.0)
        if perm_result and perm_result[0] and perm_result[0].get('value') == 'Allow':
            ok('permission hook receives Allow response from iOS')
        else:
            fail('permission hook receives Allow response', f"got {perm_result}")
    else:
        fail('confirmation block emitted for permission request', 'timed out')
        t.join(timeout=1)

    h.stop()


def test_permission_deny():
    print('\nTest 9: permission_request → Deny response from iOS')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'deny-sess-555'
    tool = 'Bash'

    perm_result: list = []

    def send_perm():
        resp = h.socket_send({
            'type': 'permission_request',
            'session_id': session_id,
            'tool': tool,
            'preview': 'curl http://example.com',
            'options': ['Allow', 'Deny'],
        })
        perm_result.append(resp)

    t = threading.Thread(target=send_perm)
    t.start()

    conf_call = h.wait_for(
        lambda m: (m.get('method') == 'tools/call' and
                   m.get('params', {}).get('name') == 'emit_block' and
                   m.get('params', {}).get('arguments', {}).get('blockType') == 'confirmation'),
        timeout=3.0
    )

    if not conf_call:
        fail('confirmation block emitted'); t.join(timeout=1); h.stop(); return
    ok('confirmation block emitted for Deny test')

    block_id = conf_call['params']['arguments']['blockId']
    h.proc.stdin.write((json.dumps({
        'jsonrpc': '2.0',
        'method': 'notifications/message',
        'params': {'level': 'info', 'data': {'type': 'user_response', 'blockId': block_id, 'value': 'Deny'}}
    }) + '\n').encode())
    h.proc.stdin.flush()

    t.join(timeout=3.0)
    if perm_result and perm_result[0] and perm_result[0].get('value') == 'Deny':
        ok('permission hook receives Deny response from iOS')
    else:
        fail('permission hook receives Deny response', f"got {perm_result}")

    h.stop()


def test_permission_waits_indefinitely():
    print('\nTest 10: permission_request waits indefinitely — daemon stays alive after hook disconnect')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'indefinite-sess-666'

    def send_and_disconnect():
        """Send a permission request then close the socket without responding —
        simulates the user answering directly in the terminal."""
        sock = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
        sock.settimeout(5)
        try:
            sock.connect(TEST_SOCKET)
            sock.sendall(json.dumps({
                'type': 'permission_request',
                'session_id': session_id,
                'tool': 'Bash',
                'preview': 'echo test',
                'options': ['Allow', 'Deny'],
            }).encode())
            sock.shutdown(socket_lib.SHUT_WR)
            time.sleep(1.0)
            sock.close()
        except Exception:
            pass

    t = threading.Thread(target=send_and_disconnect)
    t.start()

    conf_call = h.wait_for(
        lambda m: (m.get('method') == 'tools/call' and
                   m.get('params', {}).get('arguments', {}).get('blockType') == 'confirmation'),
        timeout=3.0
    )
    if conf_call:
        ok('confirmation block emitted while hook is waiting')
        h.send_rpc_response(conf_call['id'], {'content': [{'type': 'text', 'text': 'ok'}]})
    else:
        fail('confirmation block emitted while hook is waiting')
        t.join(timeout=2); h.stop(); return

    t.join(timeout=3.0)
    # Give the daemon time to detect the disconnect and clean up
    time.sleep(1.5)

    # Key test: daemon must remain alive and process new requests after the hook disconnects.
    # (The block cleanup happens via the probe-write detect path, which is timing-dependent,
    # but the daemon must never hang or crash.)
    new_session = 'post-disconnect-check'
    h.socket_send({'type': 'tool_executed', 'session_id': new_session, 'tool_name': 'Bash', 'cwd': '/tmp'})
    alive_call = h.wait_for(
        lambda m: is_session_emit(m) and
                  m['params']['arguments']['payload'].get('session_id') == new_session,
        timeout=3.0
    )
    if alive_call:
        ok('daemon remains alive and responsive after hook process disconnects')
    else:
        fail('daemon remains alive and responsive after hook process disconnects', 'timed out')

    h.stop()


def test_session_sticky_ttl():
    print('\nTest 11: session blocks use 1-hour TTL so idle sessions persist')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'sticky-sess-001'
    h.socket_send({'type': 'tool_executed', 'session_id': session_id, 'tool_name': 'Bash', 'cwd': '/tmp'})
    call = h.wait_for(lambda m: is_session_emit(m) and
                      m['params']['arguments']['payload'].get('session_id') == session_id, timeout=3.0)

    if call:
        ttl = call['params']['arguments'].get('ttl')
        if isinstance(ttl, (int, float)) and ttl >= 3600:
            ok(f'session block TTL is ≥ 3600s (got {ttl}s)')
        else:
            fail('session block TTL is ≥ 3600s', f"got {ttl!r}")
    else:
        fail('session block emitted for TTL check')

    last_msg = 'Task completed.'
    h.socket_send({'type': 'session_stop', 'session_id': session_id, 'cwd': '/tmp', 'last_message': last_msg})
    stop_call = h.wait_for(lambda m: is_session_emit(m) and
                           m['params']['arguments']['payload'].get('session_id') == session_id and
                           m['params']['arguments']['payload'].get('last_message') == last_msg, timeout=3.0)
    if stop_call:
        stop_ttl = stop_call['params']['arguments'].get('ttl')
        if isinstance(stop_ttl, (int, float)) and stop_ttl >= 3600:
            ok(f'session_stop block also uses long TTL (got {stop_ttl}s)')
        else:
            fail('session_stop block uses long TTL', f"got {stop_ttl!r}")
    else:
        fail('session_stop block emitted for TTL check')

    h.stop()


def test_permission_session_grouping():
    print('\nTest 12: permission linked to session carries session_id; unlinked does not')
    h = TestHarness()
    h.start()

    if not h.do_handshake():
        h.stop(); return

    session_id = 'group-sess-777'

    h.socket_send({'type': 'tool_executed', 'session_id': session_id, 'tool_name': 'Bash', 'cwd': '/tmp'})
    h.wait_for(lambda m: is_session_emit(m) and
               m['params']['arguments']['payload'].get('session_id') == session_id, timeout=3.0)

    perm_result: list = []

    def send_perm():
        resp = h.socket_send({
            'type': 'permission_request',
            'session_id': session_id,
            'tool': 'Bash',
            'preview': 'ls /tmp',
            'options': ['Allow', 'Deny'],
        })
        perm_result.append(resp)

    t = threading.Thread(target=send_perm)
    t.start()

    conf_call = h.wait_for(
        lambda m: (m.get('method') == 'tools/call' and
                   m.get('params', {}).get('arguments', {}).get('blockType') == 'confirmation'),
        timeout=3.0
    )
    if conf_call:
        payload = conf_call['params']['arguments']['payload']
        if payload.get('session_id') == session_id:
            ok('linked permission carries session_id (enables iOS grouping with session card)')
        else:
            fail('linked permission carries session_id', f"got {payload.get('session_id')!r}")

        block_id = conf_call['params']['arguments']['blockId']
        h.proc.stdin.write((json.dumps({
            'jsonrpc': '2.0', 'method': 'notifications/message',
            'params': {'level': 'info', 'data': {'type': 'user_response', 'blockId': block_id, 'value': 'Allow'}}
        }) + '\n').encode())
        h.proc.stdin.flush()
        t.join(timeout=3.0)
    else:
        fail('linked permission confirmation block emitted')
        t.join(timeout=1)

    perm_result2: list = []

    def send_perm2():
        resp = h.socket_send({
            'type': 'permission_request',
            'session_id': '',
            'tool': 'Bash',
            'preview': 'echo hello',
            'options': ['Allow', 'Deny'],
        })
        perm_result2.append(resp)

    t2 = threading.Thread(target=send_perm2)
    t2.start()

    conf_call2 = h.wait_for(
        lambda m: (m.get('method') == 'tools/call' and
                   m.get('params', {}).get('arguments', {}).get('blockType') == 'confirmation' and
                   'echo hello' in m.get('params', {}).get('arguments', {}).get('payload', {}).get('body', '')),
        timeout=3.0
    )
    if conf_call2:
        payload2 = conf_call2['params']['arguments']['payload']
        if 'session_id' not in payload2:
            ok('unlinked permission has no session_id in payload')
        else:
            fail('unlinked permission has no session_id', f"got session_id={payload2.get('session_id')!r}")

        block_id2 = conf_call2['params']['arguments']['blockId']
        h.proc.stdin.write((json.dumps({
            'jsonrpc': '2.0', 'method': 'notifications/message',
            'params': {'level': 'info', 'data': {'type': 'user_response', 'blockId': block_id2, 'value': 'Allow'}}
        }) + '\n').encode())
        h.proc.stdin.flush()
        t2.join(timeout=3.0)
    else:
        fail('unlinked permission confirmation block emitted')
        t2.join(timeout=1)

    h.stop()


# ─── Runner ───────────────────────────────────────────────────────────────────

TESTS = [
    test_handshake_and_tile,
    test_tool_executed_emits_session,
    test_session_active_emits_session,
    test_initialized_guard,
    test_session_stop,
    test_ttl_rate_limit,
    test_multiple_sessions,
    test_permission_block,
    test_permission_deny,
    test_permission_waits_indefinitely,
    test_session_sticky_ttl,
    test_permission_session_grouping,
]

if __name__ == '__main__':
    print('codex-controller test suite')
    print('=' * 60)
    for test_fn in TESTS:
        try:
            test_fn()
        except Exception as e:
            import traceback
            fail(f'{test_fn.__name__} (unhandled exception)', str(e))
            traceback.print_exc()
        finally:
            if os.path.exists(TEST_SOCKET):
                try:
                    os.unlink(TEST_SOCKET)
                except Exception:
                    pass
            time.sleep(0.1)

    print()
    print('=' * 60)
    total = PASS_COUNT + FAIL_COUNT
    color = '\033[32m' if FAIL_COUNT == 0 else '\033[31m'
    print(f'{color}Results: {PASS_COUNT}/{total} passed, {FAIL_COUNT} failed\033[0m')
    sys.exit(0 if FAIL_COUNT == 0 else 1)
