---
name: ask-script
description: Create a complete, working Ask script (Mac daemon script that surfaces blocks to iPhone via MCP/CloudKit). Use when asked to build a new script for the Ask system.
argument-hint: [describe what the script should do]
---

Create a complete, working Ask script for the system described below. The script must work correctly the first time — follow all patterns exactly.

## Script vault location

Scripts are installed into a **vault directory** that AskMac watches. Two modes:

| Mode | Path | When to use |
|------|------|-------------|
| **Prod** | `~/.ask/scripts` | Default; persistent across repo checkouts |
| **Dev** | `<repo-root>/ask/scripts` | Iterating in this repo |

The active vault path is stored in UserDefaults (`simple.askmac` → `vaultPath`). Use the `/vault-setup` skill to switch between modes.

Example scripts (for reference when building new ones) live in `ask/scripts/` in this repo:
- `brew-monitor` — monitors Homebrew outdated packages
- `claudecode-controller` — remote Claude Code session control
- `github` — GitHub notifications
- `ollama` — Ollama model status

## What to build

$ARGUMENTS

---

## System overview

The Ask Mac companion app (`~/.ask/scripts/`) runs scripts as persistent daemons. Each script communicates over **JSON-RPC 2.0 on stdio** with the AskMac daemon, which surfaces UI **blocks** to the user's iPhone via CloudKit. Scripts run indefinitely (they are managed processes, not one-shot commands).

---

## Required file layout

```
~/.ask/scripts/{script-id}/
├── manifest.json          # required — daemon reads this
├── main.py                # entry point (Python preferred unless asked for Swift)
└── icon.svg               # optional — custom icon rendered on iOS
```

For Swift scripts add:
```
├── Sources/
│   ├── main.swift
│   ├── {Feature}.swift
│   └── MCPClient.swift    # copy verbatim from reference below
├── Package.swift
└── build.sh
```

---

## manifest.json

```json
{
  "id": "my-script",
  "name": "My Script",
  "version": "1.0",
  "description": "One-line description",
  "entry": "main.py",
  "icon": "sparkles",
  "icon_file": "icon.svg"
}
```

- `id` — lowercase-hyphenated, unique. Also used as block ID prefix.
- `entry` — relative path to the executable (Python file or compiled binary).
- `icon` — SF Symbol name, shown if no SVG is available.
- `icon_file` — path to an SVG file; rendered natively on iOS (preferred over PNG).

---

## Block types reference

All blocks are emitted via `emit_block`. iOS polls every 5 s. Re-emit the same `blockId` to update it in place.

| Type | Payload fields | Responds? |
|------|---------------|-----------|
| `confirmation` | `title`, `body` (monospaced), `options: [string]` | ✅ tapped option |
| `prompt` | `title`, `placeholder?`, `multiline?` | ✅ submitted text |
| `chat_prompt` | `title`, `context?` (last reply bubble), `placeholder?` | ✅ submitted text |
| `picker` | `title`, `options: [string]`, `selected?` | ✅ selected value — renders as native dropdown + Select button |
| `status` | `label`, `detail?`, `icon?` (SF Symbol), `color` (green/blue/orange/red/yellow) | ❌ |
| `alert` | `title`, `body`, `icon?` | ❌ (passive, not persisted) |
| `info_card` | `title`, `pairs: [{key, value}]` | ❌ |
| `icon_card` | `title`, `subtitle?` | ❌ (use at startup for idle state) |
| `countdown` | `label`, `time` (ISO 8601 UTC) | ❌ — renders live "label in Xh Ym" on tile and detail |
| `tile` | `label`, `status_color?`, `body?`, `action_required?` | ❌ — drives home-screen tile only, not shown in detail |

**Block ID conventions:**
- Use stable, meaningful strings: `"my-script-status"`, `"my-script-confirm"`
- Re-emitting the same ID overwrites the block
- Always call `clear_block` when a block is no longer relevant
- Register response callbacks **before** calling `emit_block` (avoids race with fast CloudKit + user)

---

## Python script template

