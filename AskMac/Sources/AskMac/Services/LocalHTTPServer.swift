import Foundation
import Network

// MARK: - LocalHTTPServer

/// A minimal HTTP server on localhost that lets the MockAskMac web UI
/// connect to AskMac directly — the same block state that goes to CloudKit,
/// served over a local socket so the dev UI needs no CloudKit auth.
///
/// Endpoints:
///   GET  /blocks            → JSON array of all currently active blocks
///   GET  /events            → SSE stream: block_added / block_updated / block_cleared
///   POST /respond/:blockID  → route a user response value to the owning script
@MainActor
final class LocalHTTPServer {

    // MARK: - Public interface called by ScriptManager

    /// In-memory task store: tasks keyed by taskID, messages keyed by taskID, artifacts keyed by taskID.
    private var localTasks: [String: [String: Any]] = [:]
    private var localMessages: [String: [[String: Any]]] = [:]
    private var localArtifacts: [String: [[String: Any]]] = [:]
    /// CKAsset local file URLs keyed by artifactID — used to serve /artifacts/:id/content.
    private var artifactFileURLs: [String: URL] = [:]

    func notifyTaskUpserted(_ task: AskTaskRecord) {
        let fmt = ISO8601DateFormatter()
        localTasks[task.taskID] = [
            "taskID":         task.taskID,
            "machineID":      task.machineID,
            "scriptID":       task.scriptID,
            "scriptName":     task.scriptName,
            "title":          task.title,
            "status":         task.status,
            "lastActivityAt": fmt.string(from: task.lastActivityAt),
            "messageCount":   task.messageCount,
            "artifactCount":  task.artifactCount,
        ]
    }

