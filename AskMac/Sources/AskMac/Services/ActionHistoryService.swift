import Foundation
import Observation

// MARK: - Model

struct ActionHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { jobID }
    let timestamp: Date
    let actionName: String
    let prompt: String
    let status: String        // "completed", "failed", "cancelled", "timeout"
    let durationSeconds: Double
    let exitCode: Int?
    let jobID: String
}

// MARK: - Service

/// Appends job execution records to ~/.ask/action-history.jsonl.
/// Loaded on init; observable so HistoryView stays live.
@Observable
final class ActionHistoryService: @unchecked Sendable {
    private(set) var entries: [ActionHistoryEntry] = []

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
        entries = Self.load(from: fileURL, decoder: decoder)
    }

    /// Called by JobExecutor after each job finishes.
    func record(
        jobID: String,
        actionName: String,
        prompt: String,
        status: String,
        durationSeconds: Double,
        exitCode: Int?
    ) {
        let entry = ActionHistoryEntry(
            timestamp: Date(),
            actionName: actionName,
            prompt: prompt,
            status: status,
            durationSeconds: durationSeconds,
            exitCode: exitCode,
            jobID: jobID
        )
        entries.insert(entry, at: 0)
        append(entry)
    }

    // MARK: - Private

    private func append(_ entry: ActionHistoryEntry) {
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = (line + "\n").data(using: .utf8)!
        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            handle.seekToEndOfFile()
            handle.write(lineWithNewline)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? lineWithNewline.write(to: fileURL)
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [ActionHistoryEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> ActionHistoryEntry? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ActionHistoryEntry.self, from: data)
            }
            .reversed()  // newest first in memory
    }
}