```python
#!/usr/bin/env python3
"""
{script-name} — Ask daemon script
Communicates with AskMac via JSON-RPC 2.0 over stdio.
"""
import sys
import json
import asyncio
import subprocess

# CRITICAL: unbuffered stdout so JSON-RPC messages reach the daemon immediately.
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)

CHECK_INTERVAL = 4 * 60 * 60   # normal: every 4 hours
TEST_INTERVAL  = 10             # test mode: re-check after 10 s then exit

# ---------------------------------------------------------------------------
# MCPClient — JSON-RPC 2.0 over stdio
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._id      = 0
        self._pending = {}          # id -> Future
        self._cbs     = {}          # blockId -> coroutine callback

    # -- Low level --

    def _send(self, obj: dict):
        sys.stdout.write(json.dumps(obj) + '\n')

    async def _rpc(self, method: str, params: dict = None, timeout: float = 30) -> dict:
        self._id += 1
        rid = self._id
        loop = asyncio.get_running_loop()
        fut  = loop.create_future()
        self._pending[rid] = fut
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params:
            msg['params'] = params
        self._send(msg)
        return await asyncio.wait_for(fut, timeout=timeout)

    # -- Lifecycle --

    async def initialize(self, client_name: str = 'script'):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': client_name, 'version': '1.0'}
        }, timeout=15)
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print(f'[{client_name}] MCP initialized', file=sys.stderr)

    # -- Block helpers --

    async def emit_block(self, block_id: str, block_type: str, payload: dict, ttl: int = None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id: str):
        try:
            await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}}, timeout=10)
        except Exception:
            pass

    def set_callback(self, block_id: str, coro_fn):
        """Register an async callback for when the user responds to block_id."""
        self._cbs[block_id] = coro_fn

    # -- Stdin read loop --

    async def read_loop(self):
        """Reads JSON-RPC messages from stdin and dispatches them.
        Uses run_in_executor so the blocking readline() doesn't stall the event loop.
        connect_read_pipe is NOT used — it only delivers the first message on macOS."""
        loop = asyncio.get_running_loop()
        stdin_buf = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, stdin_buf.readline)
            except Exception:
                break
            if not raw:   # EOF — daemon closed the pipe
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
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value    = data.get('value', '')
                cb = self._cbs.pop(block_id, None)
                if cb:
                    asyncio.create_task(cb(value))


# ---------------------------------------------------------------------------
# Script logic
# ---------------------------------------------------------------------------

BLOCK_STATUS  = 'my-script-status'
BLOCK_CONFIRM = 'my-script-confirm'

async def run(mcp: MCPClient, test_mode: bool):
    interval = TEST_INTERVAL if test_mode else CHECK_INTERVAL
    runs = 0

    while True:
        try:
            await check(mcp)
        except Exception as e:
            print(f'[my-script] check error: {e}', file=sys.stderr)

        runs += 1
        if test_mode and runs >= 1:
            # In test mode: emit one cycle, wait briefly for the user to see
            # the blocks on iOS, then exit cleanly.
            print('[my-script] test mode complete', file=sys.stderr)
            await asyncio.sleep(60)
            return

        await asyncio.sleep(interval)


async def check(mcp: MCPClient):
    print('[my-script] running check…', file=sys.stderr)

    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label': 'Checking…',
        'icon':  'arrow.clockwise',
        'color': 'blue',
    }, ttl=60)

    # --- do the actual work here ---
    result = do_work()
    # --------------------------------

    await mcp.clear_block(BLOCK_STATUS)

    if not result:
        await mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'All clear',
            'icon':  'checkmark.circle',
            'color': 'green',
        }, ttl=CHECK_INTERVAL)
        return

    title = f'{len(result)} item(s) need attention'
    body  = '\n'.join(result)

    # Register callback BEFORE emitting (avoids race condition).
    async def on_response(value: str):
        await mcp.clear_block(BLOCK_CONFIRM)
        if value == 'Fix Now':
            await do_fix(mcp)

    mcp.set_callback(BLOCK_CONFIRM, on_response)
    await mcp.emit_block(BLOCK_CONFIRM, 'confirmation', {
        'title':   title,
        'body':    body,
        'options': ['Fix Now', 'Later'],
    }, ttl=86400)


def do_work() -> list[str]:
    """Return list of issues found, or empty list if all clear."""
    # TODO: implement
    return []


async def do_fix(mcp: MCPClient):
    """Perform the fix and update status."""
    await mcp.emit_block(BLOCK_STATUS, 'status', {
        'label': 'Fixing…',
        'icon':  'arrow.down.circle',
        'color': 'blue',
    }, ttl=300)
    # TODO: implement
    await mcp.clear_block(BLOCK_STATUS)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[my-script] running in test mode', file=sys.stderr)

    mcp = MCPClient()

    # read_loop MUST be running before initialize() so the response from AskMac
    # can be dispatched. Using gather() or awaiting initialize() first causes a
    # deadlock because the response never gets dispatched.
    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='my-script')
    await run(mcp, test_mode=test_mode)

if __name__ == '__main__':
    asyncio.run(main())
```

