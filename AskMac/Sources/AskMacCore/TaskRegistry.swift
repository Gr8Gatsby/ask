import Foundation

// MARK: - TaskRegistryEntry

/// Persisted state for one task. Stored in the task registry on disk.
public struct TaskRegistryEntry: Codable, Sendable {
    public var title: String
    public var status: String
    public var messageCount: Int
    public var artifactCount: Int
    public var nextSequenceNumber: Int

    public nonisolated init(title: String, status: String) {
        self.title = title
        self.status = status
        self.messageCount = 0
        self.artifactCount = 0
        self.nextSequenceNumber = 1
    }
}

// MARK: - TaskRegistryActor

/// Thread-safe task state registry. Persists to disk so tasks survive daemon restarts.
/// Composite key: machineID + "/" + scriptID + "/" + taskID → entry.
///
/// The on-disk file is read lazily on first access. Every public method awaits
/// `ensureLoaded()` first, so an early `incrementMessage` call (which can happen
/// when a hook event lands before the explicit `load()` completes) cannot race
/// with the disk read and reset the sequence counter to 1.
public actor TaskRegistryActor {
    public var entries: [String: TaskRegistryEntry] = [:]
    private var didLoad = false

    private let persistURL: URL

    public init(persistURL: URL? = nil) {
        if let url = persistURL {
            self.persistURL = url
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ask", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.persistURL = dir.appendingPathComponent("task-registry.json")
        }
    }

    /// Reads the on-disk registry into memory. Idempotent — subsequent calls are no-ops.
    /// All mutating methods call this internally so the counter never starts fresh
    /// on a stale in-memory view.
    public func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: persistURL),
              let decoded = try? JSONDecoder().decode([String: TaskRegistryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: persistURL, options: .atomic)
    }

    public func entry(for key: String) -> TaskRegistryEntry? {
        load()
        return entries[key]
    }

    /// Upserts a task entry, updating title and status. Returns the current entry.
    @discardableResult
    public func upsert(key: String, title: String, status: String) -> TaskRegistryEntry {
        load()
        var entry = entries[key] ?? TaskRegistryEntry(title: title, status: status)
        entry.title = title
        entry.status = status
        entries[key] = entry
        save()
        return entry
    }

    /// Increments the message counter and sequence number. Returns the sequence number to use.
    public func incrementMessage(key: String) -> Int {
        load()
        var entry = entries[key] ?? TaskRegistryEntry(title: "", status: "working")
        let seq = entry.nextSequenceNumber
        entry.messageCount += 1
        entry.nextSequenceNumber += 1
        entries[key] = entry
        save()
        return seq
    }

    public func incrementArtifact(key: String) {
        load()
        guard var entry = entries[key] else { return }
        entry.artifactCount += 1
        entries[key] = entry
        save()
    }
}

// MARK: - TaskServiceError

public enum TaskServiceError: LocalizedError, Equatable, Sendable {
    case noContent
    case fileNotFound(String)
    case invalidBase64
    case contentTooLarge(Int)
    case invalidPartsJSON
    case taskNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noContent:
            return "put_artifact requires filePath or content"
        case .fileNotFound(let path):
            return "filePath not found: \(path)"
        case .invalidBase64:
            return "content is not valid base64"
        case .contentTooLarge(let bytes):
            let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
            return "content exceeds 10 MB limit (\(mb) MB) — write to disk and use filePath"
        case .invalidPartsJSON:
            return "parts could not be serialized to JSON"
        case .taskNotFound(let id):
            return "task not found: \(id)"
        }
    }
}
