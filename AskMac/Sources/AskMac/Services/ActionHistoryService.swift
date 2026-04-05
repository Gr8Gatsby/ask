import Foundation
import Observation

// MARK: - Model

enum HistoryEventKind: String, Codable, Sendable {
    case blockResponse      // user responded to an iOS block
    case scriptEnabled      // script enabled in Settings
    case scriptDisabled     // script disabled in Settings
    case scriptCrashed      // script crashed unexpectedly
    case scriptStarted      // script launched/restarted successfully
    case dependencyMissing  // dependency check failed at launch
    case blockEmitted       // script emitted a block to CloudKit
}

struct HistoryEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String              // UUID
    let timestamp: Date
    let kind: HistoryEventKind
    let source: String          // script name
    let summary: String         // one-line human description
    let detail: String?         // multi-line detail (stderr, prompt, etc.)

    // Crash diagnostics — nil for non-crash events
    let exitCode: Int32?
    let exitedBySignal: Bool?
    let stderrTail: String?     // last N stderr lines joined with \n

    // Block event metadata — nil for non-block events
    let blockID: String?
    let blockType: String?
    /// The title/prompt shown to the user (from the block payload, e.g. "Allow bash command?")
    let blockTitle: String?
    /// The options presented to the user, comma-separated (e.g. "Allow, Deny, Allow Always")
    let blockOptions: String?
    /// Full pretty-printed JSON payload of an emitted block (for inspection in detail view)
    let blockPayload: String?

    // Script metadata (captured at event time)
    let scriptVersion: String?

    // MARK: CodingKeys — explicit so new optional fields decode cleanly from old JSONL
    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, source, summary, detail
        case exitCode, exitedBySignal, stderrTail
        case blockID, blockType, blockTitle, blockOptions, blockPayload
        case scriptVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        timestamp      = try c.decode(Date.self,   forKey: .timestamp)
        kind           = try c.decode(HistoryEventKind.self, forKey: .kind)
        source         = try c.decode(String.self, forKey: .source)
        summary        = try c.decode(String.self, forKey: .summary)
        detail         = try c.decodeIfPresent(String.self,  forKey: .detail)
        exitCode       = try c.decodeIfPresent(Int32.self,   forKey: .exitCode)
        exitedBySignal = try c.decodeIfPresent(Bool.self,    forKey: .exitedBySignal)
        stderrTail     = try c.decodeIfPresent(String.self,  forKey: .stderrTail)
        blockID        = try c.decodeIfPresent(String.self,  forKey: .blockID)
        blockType      = try c.decodeIfPresent(String.self,  forKey: .blockType)
        blockTitle     = try c.decodeIfPresent(String.self,  forKey: .blockTitle)
        blockOptions   = try c.decodeIfPresent(String.self,  forKey: .blockOptions)
        blockPayload   = try c.decodeIfPresent(String.self,  forKey: .blockPayload)
        scriptVersion  = try c.decodeIfPresent(String.self,  forKey: .scriptVersion)
    }

    init(id: String, timestamp: Date, kind: HistoryEventKind, source: String, summary: String,
         detail: String? = nil, exitCode: Int32? = nil, exitedBySignal: Bool? = nil,
         stderrTail: String? = nil, blockID: String? = nil, blockType: String? = nil,
         blockTitle: String? = nil, blockOptions: String? = nil, blockPayload: String? = nil,
         scriptVersion: String? = nil) {
        self.id             = id
        self.timestamp      = timestamp
        self.kind           = kind
        self.source         = source
        self.summary        = summary
        self.detail         = detail
        self.exitCode       = exitCode
        self.exitedBySignal = exitedBySignal
        self.stderrTail     = stderrTail
        self.blockID        = blockID
        self.blockType      = blockType
        self.blockTitle     = blockTitle
        self.blockOptions   = blockOptions
        self.blockPayload   = blockPayload
        self.scriptVersion  = scriptVersion
    }
}

// MARK: - Service

/// Appends interaction events to ~/.ask/action-history.jsonl.
/// Loaded on init; observable so HistoryView stays live.
/// Cached context about an emitted block, used to enrich response events.
private struct EmissionContext {
    let title: String?
    let options: String?   // comma-separated option labels
    let blockType: String
}

@Observable
final class ActionHistoryService: @unchecked Sendable {
    private(set) var events: [HistoryEvent] = []