---

## Swift MCPClient (copy verbatim — do not modify)

This is the production-tested implementation. Copy it exactly into `Sources/MCPClient.swift`:

```swift
import Foundation

enum MCPError: Error, CustomStringConvertible {
    case timeout
    case pipeBroken
    case rpcError(String)

    var description: String {
        switch self {
        case .timeout:           return "RPC timed out"
        case .pipeBroken:        return "stdout pipe is broken"
        case .rpcError(let msg): return "RPC error: \(msg)"
        }
    }
}

actor MCPClient {
    private var nextID = 0
    private var pending:         [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]
    private var responseCbs:     [String: @Sendable (String) async -> Void] = [:]
    private var pipeBroken = false

    nonisolated func rawSend(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func rpc(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard !pipeBroken else { throw MCPError.pipeBroken }
        let id = nextID; nextID += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        rawSend(msg)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            let t = Task {
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); await self.expireRPC(id: id) }
                catch { }
            }
            pendingTimeouts[id] = t
        }
    }

    private func expireRPC(id: Int) async {
        pendingTimeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: MCPError.timeout)
    }

    func fulfill(id: Int, result: [String: Any]) {
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: result)
    }

    func fail(id: Int, error: Error) {
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func initialize(clientName: String) async throws {
        _ = try await rpc("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": clientName, "version": "1.0"]
        ], timeout: 15)
        rawSend(["jsonrpc": "2.0", "method": "notifications/initialized"])
        fputs("[\(clientName)] MCP initialized\n", stderr)
    }

    func emitBlock(_ blockID: String, type: String, payload: [String: Any], ttl: TimeInterval? = nil) async throws {
        var args: [String: Any] = ["blockId": blockID, "blockType": type, "payload": payload]
        if let ttl { args["ttl"] = ttl }
        _ = try await rpc("tools/call", params: ["name": "emit_block", "arguments": args])
    }

    func clearBlock(_ blockID: String) async {
        _ = try? await rpc("tools/call", params: ["name": "clear_block", "arguments": ["blockId": blockID]], timeout: 30)
    }

    func setCallback(blockID: String, _ cb: @escaping @Sendable (String) async -> Void) {
        responseCbs[blockID] = cb
    }

    nonisolated func readLoop() async {
        let fh = FileHandle.standardInput
        for await line in MCPClient.stdinLines(fh) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            await dispatch(json)
        }
    }

    private static func stdinLines(_ fh: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            final class State: @unchecked Sendable { var buffer = Data() }
            let state = State()
            let fd = fh.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler {
                var chunk = Data(count: 4096)
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 4096) }
                guard n > 0 else { source.cancel(); return }
                state.buffer.append(chunk.prefix(n))
                while let range = state.buffer.range(of: Data([0x0A])) {
                    if let line = String(data: state.buffer[state.buffer.startIndex..<range.lowerBound], encoding: .utf8) {
                        continuation.yield(line)
                    }
                    state.buffer.removeSubrange(state.buffer.startIndex...range.lowerBound)
                }
            }
            source.setCancelHandler { continuation.finish() }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        let rpcID = (msg["id"] as? NSNumber)?.intValue
        if let id = rpcID, let result = msg["result"] as? [String: Any] { fulfill(id: id, result: result); return }
        if let id = rpcID, let error = msg["error"] { fail(id: id, error: MCPError.rpcError(String(describing: error))); return }
        if msg["method"] as? String == "notifications/message" {
            let data = (msg["params"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
            guard data["type"] as? String == "user_response" else { return }
            let blockID = data["blockId"] as? String ?? ""
            let value   = data["value"]   as? String ?? ""
            if let cb = responseCbs.removeValue(forKey: blockID) { Task { await cb(value) } }
        }
    }
}
```

Swift `main.swift` entry point:

```swift
import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)  // required — broken pipe must not crash the process

let testMode = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "test"
let mcp      = MCPClient()
let monitor  = MyMonitor(mcp: mcp, testMode: testMode)

await withTaskGroup(of: Void.self) { group in
    group.addTask { await mcp.readLoop() }
    group.addTask {
        do { try await mcp.initialize(clientName: "my-script") }
        catch { fputs("[my-script] init failed: \(error)\n", stderr); return }
        await monitor.run()
    }
}
```

