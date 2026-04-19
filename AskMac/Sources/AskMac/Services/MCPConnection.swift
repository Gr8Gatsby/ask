import Foundation
import OSLog
#if canImport(AskMacCore)
import AskMacCore
#endif

// MARK: - LiveBlock

/// A block currently emitted by a script, tracked locally for Mac-side preview.
struct LiveBlock: Identifiable, Sendable {
    let id: String          // blockId
    let blockType: String
    let payloadJSON: String
    let createdAt: Date
    let requiresResponse: Bool
    let showsInInbox: Bool
}

// MARK: - MCPConnection

/// Manages a single MCP (JSON-RPC 2.0 over stdio) connection to one script subprocess.
///
/// The script sends tool calls on its stdout; the daemon responds on the script's stdin.
/// The daemon sends `notifications/message` (user_response) on the script's stdin.
final class MCPConnection: @unchecked Sendable {
    let scriptID: String
    private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "MCPConnection")

    /// Called when the script process terminates (crash or clean exit).
    var onTerminate: (() -> Void)?
    /// Called when the script emits a block (after CloudKit write succeeds).
    var onBlockEmitted: (@Sendable (LiveBlock) -> Void)?
    /// Called when the script clears a block.
    var onBlockCleared: (@Sendable (String) -> Void)?
    /// Routes unknown tool calls to system scripts. Returns nil if not handled.
    var systemProxy: ((String, [String: Any]) async -> [String: Any]?)?
    /// Additional tools from system scripts, appended to tools/list responses.
    var systemTools: [[String: Any]] = []
    /// Called for each line written to stderr (live, from the stderr-reading task).
    /// nonisolated(unsafe): set from the main actor, called from the detached stderr task.
    nonisolated(unsafe) var onStderrLine: (@Sendable (String) -> Void)?

    private let entryURL: URL
    private let blockService: BlockService
    private let terminalMonitor: TerminalMonitorService
    private let taskService: TaskService

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    // Rolling buffer of the last 50 stderr lines — used for crash diagnostics.
    // nonisolated(unsafe): written from a detached stderr-reading task, read after
    // process exit from the main actor in ScriptManager.handleCrash. The race is
    // benign — worst case is a slightly stale error message.
    nonisolated(unsafe) private var stderrLines: [String] = []

    // Set to true after the first malformed (non-JSON) line is seen; prevents
    // emitting duplicate warning blocks for the same script run.
    nonisolated(unsafe) private var hasWarnedMalformedJSON = false

    var lastStderrSummary: String {
        stderrLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "Script exited unexpectedly"
    }

    /// All captured stderr lines (up to 50), filtered of blank lines.
    var allStderrLines: [String] {
        stderrLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Exit code and reason captured at termination time.
    private(set) var exitCode: Int32 = 0
    private(set) var exitedBySignal: Bool = false

    init(scriptID: String, entryURL: URL, blockService: BlockService, terminalMonitor: TerminalMonitorService, taskService: TaskService) {
        self.scriptID = scriptID
        self.entryURL = entryURL
        self.blockService = blockService
        self.terminalMonitor = terminalMonitor
        self.taskService = taskService
    }

    // MARK: - Lifecycle

    func start() {
        hasWarnedMalformedJSON = false
        stderrLines = []
        let inPipe = Pipe()
        let outPipe = Pipe()

        let p = Process()
        if entryURL.pathExtension == "py" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", entryURL.path]
        } else {
            p.executableURL = entryURL
        }
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.terminationHandler = { [weak self] proc in
            self?.exitCode = proc.terminationStatus
            self?.exitedBySignal = proc.terminationReason == .uncaughtSignal
            self?.readTask?.cancel()
            self?.stderrTask?.cancel()
            self?.onTerminate?()
        }

        stderrPipe = errPipe

        stdinPipe = inPipe
        stdoutPipe = outPipe
        process = p

        do {
            try p.run()
        } catch {
            logger.error("[MCPConnection:\(self.scriptID)] Launch failed: \(error)")
            onTerminate?()
            return
        }

        readTask = Task.detached { [weak self] in
            guard let self else { return }
            for await line in MCPConnection.lines(from: outPipe.fileHandleForReading) {
                guard !Task.isCancelled else { break }
                await self.handleLine(line)
            }
        }

        stderrTask = Task.detached { [weak self] in
            guard let self else { return }
            for await line in MCPConnection.lines(from: errPipe.fileHandleForReading) {
                guard !Task.isCancelled else { break }
                self.stderrLines.append(line)
                if self.stderrLines.count > 50 { self.stderrLines.removeFirst() }
                self.onStderrLine?(line)
                logger.debug("[MCPConnection:\(self.scriptID)] \(line)")
            }
        }
    }

    func stop() {
        onTerminate = nil  // intentional stop — do not trigger crash handler
        readTask?.cancel()
        stderrTask?.cancel()
        process?.terminate()
        process = nil
    }

    // MARK: - Outbound (daemon → script)

    /// Sends a user_response notification to the script's stdin.
    func deliverResponse(blockID: String, value: String) {
        send([
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": [
                "level": "info",
                "data": [
                    "type": "user_response",
                    "blockId": blockID,
                    "value": value
                ]
            ]
        ])
    }

    /// Sends a chat_message notification to the script's stdin.
    /// Used for free-form chat messages from the iOS session chat view.
    func deliverChatMessage(sessionID: String, messageID: String, text: String) {
        send([
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": [
                "level": "info",
                "data": [
                    "type": "chat_message",
                    "sessionId": sessionID,
                    "messageId": messageID,
                    "text": text
                ]
            ]
        ])
    }

    // MARK: - Inbound (script → daemon)

    private func handleLine(_ line: String) async {
        guard !line.isEmpty else { return }

        // Silently ignore whitespace-only lines (e.g. blank separators from scripts).
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Non-JSON output from the script — warn once per run so the developer
            // knows a line was dropped rather than silently losing it.
            if !hasWarnedMalformedJSON {
                hasWarnedMalformedJSON = true
                let truncated = line.count > 500 ? String(line.prefix(500)) + "…" : line
                logger.debug("[MCPConnection:\(self.scriptID)] Non-JSON line dropped: \(truncated)")
                Task {
                    let payload: [String: Any] = [
                        "title": "\(scriptID): output error",
                        "body": "Script emitted non-JSON output (check logs):\n\(truncated)"
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: payload),
                       let js = String(data: d, encoding: .utf8) {
                        try? await blockService.emitBlock(
                            blockID: "\(scriptID)-malformed-json",
                            blockType: "alert",
                            payload: js,
                            expiresAt: Date().addingTimeInterval(3600)
                        )
                    }
                }
            }
            return
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]

        switch method {
        case "initialize":
            // Clear stale blocks BEFORE replying so the script can't emit new blocks
            // until the old ones are gone. Scripts time out their initialize call at
            // 15 seconds; a CloudKit clear takes 1–3 seconds — well within budget.
            Task {
                try? await blockService.clearAllBlocks()
                reply(id: id, result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: String]()],
                    "serverInfo": ["name": "AskMac", "version": "1.0"]
                ])
            }

        case "notifications/initialized":
            logger.debug("[MCPConnection:\(self.scriptID)] Ready")

        case "tools/list":
            reply(id: id, result: ["tools": toolsList])

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            await dispatchTool(id: id, name: name, args: args)

        default:
            if id != nil {
                replyError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func dispatchTool(id: Any?, name: String, args: [String: Any]) async {
        switch name {
        case "emit_block":
            guard
                let blockID = args["blockId"] as? String,
                let blockType = args["blockType"] as? String,
                let payloadObj = args["payload"],
                let payloadJSON = payloadString(from: payloadObj)
            else {
                replyError(id: id, code: -32602, message: "Invalid arguments for emit_block")
                return
            }
            let ttl = args["ttl"] as? TimeInterval
            let expiresAt = ttl.map { Date().addingTimeInterval($0) }
            let showsInInbox = args["inbox"] as? Bool ?? false
            // Determine if this block needs user input for CloudKit alert push delivery.
            // Only explicit interaction blocks (confirmation, prompts, pickers) trigger push.
            // agent_session blocks do NOT push — they update too frequently and the
            // session tile is not a direct call-to-action.
            let requiresResponse: Bool
            let responseTypes: Set<String> = ["confirmation", "prompt", "chat_prompt", "picker", "list", "detail"]
            if responseTypes.contains(blockType) {
                requiresResponse = true
            } else if blockType == "tile",
                      let payloadDict = args["payload"] as? [String: Any],
                      let actionRequired = payloadDict["action_required"] as? Bool {
                requiresResponse = actionRequired
            } else {
                requiresResponse = false
            }
            // Reply and update local preview immediately — don't block on CloudKit.
            reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
            let block = LiveBlock(
                id: blockID,
                blockType: blockType,
                payloadJSON: payloadJSON,
                createdAt: Date(),
                requiresResponse: requiresResponse,
                showsInInbox: showsInInbox
            )
            onBlockEmitted?(block)
            Task {
                do {
                    try await blockService.emitBlock(
                        blockID: blockID,
                        blockType: blockType,
                        payload: payloadJSON,
                        expiresAt: expiresAt,
                        requiresResponse: requiresResponse,
                        showsInInbox: showsInInbox
                    )
                } catch {
                    logger.error("[MCPConnection:\(self.scriptID)] emit_block CloudKit error: \(error)")
                }
            }

        case "clear_block":
            guard let blockID = args["blockId"] as? String else {
                replyError(id: id, code: -32602, message: "Missing blockId")
                return
            }
            // Reply and update local preview immediately — don't block on CloudKit.
            reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
            onBlockCleared?(blockID)
            Task {
                do {
                    try await blockService.clearBlock(blockID: blockID)
                } catch {
                    logger.error("[MCPConnection:\(self.scriptID)] clear_block CloudKit error: \(error)")
                }
            }

        case "open_task":
            guard let taskID = args["taskId"] as? String,
                  let title  = args["title"] as? String
            else {
                replyError(id: id, code: -32602, message: "open_task requires taskId and title")
                return
            }
            let status = args["status"] as? String ?? "working"
            Task {
                do {
                    try await taskService.openTask(taskID: taskID, title: title, status: status)
                    reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
                } catch {
                    replyError(id: id, code: -32000, message: "open_task failed: \(error.localizedDescription)")
                }
            }

        case "append_message":
            guard let taskID = args["taskId"] as? String,
                  let role   = args["role"] as? String,
                  let parts  = args["parts"] as? [[String: Any]]
            else {
                replyError(id: id, code: -32602, message: "append_message requires taskId, role, and parts")
                return
            }
            Task {
                do {
                    try await taskService.appendMessage(taskID: taskID, role: role, parts: parts)
                    reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
                } catch {
                    replyError(id: id, code: -32000, message: "append_message failed: \(error.localizedDescription)")
                }
            }

        case "put_artifact":
            guard let taskID     = args["taskId"] as? String,
                  let artifactID = args["artifactId"] as? String,
                  let filename   = args["filename"] as? String,
                  let mimeType   = args["mimeType"] as? String
            else {
                replyError(id: id, code: -32602, message: "put_artifact requires taskId, artifactId, filename, and mimeType")
                return
            }
            let description    = args["description"] as? String
            let filePath       = args["filePath"] as? String
            let contentBase64  = args["content"] as? String
            Task {
                do {
                    try await taskService.putArtifact(
                        taskID: taskID,
                        artifactID: artifactID,
                        filename: filename,
                        mimeType: mimeType,
                        description: description,
                        filePath: filePath,
                        contentBase64: contentBase64
                    )
                    reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
                } catch {
                    replyError(id: id, code: -32000, message: "put_artifact failed: \(error.localizedDescription)")
                }
            }

        case "get_schema":
            reply(id: id, result: ["content": [["type": "text", "text": schemaText]]])

        case "list_terminal_sessions":
            let filter = args["filter"] as? String
            Task {
                let sessions = await terminalMonitor.listSessions(filter: filter)
                let sessionDicts = sessions.map { $0.asDictionary }
                reply(id: id, result: ["sessions": sessionDicts])
            }

        default:
            // Try to route through a system script that declares this tool.
            if let proxy = systemProxy,
               let result = await proxy(name, args) {
                reply(id: id, result: result)
            } else {
                replyError(id: id, code: -32601, message: "Unknown tool: \(name)")
            }
        }
    }

    // MARK: - Pipe reading

    /// Reads newline-delimited text from a pipe file descriptor using DispatchSource.
    /// `nonisolated` — safe to call from any Swift concurrency context without
    /// hopping to the main actor (unlike `FileHandle.readabilityHandler`).
    nonisolated private static func lines(from fh: FileHandle) -> AsyncStream<String> {
        // Buffer box defined locally so the compiler cannot infer @MainActor on it.
        // Accessed exclusively from the serial DispatchQueue below — @unchecked Sendable is correct.
        final class Buffer: @unchecked Sendable { var data = Data() }
        let fd = fh.fileDescriptor
        return AsyncStream { continuation in
            let buf = Buffer()
            let queue = DispatchQueue(label: "ask.mcp.pipe-reader", qos: .utility)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let n = Darwin.read(fd, &chunk, chunk.count)
                guard n > 0 else { source.cancel(); return }
                buf.data.append(contentsOf: chunk[..<n])
                while let range = buf.data.range(of: Data([0x0A])) {
                    if let line = String(data: buf.data[buf.data.startIndex..<range.lowerBound], encoding: .utf8) {
                        continuation.yield(line)
                    }
                    buf.data.removeSubrange(buf.data.startIndex...range.lowerBound)
                }
            }
            source.setCancelHandler { continuation.finish() }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }

    // MARK: - JSON-RPC helpers

    private func reply(id: Any?, result: Any) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(id: Any?, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id as Any, "error": ["code": code, "message": message]])
    }

    private func send(_ obj: [String: Any]) {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let bytes = Data((line + "\n").utf8)
        do {
            try pipe.fileHandleForWriting.write(contentsOf: bytes)
        } catch {
            // Script process has exited; the termination callback will handle cleanup.
        }
    }

    // MARK: - Payload serialisation

    /// Serialises `object` to a JSON string, decoding any UTF-16 surrogate pairs that
    /// `JSONSerialization` emits for emoji (e.g. `\uD83C\uDF55` → 🍕) so that the raw
    /// UTF-8 characters are stored in CloudKit instead of escape sequences.
    private func payloadString(from object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeSurrogatePairs(in: json)
    }

    private func decodeSurrogatePairs(in json: String) -> String {
        // High surrogate: U+D800–U+DBFF  →  \uD[89AB]xx
        // Low  surrogate: U+DC00–U+DFFF  →  \uD[CDEF]xx
        let pattern = #"\\u([Dd][89AaBb][0-9A-Fa-f]{2})\\u([Dd][CcDdEeFf][0-9A-Fa-f]{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }

        var result = json
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Iterate in reverse so replacement doesn't shift earlier match ranges.
        for match in matches.reversed() {
            guard let highRange = Range(match.range(at: 1), in: result),
                  let lowRange  = Range(match.range(at: 2), in: result),
                  let highCode  = UInt32(result[highRange], radix: 16),
                  let lowCode   = UInt32(result[lowRange],  radix: 16),
                  let fullRange = Range(match.range, in: result)
            else { continue }

            let codePoint = 0x10000 + (highCode - 0xD800) * 0x400 + (lowCode - 0xDC00)
            guard let scalar = Unicode.Scalar(codePoint) else { continue }
            result.replaceSubrange(fullRange, with: String(scalar))
        }

        return result
    }

    // MARK: - Static data

    private var toolsList: [[String: Any]] {
        builtInToolsList + systemTools
    }

    private var builtInToolsList: [[String: Any]] {
        [
            [
                "name": "emit_block",
                "description": "Display a UI block on the connected iOS device",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "blockId": ["type": "string", "description": "Unique block identifier (use UUID)"],
                        "blockType": ["type": "string", "enum": ["confirmation", "alert", "status", "prompt", "info_card", "chat_prompt", "icon_card", "agent_session", "claude_message"]],
                        "payload": ["type": "object", "description": "Block-type-specific payload — see get_schema"],
                        "ttl": ["type": "number", "description": "Seconds until the block auto-expires (optional)"]
                    ],
                    "required": ["blockId", "blockType", "payload"]
                ]
            ],
            [
                "name": "clear_block",
                "description": "Remove a UI block from the iOS device",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "blockId": ["type": "string"]
                    ],
                    "required": ["blockId"]
                ]
            ],
            [
                "name": "get_schema",
                "description": "Get payload schemas for all block types",
                "inputSchema": ["type": "object", "properties": [String: String]()]
            ],
            [
                "name": "list_terminal_sessions",
                "description": "List interactive terminal sessions on this Mac. Returns pid, name, tty, cwd, and tab_title (if available) for each session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "filter": ["type": "string", "description": "Optional process name filter (case-insensitive substring, e.g. \"claude\" or \"codex\")"]
                    ]
                ]
            ],
            [
                "name": "open_task",
                "description": "Create or update a task in the A2A task history. Call once at the start of a job and again on status changes (e.g. working → completed).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "taskId": ["type": "string", "description": "Stable task identifier (use UUID; same ID reopens the existing task)"],
                        "title": ["type": "string", "description": "Human-readable task title shown in the iOS task list"],
                        "status": ["type": "string", "enum": ["working", "completed", "failed", "cancelled"], "description": "Task status (default: working)"]
                    ],
                    "required": ["taskId", "title"]
                ]
            ],
            [
                "name": "append_message",
                "description": "Append a message (assistant or user turn) to a task's conversation history.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "taskId": ["type": "string", "description": "Task ID from open_task"],
                        "role": ["type": "string", "enum": ["assistant", "user"], "description": "Message author"],
                        "parts": [
                            "type": "array",
                            "description": "Message content parts",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "type": ["type": "string", "enum": ["text", "file", "data"]],
                                    "text": ["type": "string", "description": "For type=text"],
                                    "mimeType": ["type": "string", "description": "For type=file/data"],
                                    "uri": ["type": "string", "description": "For type=file"],
                                    "data": ["type": "string", "description": "For type=data (base64)"]
                                ],
                                "required": ["type"]
                            ]
                        ]
                    ],
                    "required": ["taskId", "role", "parts"]
                ]
            ],
            [
                "name": "put_artifact",
                "description": "Attach a file artifact to a task. Use filePath (preferred) for files on disk, or content (base64, max 10 MB) for in-memory data.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "taskId": ["type": "string", "description": "Task ID from open_task"],
                        "artifactId": ["type": "string", "description": "Stable artifact identifier (use UUID; same ID replaces the existing artifact)"],
                        "filename": ["type": "string", "description": "Display filename (e.g. report.pdf)"],
                        "mimeType": ["type": "string", "description": "MIME type (e.g. application/pdf, image/png)"],
                        "description": ["type": "string", "description": "Optional human-readable description"],
                        "filePath": ["type": "string", "description": "Absolute path to the file on disk (preferred — AskMac reads the file directly)"],
                        "content": ["type": "string", "description": "Base64-encoded file content (max 10 MB decoded). Use filePath for larger files."]
                    ],
                    "required": ["taskId", "artifactId", "filename", "mimeType"]
                ]
            ]
        ]
    }

    private var schemaText: String {
        """
        Block payload schemas:

        confirmation  {"title":string, "body":string, "options":[string]}
        alert         {"title":string, "body":string, "icon":string?}
        status        {"label":string, "detail":string?, "icon":string?, "color":"green"|"blue"|"orange"|"red"|"yellow"}
        prompt        {"title":string, "placeholder":string?, "multiline":bool?}
        chat_prompt   {"title":string, "context":string?, "placeholder":string?}
        info_card     {"title":string, "pairs":[{"key":string,"value":string}]}
        icon_card     {"title":string, "subtitle":string?}
        list          {"title":string?, "items":[{"id":string,"label":string,"subtitle":string?}], "actions":[string]?}
        detail        {"title":string, "body":string, "actions":[string]?}
        countdown     {"label":string, "time":string (ISO 8601 UTC)}
        tile          {"label":string, "body":string?, "status_color":string?, "action_required":bool?}
        picker        {"title":string, "options":[string], "selected":string?}

        list: items respond with item.id; actions respond with the action string.
        detail: shown as a full-screen pushed view with Markdown rendering. Close button
          sends "dismissed". Use actions[] only for non-dismiss interactions.
        tile: drives the home-screen tile only; not shown in script detail view.
        emit_block also accepts top-level argument:
          inbox        bool?  when true, this block appears in the iOS bell menu.

        User responses are delivered as notifications/message with:
          data.type == "user_response", data.blockId, data.value
        """
    }
}