    // In-memory cache: blockID → context at emission time. Cleared when response is recorded.
    private var emissionCache: [String: EmissionContext] = [:]

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask/action-history.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = Self.load(from: fileURL, decoder: decoder)
    }

    // MARK: - Recording

    /// Records a user responding to a script block from iOS.
    func recordBlockResponse(scriptName: String, value: String, blockID: String? = nil, blockType: String? = nil) {
        let summary: String
        switch value.lowercased() {
        case "confirm", "yes":  summary = "Confirmed"
        case "deny", "no":      summary = "Declined"
        default:                summary = "Responded: \(value)"
        }

        // Look up what was originally asked from the emission cache
        var cached: EmissionContext?
        if let bid = blockID { cached = emissionCache[bid] }

        // Build detail showing what the user was presented
        var detailLines: [String] = []
        if let title = cached?.title, !title.isEmpty {
            detailLines.append("Asked: \(title)")
        }
        if let opts = cached?.options, !opts.isEmpty {
            detailLines.append("Options: \(opts)")
        }
        detailLines.append("Response: \(value)")

        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .blockResponse,
            source: scriptName,
            summary: summary,
            detail: detailLines.joined(separator: "\n"),
            blockID: blockID,
            blockType: blockType ?? cached?.blockType,
            blockTitle: cached?.title,
            blockOptions: cached?.options
        ))

        // Clean up cache entry
        if let bid = blockID { emissionCache.removeValue(forKey: bid) }
    }

    /// Records a script being enabled or disabled from Settings.
    func recordScriptToggle(scriptName: String, enabled: Bool) {
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: enabled ? .scriptEnabled : .scriptDisabled,
            source: scriptName,
            summary: enabled ? "Enabled" : "Disabled"
        ))
    }

    /// Records a script crashing with full diagnostics.
    func recordScriptCrash(scriptName: String, exitCode: Int32, exitedBySignal: Bool, stderrLines: [String], scriptVersion: String? = nil) {
        let tail = stderrLines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(30)
            .joined(separator: "\n")

        let reason = exitedBySignal
            ? "killed by signal \(exitCode)"
            : (exitCode == 0 ? "unexpected clean exit" : "exit code \(exitCode)")
        let summary = "Crashed (\(reason))"

        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .scriptCrashed,
            source: scriptName,
            summary: summary,
            detail: tail.isEmpty ? nil : tail,
            exitCode: exitCode,
            exitedBySignal: exitedBySignal,
            stderrTail: tail.isEmpty ? nil : tail,
            scriptVersion: scriptVersion
        ))
    }

    /// Records a script launching (or restarting after a crash).
    func recordScriptStarted(scriptName: String, scriptVersion: String? = nil, afterCrash: Bool = false) {
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .scriptStarted,
            source: scriptName,
            summary: afterCrash ? "Restarted" : "Started",
            scriptVersion: scriptVersion
        ))
    }

    /// Records a dependency check failure preventing a script from launching.
    func recordDependencyMissing(scriptName: String, missingDeps: [String]) {
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .dependencyMissing,
            source: scriptName,
            summary: "Missing: \(missingDeps.joined(separator: ", "))",
            detail: missingDeps.map { "• \($0)" }.joined(separator: "\n")
        ))
    }

    /// Records a block being emitted to CloudKit, caching the context for future response events.
    func recordBlockEmitted(scriptName: String, blockID: String, blockType: String,
                            title: String? = nil, options: [String]? = nil,
                            payloadJSON: String? = nil) {
        let optionsSummary = options.map { $0.joined(separator: ", ") }

        // Build a summary that includes the title if available
        let summary: String
        if let t = title, !t.isEmpty {
            summary = "\(blockType): \(t)"
        } else {
            summary = "Emitted \(blockType)"
        }

        // Cache so we can enrich the response event later
        emissionCache[blockID] = EmissionContext(
            title: title,
            options: optionsSummary,
            blockType: blockType
        )

        // Pretty-print the payload for display
        let prettyPayload: String? = payloadJSON.flatMap { raw -> String? in
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str = String(data: pretty, encoding: .utf8)
            else { return raw }
            return str
        }

        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .blockEmitted,
            source: scriptName,
            summary: summary,
            blockID: blockID,
            blockType: blockType,
            blockTitle: title,
            blockOptions: optionsSummary,
            blockPayload: prettyPayload
        ))
    }

    // MARK: - Private

    private func record(_ event: HistoryEvent) {
        events.insert(event, at: 0)
        append(event)
    }

    private func append(_ event: HistoryEvent) {
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = (line + "\n").data(using: .utf8)!
        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineWithNewline)
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? lineWithNewline.write(to: fileURL)
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [HistoryEvent] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> HistoryEvent? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(HistoryEvent.self, from: data)
            }
            .reversed()
    }
}
