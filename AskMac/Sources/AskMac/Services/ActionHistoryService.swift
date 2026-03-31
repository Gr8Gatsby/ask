import Foundation
import Observation

// MARK: - Model

enum HistoryEventKind: String, Codable, Sendable {
    case blockResponse   // user responded to an iOS block
    case jobCompleted    // one-shot job completed (exit 0)
    case jobFailed       // one-shot job failed (non-zero exit or timeout)
    case jobCancelled    // one-shot job cancelled by user
    case scriptEnabled   // script enabled in Settings
    case scriptDisabled  // script disabled in Settings
    case scriptCrashed   // script crashed unexpectedly
}

struct HistoryEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String              // UUID
    let timestamp: Date
    let kind: HistoryEventKind
    let source: String          // script name or agent name
    let summary: String         // one-line human description
    let detail: String?         // prompt for jobs, response value for blocks, stderr for crashes
}

// MARK: - Service

/// Appends interaction events to ~/.ask/action-history.jsonl.
/// Loaded on init; observable so HistoryView stays live.
@Observable
final class ActionHistoryService: @unchecked Sendable {
    private(set) var events: [HistoryEvent] = []

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
    func recordBlockResponse(scriptName: String, value: String) {
        let summary: String
        switch value.lowercased() {
        case "confirm", "yes":  summary = "Confirmed"
        case "deny", "no":      summary = "Declined"
        default:                summary = "Responded: \(value)"
        }
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .blockResponse,
            source: scriptName,
            summary: summary,
            detail: nil
        ))
    }

    /// Records a job completion.
    func recordJob(agentName: String, prompt: String, status: JobStatus, durationSeconds: Double, exitCode: Int?) {
        let kind: HistoryEventKind
        let summary: String

        switch status {
        case .completed:
            kind = .jobCompleted
            summary = "Completed in \(durationLabel(durationSeconds))"
        case .failed:
            kind = .jobFailed
            let code = exitCode.map { " (exit \($0))" } ?? ""
            summary = "Failed\(code) after \(durationLabel(durationSeconds))"
        case .cancelled:
            kind = .jobCancelled
            summary = "Cancelled after \(durationLabel(durationSeconds))"
        default:
            kind = .jobFailed
            summary = "Ended with status \(status.rawValue)"
        }

        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: kind,
            source: agentName,
            summary: summary,
            detail: prompt
        ))
    }

    /// Records a script being enabled or disabled from Settings.
    func recordScriptToggle(scriptName: String, enabled: Bool) {
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: enabled ? .scriptEnabled : .scriptDisabled,
            source: scriptName,
            summary: enabled ? "Enabled" : "Disabled",
            detail: nil
        ))
    }

    /// Records a script crashing.
    func recordScriptCrash(scriptName: String, lastStderr: String?) {
        record(HistoryEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            kind: .scriptCrashed,
            source: scriptName,
            summary: "Crashed",
            detail: lastStderr
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

    private func durationLabel(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
