import Foundation

// MARK: - Error

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

// MARK: - MCPClient

/// Actor-based JSON-RPC 2.0 client over stdio.
/// Reads from stdin, writes to stdout, manages pending RPCs and response callbacks.
actor MCPClient {
    private var nextID = 0
    private var pending:         [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]
    private var responseCbs:     [String: @Sendable (String) async -> Void] = [:]
    private var pipeBroken = false

    // MARK: - Low-level send

    /// Serialise `obj` as a single JSON line on stdout.
    /// `nonisolated` so it can be called from the `withCheckedThrowingContinuation` body
    /// without re-entering the actor (the actor is already suspended at that point).
    nonisolated func rawSend(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        // FileHandle.write is synchronous; SIGPIPE is ignored in main.swift.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    // MARK: - RPC

    func rpc(
        _ method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval = 60
    ) async throws -> [String: Any] {
        guard !pipeBroken else { throw MCPError.pipeBroken }

        let id = nextID
        nextID += 1

        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        rawSend(msg)

        return try await withCheckedThrowingContinuation { cont in
            // Body runs synchronously on the actor's executor (Swift 5.7+).
            pending[id] = cont
            let t = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self.expireRPC(id: id)
                } catch { /* cancelled — response arrived first */ }
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

    // MARK: - MCP helpers

    func initialize() async throws {
        _ = try await rpc("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "brew-monitor", "version": "2.0"]
        ], timeout: 15)
        rawSend(["jsonrpc": "2.0", "method": "notifications/initialized"])
        fputs("[brew-monitor] MCP initialized\n", stderr)
    }

    func emitBlock(
        _ blockID: String,
        type: String,
        payload: [String: Any],
        ttl: TimeInterval? = nil
    ) async throws {
        var args: [String: Any] = [
            "blockId":   blockID,
            "blockType": type,
            "payload":   payload
        ]
        if let ttl { args["ttl"] = ttl }
        _ = try await rpc("tools/call", params: ["name": "emit_block", "arguments": args])
    }

    func clearBlock(_ blockID: String) async {
        _ = try? await rpc(
            "tools/call",
            params: ["name": "clear_block", "arguments": ["blockId": blockID]],
            timeout: 30
        )
    }

    func setCallback(blockID: String, _ cb: @escaping @Sendable (String) async -> Void) {
        responseCbs[blockID] = cb
    }

    // MARK: - Inbound

    /// Reads stdin line-by-line and dispatches each JSON-RPC message.
    /// Uses GCD readabilityHandler so no cooperative thread is blocked waiting for pipe data.
    nonisolated func readLoop() async {
        let fh = FileHandle.standardInput
        for await line in MCPClient.stdinLines(fh) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            await dispatch(json)
        }
        fputs("[brew-monitor] stdin closed\n", stderr)
    }

    private static func stdinLines(_ fh: FileHandle) -> AsyncStream<String> {
        final class State: @unchecked Sendable { var buffer = Data() }
        let state = State()
        return AsyncStream { continuation in
            fh.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                state.buffer.append(chunk)
                while let range = state.buffer.range(of: Data([0x0A])) {
                    if let line = String(data: state.buffer[state.buffer.startIndex..<range.lowerBound], encoding: .utf8) {
                        continuation.yield(line)
                    }
                    state.buffer.removeSubrange(state.buffer.startIndex...range.lowerBound)
                }
            }
            continuation.onTermination = { _ in fh.readabilityHandler = nil }
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        // Numeric IDs come back as NSNumber; cast to Int.
        let rpcID = (msg["id"] as? NSNumber)?.intValue

        if let id = rpcID, let result = msg["result"] as? [String: Any] {
            fulfill(id: id, result: result)
            return
        }

        if let id = rpcID, let error = msg["error"] {
            fail(id: id, error: MCPError.rpcError(String(describing: error)))
            return
        }

        if msg["method"] as? String == "notifications/message" {
            let data = (msg["params"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
            guard data["type"] as? String == "user_response" else { return }
            let blockID = data["blockId"] as? String ?? ""
            let value   = data["value"]   as? String ?? ""
            if let cb = responseCbs.removeValue(forKey: blockID) {
                Task { await cb(value) }
            }
        }
    }
}
