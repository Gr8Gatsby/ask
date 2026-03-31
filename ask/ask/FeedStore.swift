import Foundation
import Observation

// MARK: - LocalFeedItem

struct LocalFeedItem: Identifiable, Codable {
    let id: String          // = blockID
    let machineID: String
    let scriptID: String
    let scriptName: String?
    let scriptIcon: String?
    let headline: String
    let body: String?
    let statusColor: String?
    let timestamp: Date

    init?(block: RKBlock) {
        guard let payload = block.feedItemPayload else { return nil }
        self.id          = block.id
        self.machineID   = block.machineID
        self.scriptID    = block.scriptID
        self.scriptName  = block.scriptName
        self.scriptIcon  = block.scriptIcon
        self.headline    = payload.headline
        self.body        = payload.body
        self.statusColor = payload.statusColor
        self.timestamp   = block.createdAt
    }
}

// MARK: - FeedStore

@Observable
final class FeedStore {
    static let shared = FeedStore()

    private(set) var items: [LocalFeedItem] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-items.json")
    }()

    private init() {
        load()
    }

    // MARK: - Public

    func upsert(_ blocks: [RKBlock]) {
        let newItems = blocks.compactMap { LocalFeedItem(block: $0) }
        guard !newItems.isEmpty else { return }
        let existingIDs = Set(items.map(\.id))
        let fresh = newItems.filter { !existingIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        items = (fresh + items).sorted { $0.timestamp > $1.timestamp }
        save()
    }

    func clearAll() {
        items = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LocalFeedItem].self, from: data)
        else { return }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        items = decoded.filter { $0.timestamp > cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