---

## Code signing

**Python scripts:** No signing needed. The system Python interpreter runs them directly.

**Swift compiled binaries:** Must be ad-hoc signed or macOS will refuse to execute them. `swift build` applies a linker-provided ad-hoc signature automatically, but it can be stripped by a plain `cp`. Always re-sign explicitly in `build.sh` after copying:

```bash
cp "$BINARY" "$DEST"
codesign --sign - --force "$DEST"
echo "Signed $DEST (ad-hoc)"
```

`--sign -` means ad-hoc (no Developer ID required). This is sufficient for locally built scripts on the same Mac. Verify with:

```bash
codesign -dv path/to/binary 2>&1 | grep -E "Signature|flags"
# Should show: Signature=adhoc
```

If you see `code object is not signed at all`, the binary will be blocked at launch.

---

## Critical rules — every one causes silent failure if violated

1. **Unbuffered stdout** — Python: open stdout with `buffering=1`. Swift: `FileHandle.standardOutput.write`. Never use `print()` for MCP messages in Python without flushing.

2. **Stdin isolation for subprocesses** — Any `Process` or `subprocess` you launch MUST redirect stdin away from the MCP pipe:
   - Swift: `proc.standardInput = Pipe()`
   - Python: `subprocess.run([...], stdin=subprocess.DEVNULL, ...)`
   If you forget this, the subprocess inherits the MCP stdin pipe and steals JSON-RPC messages.

3. **SIGPIPE must be ignored** (Swift only) — Add `signal(SIGPIPE, SIG_IGN)` as the first line of `main.swift`. A write to a closed stdout otherwise kills the process silently.

4. **Callbacks before emit** — Call `set_callback` / `setCallback` before `emit_block`. If CloudKit is fast and the user responds before the callback is registered, the response is lost.

5. **Non-blocking stdin read** — Python: use `run_in_executor(None, sys.stdin.buffer.readline)` in a loop. **Never use `connect_read_pipe`** — it only delivers the first message on macOS and silently drops all subsequent ones. Swift: use the GCD-based `stdinLines` pattern. Do not use `readLine()` directly — it blocks the event loop.

6. **read_loop before initialize** — Always `asyncio.create_task(mcp.read_loop())` before `await mcp.initialize()`. If `initialize()` is awaited first, its response can never be dispatched and the script deadlocks.

7. **Tile blocks need a TTL + heartbeat** — If you emit a `tile` block, give it a short TTL (e.g. `ttl=600`) and refresh it every 5 minutes with a background task. Without this, the tile disappears from the iOS home screen after the TTL expires. Example:

```python
async def _heartbeat(mcp):
    while True:
        await asyncio.sleep(300)
        await emit_tile(mcp)   # re-emit with same ttl=600

asyncio.create_task(_heartbeat(mcp))  # start unconditionally, before try/except
```

6. **Scripts run forever** — The daemon expects the process to stay alive. Design a loop with `await asyncio.sleep(interval)` / `try await Task.sleep(...)`. Exit only on unrecoverable errors.

---

## Test mode

Every script must support a test mode activated by `sys.argv[1] == "test"` (or `CommandLine.arguments[1] == "test"`):
- Run the check immediately (no initial wait)
- After the first check cycle completes, sleep for **60 seconds** (giving the user time to see the blocks on iOS), then exit
- Log `[script-name] test mode complete` to stderr

This lets the Mac companion's Settings > Actions test button verify the full MCP + CloudKit + iOS rendering pipeline end-to-end.

---

## What to deliver

1. All files listed under **Required file layout**
2. `manifest.json` with correct `id`, `name`, `icon`, and `entry`
3. Complete script with working MCP client, check loop, all relevant block types, and test mode
4. If Python: make the file executable (`chmod +x main.py`) and set the shebang to `#!/usr/bin/env python3`
5. If Swift: include `Package.swift`, `build.sh` that compiles to a binary named `{id}-bin`, **ad-hoc signs it** (`codesign --sign - --force`), and update `manifest.json` `entry` to point to the binary

After creating the files, run the script in test mode to verify it starts without errors:
```bash
cd ~/.ask/scripts/{script-id}
echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}' | python3 main.py test 2>&1 | head -5
```
(The script will block waiting for more stdin — Ctrl-C after seeing the init log line is fine. The goal is confirming no import errors or syntax issues.)