    func notifyMessageAppended(_ msg: AskTaskMessageRecord) {
        let fmt = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "messageID":      msg.messageID,
            "taskID":         msg.taskID,
            "role":           msg.role,
            "partsJSON":      msg.partsJSON,
            "timestamp":      fmt.string(from: msg.timestamp),
            "sequenceNumber": msg.sequenceNumber,
        ]
        localMessages[msg.taskID, default: []].append(entry)
    }

    /// Seeds historical tasks from CloudKit without overwriting any tasks already seen live.
    func seedTasksFromCloudKit(_ tasks: [AskTaskRecord]) {
        let fmt = ISO8601DateFormatter()
        var seeded = 0
        for task in tasks {
            guard localTasks[task.taskID] == nil else { continue }
            localTasks[task.taskID] = [
                "taskID":         task.taskID,
                "machineID":      task.machineID,
                "scriptID":       task.scriptID,
                "scriptName":     task.scriptName,
                "title":          task.title,
                "status":         task.status,
                "lastActivityAt": fmt.string(from: task.lastActivityAt),
                "messageCount":   task.messageCount,
                "artifactCount":  task.artifactCount,
            ]
            seeded += 1
        }
        print("[LocalHTTPServer] seeded \(seeded) task(s) from CloudKit")
    }

    /// Call after every activeBlocks mutation so SSE clients stay in sync.
    func notifyBlockAdded(block: LiveBlock, scriptID: String, scriptName: String, scriptIconSVG: String?, scriptType: String, machineID: String) {
        ckSeedBlocks.removeValue(forKey: block.id)  // live data supersedes seed
        let serialised = serialiseBlock(block: block, scriptID: scriptID, scriptName: scriptName, scriptIconSVG: scriptIconSVG, scriptType: scriptType, machineID: machineID)
        broadcast(event: "block_added", data: serialised)
    }

    func notifyBlockUpdated(block: LiveBlock, scriptID: String, scriptName: String, scriptIconSVG: String?, scriptType: String, machineID: String) {
        ckSeedBlocks.removeValue(forKey: block.id)  // live data supersedes seed
        let serialised = serialiseBlock(block: block, scriptID: scriptID, scriptName: scriptName, scriptIconSVG: scriptIconSVG, scriptType: scriptType, machineID: machineID)
        broadcast(event: "block_updated", data: serialised)
    }

    func notifyBlockCleared(blockID: String) {
        ckSeedBlocks.removeValue(forKey: blockID)
        broadcast(event: "block_cleared", data: #"{"blockID":"\#(blockID)"}"#)
    }

    /// Called once after start() — fills ckSeedBlocks from CloudKit so blocks
    /// persisted before this AskMac session are immediately visible.
    func seedFromCloudKit(_ records: [[String: Any]]) {
        for dict in records {
            guard let blockID = dict["blockID"] as? String else { continue }
            // Don't overwrite blocks already received live
            if let sm = scriptManager,
               sm.scriptID(forBlockID: blockID) != nil { continue }
            ckSeedBlocks[blockID] = dict
        }
        print("[LocalHTTPServer] seeded \(ckSeedBlocks.count) block(s) from CloudKit")
    }

    // MARK: - Init & start

    private weak var scriptManager: ScriptManager?
    private var cloudKitService: CloudKitService?
    private var cloudKitMachineID: String = ""
    private var listener: NWListener?
    private var sseConnections: [NWConnection] = []
    private let port: UInt16
    private var machineName: String = ""

    /// Blocks seeded from CloudKit on startup — fills the gap until scripts re-emit live.
    /// Keyed by blockID. Entries are evicted when a live activeBlocks update arrives for the same blockID.
    private var ckSeedBlocks: [String: [String: Any]] = [:]

    init(port: UInt16 = 4242) {
        self.port = port
    }

    func configure(scriptManager: ScriptManager, machineName: String, cloudKit: CloudKitService? = nil, machineID: String = "") {
        self.scriptManager = scriptManager
        self.machineName = machineName
        self.cloudKitService = cloudKit
        self.cloudKitMachineID = machineID
    }

    func start() {
        attemptBind(retriesLeft: 10)
    }

    private func attemptBind(retriesLeft: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let p = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: p) else {
            if retriesLeft > 0 {
                print("[LocalHTTPServer] Port \(port) busy, retrying in 2s (\(retriesLeft) left)…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(2))
                    self.attemptBind(retriesLeft: retriesLeft - 1)
                }
            } else {
                print("[LocalHTTPServer] Failed to bind port \(port) after all retries")
            }
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state {
                print("[LocalHTTPServer] Listening on http://localhost:\(self.port)")
            }
            if case .failed = state {
                // Port lost (e.g. another process grabbed it) — retry
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.listener = nil
                    try? await Task.sleep(for: .seconds(2))
                    self.attemptBind(retriesLeft: 5)
                }
            }
        }
        listener.start(queue: .main)
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            Task { @MainActor [weak self] in await self?.handle(data: data, conn: conn) }
        }
    }

    private func handle(data: Data, conn: NWConnection) async {
        guard let raw = String(data: data, encoding: .utf8) else { conn.cancel(); return }

        // Parse request line
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let fullPath = parts[1]

        // Strip query string
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        // CORS preflight
        if method == "OPTIONS" {
            send(conn: conn, status: "204 No Content", extraHeaders: corsHeaders(), body: "")
            return
        }

        if method == "GET" && path == "/debug" {
            var info: [String: Any] = [:]
            if let sm = scriptManager {
                var ab: [String: [String]] = [:]
                for (sid, byID) in sm.activeBlocks { ab[sid] = Array(byID.keys) }
                info["activeBlocks"] = ab
                info["ckSeedBlockIDs"] = Array(ckSeedBlocks.keys)
            } else {
                info["error"] = "no scriptManager"
            }
            let data = (try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)) ?? Data()
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        if method == "GET" && path == "/blocks" {
            let json = blocksPayload()
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: json)
            return
        }

        if method == "GET" && path == "/events" {
            // Keep connection alive for SSE
            let headerLines = (corsHeaders() + [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-cache"),
                ("Connection", "keep-alive"),
            ]).map { "\($0.0): \($0.1)" }.joined(separator: "\r\n")
            let response = "HTTP/1.1 200 OK\r\n\(headerLines)\r\n\r\n: connected\r\n\r\n"
            conn.send(content: Data(response.utf8), completion: .idempotent)
            sseConnections.append(conn)
            conn.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state {
                    Task { @MainActor [weak self] in
                        self?.sseConnections.removeAll { $0 === conn }
                    }
                }
                if case .failed = state {
                    Task { @MainActor [weak self] in
                        self?.sseConnections.removeAll { $0 === conn }
                    }
                }
            }
            return
        }

        if method == "GET" && path == "/machines" {
            let machineID = scriptManager?.machineIDPublic ?? ""
            let status = (scriptManager?.scripts.contains { $0.status == .running } ?? false) ? "busy" : "idle"
            let dict: [String: Any] = [
                "machineID": machineID,
                "name": machineName.isEmpty ? "My Mac" : machineName,
                "platform": "macOS",
                "lastHeartbeat": ISO8601DateFormatter().string(from: Date()),
                "status": status,
            ]
            let wrapper: [String: Any] = ["machines": [dict]]
            let data = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? #"{"machines":[]}"#
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: json)
            return
        }

        if method == "GET" && path == "/tasks" {
            let tasks = Array(localTasks.values).sorted {
                ($0["lastActivityAt"] as? String ?? "") > ($1["lastActivityAt"] as? String ?? "")
            }
            let wrapper = ["tasks": tasks]
            let data = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: String(data: data, encoding: .utf8) ?? #"{"tasks":[]}"#)
            return
        }

        if method == "GET" && path.hasPrefix("/tasks/") && path.hasSuffix("/messages") {
            let taskID = String(path.dropFirst("/tasks/".count).dropLast("/messages".count))
            var messages = localMessages[taskID] ?? []
            // On-demand CloudKit fetch when not cached locally
            if messages.isEmpty, let ck = cloudKitService, !cloudKitMachineID.isEmpty {
                let fetched = await ck.fetchTaskMessagesAsJSON(taskID: taskID, machineID: cloudKitMachineID)
                if !fetched.isEmpty {
                    localMessages[taskID] = fetched
                    messages = fetched
                }
            }
            let sorted = messages.sorted {
                ($0["sequenceNumber"] as? Int ?? 0) < ($1["sequenceNumber"] as? Int ?? 0)
            }
            let wrapper = ["messages": sorted]
            let msgData = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: String(data: msgData, encoding: .utf8) ?? #"{"messages":[]}"#)
            return
        }

        if method == "GET" && path.hasPrefix("/tasks/") && path.hasSuffix("/artifacts") {
            let taskID = String(path.dropFirst("/tasks/".count).dropLast("/artifacts".count))
            var artifacts = localArtifacts[taskID] ?? []
            // On-demand CloudKit fetch when not cached locally
            if artifacts.isEmpty, let ck = cloudKitService, !cloudKitMachineID.isEmpty {
                let (fetched, urls) = await ck.fetchTaskArtifactsAsJSON(taskID: taskID, machineID: cloudKitMachineID)
                if !fetched.isEmpty {
                    localArtifacts[taskID] = fetched
                    for (aid, url) in urls { artifactFileURLs[aid] = url }
                    artifacts = fetched
                }
            }
            let wrapper = ["artifacts": artifacts]
            let artData = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: String(data: artData, encoding: .utf8) ?? #"{"artifacts":[]}"#)
            return
        }

        if method == "GET" && path.hasPrefix("/artifacts/") && path.hasSuffix("/content") {
            let artifactID = String(path.dropFirst("/artifacts/".count).dropLast("/content".count))
            guard let fileURL = artifactFileURLs[artifactID],
                  let content = try? Data(contentsOf: fileURL) else {
                send(conn: conn, status: "404 Not Found", extraHeaders: corsHeaders(), body: "Not found")
                return
            }
            let mimeType = localArtifacts.values
                .flatMap { $0 }
                .first { $0["artifactID"] as? String == artifactID }?["mimeType"] as? String
                ?? "application/octet-stream"
            sendData(conn: conn, status: "200 OK",
                     extraHeaders: corsHeaders() + [("Content-Type", mimeType)],
                     body: content)
            return
        }

        if method == "POST", path.hasPrefix("/respond/") {
            let blockID = String(path.dropFirst("/respond/".count))
            // Extract "value" from the JSON body. Locate the JSON object directly
            // in the raw request (handles both Content-Length and chunked encoding
            // from the Vite proxy without needing to fully parse HTTP framing).
            var value = ""
            if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
               start <= end {
                let jsonStr = String(raw[start...end])
                if let bodyData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    value = json["value"] as? String ?? ""
                }
            }
            // Find scriptID by looking up blockID in activeBlocks
            if let sm = scriptManager {
                if let scriptID = sm.scriptID(forBlockID: blockID) {
                    print("[LocalHTTPServer] respond blockID=\(blockID) scriptID=\(scriptID) value=\(value.prefix(60))")
                    sm.respondToBlock(scriptID: scriptID, blockID: blockID, value: value)
                } else {
                    print("[LocalHTTPServer] respond: blockID \(blockID) not found in activeBlocks")
                }
            }
            send(conn: conn, status: "200 OK",
                 extraHeaders: corsHeaders() + [("Content-Type", "application/json")],
                 body: #"{"ok":true}"#)
            return
        }

        send(conn: conn, status: "404 Not Found", extraHeaders: corsHeaders(), body: "Not found")
    }

    // MARK: - Helpers

    private func send(conn: NWConnection, status: String, extraHeaders: [(String, String)], body: String) {
        sendData(conn: conn, status: status, extraHeaders: extraHeaders, body: Data(body.utf8))
    }

    private func sendData(conn: NWConnection, status: String, extraHeaders: [(String, String)], body: Data) {
        let headerLines = (extraHeaders + [("Content-Length", "\(body.count)")]).map { "\($0.0): \($0.1)" }.joined(separator: "\r\n")
        let response = "HTTP/1.1 \(status)\r\n\(headerLines)\r\n\r\n"
        var full = Data(response.utf8)
        full.append(body)
        conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Headers", "Content-Type"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ]
    }

    private func broadcast(event: String, data: String) {
        let payload = Data("event: \(event)\ndata: \(data)\n\n".utf8)
        sseConnections = sseConnections.filter { conn in
            conn.state == .ready || conn.state == .preparing
        }
        for conn in sseConnections {
            conn.send(content: payload, completion: .idempotent)
        }
    }

    // MARK: - Block serialisation

    private func serialiseBlock(block: LiveBlock, scriptID: String, scriptName: String, scriptIconSVG: String?, scriptType: String, machineID: String) -> String {
        let fmt = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "blockID":         block.id,
            "machineID":       machineID,
            "scriptID":        scriptID,
            "scriptName":      scriptName,
            "blockType":       block.blockType,
            "scriptType":      scriptType,
            "createdAt":       fmt.string(from: block.createdAt),
            "requiresResponse": block.requiresResponse ? 1 : 0,
            "showsInInbox":    block.showsInInbox ? 1 : 0,
            "payload":         block.payloadJSON,
        ]
        if let svg = scriptIconSVG { dict["scriptIconSVG"] = svg }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func blocksPayload() -> String {
        guard let sm = scriptManager else { return #"{"blocks":[]}"# }
        var all: [Any] = []
        let fmt = ISO8601DateFormatter()

        // Live activeBlocks (always authoritative)
        var liveBlockIDs = Set<String>()
        for (scriptID, blocksByID) in sm.activeBlocks {
            let script = sm.scripts.first(where: { $0.id == scriptID })
            for (_, block) in blocksByID {
                liveBlockIDs.insert(block.id)
                var dict: [String: Any] = [
                    "blockID":          block.id,
                    "machineID":        sm.machineIDPublic,
                    "scriptID":         scriptID,
                    "scriptName":       script?.name ?? scriptID,
                    "blockType":        block.blockType,
                    "scriptType":       script?.scriptType ?? "tile",
                    "createdAt":        fmt.string(from: block.createdAt),
                    "requiresResponse": block.requiresResponse ? 1 : 0,
                    "showsInInbox":     block.showsInInbox ? 1 : 0,
                    "payload":          block.payloadJSON,
                ]
                if let svg = script?.svgString { dict["scriptIconSVG"] = svg }
                all.append(dict)
            }
        }

        // CloudKit-seeded blocks for any blockID not already covered by live data
        for (blockID, dict) in ckSeedBlocks where !liveBlockIDs.contains(blockID) {
            all.append(dict)
        }

        let wrapper = ["blocks": all]
        let data = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"blocks":[]}"#
    }
}
