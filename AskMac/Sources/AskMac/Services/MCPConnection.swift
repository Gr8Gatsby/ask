import Foundation

/// Manages a single MCP (JSON-RPC 2.0 over stdio) connection to one script subprocess.
///
/// The script sends tool calls on its stdout; the daemon responds on the script's stdin.
/// The daemon sends `notifications/message` (user_response) on the script's stdin.
final class MCPConnection: @unchecked Sendable {
    let scriptID: String

    /// Called when the script process terminates (crash or clean exit).
    var onTerminate: (() -> Void)?

    private let entryURL: URL
    private let blockService: BlockService

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readTask: Task<Void, Never>?

    init(scriptID: String, entryURL: URL, blockService: BlockService) {
        self.scriptID = scriptID
        self.entryURL = entryURL
        self.blockService = blockService
    }

    // MARK: - Lifecycle

    func start() {
        let inPipe = Pipe()
        let outPipe = Pipe()

        let p = Process()
        if entryURL.pathExtension == "py" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", entryURL.path]
        } else {
            p.executableURL = entryURL
        }
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        p.terminationHandler = { [weak self] _ in
            self?.readTask?.cancel()
            self?.onTerminate?()
        }

        stdinPipe = inPipe
        stdoutPipe = outPipe
        process = p

        do {
            try p.run()
        } catch {
            print("[MCPConnection:\(scriptID)] Launch failed: \(error)")
            onTerminate?()
            return
        }

        readTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in outPipe.fileHandleForReading.bytes.lines {
                    guard !Task.isCancelled else { break }
                    await self.handleLine(line)
                }
            } catch {
                // EOF — process exited
            }
        }
    }

    func stop() {
        readTask?.cancel()
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

    // MARK: - Inbound (script → daemon)

    private func handleLine(_ line: String) async {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let method = json["method"] as? String ?? ""
        let id = json["id"]

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: String]()],
                "serverInfo": ["name": "AskMac", "version": "1.0"]
            ])

        case "notifications/initialized":
            print("[MCPConnection:\(scriptID)] Ready")

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
                let payloadData = try? JSONSerialization.data(withJSONObject: payloadObj),
                let payloadJSON = String(data: payloadData, encoding: .utf8)
            else {
                replyError(id: id, code: -32602, message: "Invalid arguments for emit_block")
                return
            }
            let ttl = args["ttl"] as? TimeInterval
            let expiresAt = ttl.map { Date().addingTimeInterval($0) }
            do {
                try await blockService.emitBlock(
                    blockID: blockID,
                    blockType: blockType,
                    payload: payloadJSON,
                    expiresAt: expiresAt
                )
                reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
            } catch {
                replyError(id: id, code: -32000, message: "emit_block failed: \(error)")
            }

        case "clear_block":
            guard let blockID = args["blockId"] as? String else {
                replyError(id: id, code: -32602, message: "Missing blockId")
                return
            }
            do {
                try await blockService.clearBlock(blockID: blockID)
                reply(id: id, result: ["content": [["type": "text", "text": "ok"]]])
            } catch {
                replyError(id: id, code: -32000, message: "clear_block failed: \(error)")
            }

        case "get_schema":
            reply(id: id, result: ["content": [["type": "text", "text": schemaText]]])

        default:
            replyError(id: id, code: -32601, message: "Unknown tool: \(name)")
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
        pipe.fileHandleForWriting.write(bytes)
    }

    // MARK: - Static data

    private var toolsList: [[String: Any]] {
        [
            [
                "name": "emit_block",
                "description": "Display a UI block on the connected iOS device",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "blockId": ["type": "string", "description": "Unique block identifier (use UUID)"],
                        "blockType": ["type": "string", "enum": ["confirmation", "alert", "status", "prompt", "info_card"]],
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
        info_card     {"title":string, "pairs":[{"key":string,"value":string}]}

        User responses are delivered as notifications/message with:
          data.type == "user_response", data.blockId, data.value
        """
    }
}
