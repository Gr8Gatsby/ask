import Foundation
import os

/// Manages a JSON-RPC 2.0 connection to a **system** script subprocess.
///
/// Unlike `MCPConnection` (where the script calls the daemon's tools),
/// `SystemScriptConnection` is the *caller* — it sends `tools/call` requests
/// to the system script and awaits responses. This lets tile/feed scripts
/// call system script tools as if they were built-in AskMac tools.
final class SystemScriptConnection: @unchecked Sendable {
    let scriptID: String

    /// Called on the main queue when the process exits.
    var onTerminate: (() -> Void)?

    private let entryURL: URL
    private var process: Process?
    private var stdinPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    // Pending RPC calls — keyed by request ID.
    // OSAllocatedUnfairLock is async-safe (unlike NSLock).
    private struct SyncState {
        var nextID = 0
        var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    }
    private let sync = OSAllocatedUnfairLock(initialState: SyncState())

    init(scriptID: String, entryURL: URL) {
        self.scriptID = scriptID
        self.entryURL = entryURL
    }

    // MARK: - Lifecycle

    func start() {
        let inPipe  = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        let p = Process()
        if entryURL.pathExtension == "py" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", entryURL.path]
        } else {
            p.executableURL = entryURL
        }
        p.standardInput  = inPipe
        p.standardOutput = outPipe
        p.standardError  = errPipe
        p.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        stdinPipe = inPipe
        process   = p

        do {
            try p.run()
        } catch {
            print("[SystemScript:\(scriptID)] Launch failed: \(error)")
            onTerminate?()
            return
        }

        readTask = Task.detached { [weak self] in
            guard let self else { return }
            for await line in SystemScriptConnection.pipeLines(from: outPipe.fileHandleForReading) {
                guard !Task.isCancelled else { break }
                self.handleLine(line)
            }
        }

        stderrTask = Task.detached { [weak self] in
            guard let self else { return }
            for await line in SystemScriptConnection.pipeLines(from: errPipe.fileHandleForReading) {
                guard !Task.isCancelled else { break }
                print("[SystemScript:\(self.scriptID)] \(line)")
            }
        }

        print("[SystemScript:\(scriptID)] Started")
    }

    func stop() {
        readTask?.cancel()
        stderrTask?.cancel()
        process?.terminate()
        process = nil
        // Fail all pending calls immediately
        failAllPending(reason: "System script stopped")
    }

    // MARK: - Tool calls

    /// Send a `tools/call` request to the system script and await the result.
    func callTool(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        let id = sync.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }

        return try await withCheckedThrowingContinuation { cont in
            sync.withLock { $0.pending[id] = cont }
            send([
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": ["name": name, "arguments": args],
            ])
        }
    }

    // MARK: - Response handling

    private func handleLine(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // JSON numbers deserialise as Double — normalise to Int.
        let id: Int
        if let i = json["id"] as? Int       { id = i }
        else if let d = json["id"] as? Double { id = Int(d) }
        else { return }

        let cont = sync.withLock { $0.pending.removeValue(forKey: id) }
        guard let cont else { return }

        if let result = json["result"] as? [String: Any] {
            cont.resume(returning: result)
        } else if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "System script error"
            cont.resume(throwing: NSError(
                domain: "SystemScriptConnection", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))
        } else {
            // Malformed response — resume with empty dict rather than hanging.
            cont.resume(returning: [:])
        }
    }

    private func handleTermination() {
        failAllPending(reason: "System script terminated")
        DispatchQueue.main.async { [weak self] in
            self?.onTerminate?()
        }
        print("[SystemScript:\(scriptID)] Terminated")
    }

    private func failAllPending(reason: String) {
        let all = sync.withLock { state -> [Int: CheckedContinuation<[String: Any], Error>] in
            let p = state.pending
            state.pending = [:]
            return p
        }
        let err = NSError(
            domain: "SystemScriptConnection", code: -2,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
        for cont in all.values { cont.resume(throwing: err) }
    }

    // MARK: - I/O

    private func send(_ obj: [String: Any]) {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        pipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Reads newline-delimited text from a pipe file descriptor using DispatchSource.
    /// Mirrors `MCPConnection.lines(from:)`.
    nonisolated static func pipeLines(from fh: FileHandle) -> AsyncStream<String> {
        final class Buffer: @unchecked Sendable { var data = Data() }
        let fd = fh.fileDescriptor
        return AsyncStream { continuation in
            let buf   = Buffer()
            let queue = DispatchQueue(label: "ask.system.pipe-reader.\(fd)", qos: .utility)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let n = Darwin.read(fd, &chunk, chunk.count)
                guard n > 0 else { source.cancel(); return }
                buf.data.append(contentsOf: chunk[..<n])
                while let range = buf.data.range(of: Data([0x0A])) {
                    if let line = String(
                        data: buf.data[buf.data.startIndex..<range.lowerBound],
                        encoding: .utf8
                    ) { continuation.yield(line) }
                    buf.data.removeSubrange(buf.data.startIndex...range.lowerBound)
                }
            }
            source.setCancelHandler { continuation.finish() }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
