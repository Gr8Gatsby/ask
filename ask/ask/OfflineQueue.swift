import Foundation
import Observation

// MARK: - OfflineQueueEntry

struct OfflineQueueEntry: Codable, Identifiable {
    let id: String
    let machineID: String
    let scriptID: String
    let scriptName: String   // human-readable, e.g. "Homebrew"
    let blockID: String
    let responseValue: String
    let queuedAt: Date
}

// MARK: - OfflineQueue

/// Stores user responses that were made while the Mac was offline.
/// Persisted to UserDefaults so entries survive app restarts.
@Observable
final class OfflineQueue {
    static let shared = OfflineQueue()

    private(set) var entries: [OfflineQueueEntry] = []

    private let defaultsKey = "ask.offlineQueue"

    private init() {
        load()
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func enqueue(
        machineID: String,
        scriptID: String,
        scriptName: String,
        blockID: String,
        value: String
    ) {
        let entry = OfflineQueueEntry(
            id: UUID().uuidString,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: scriptName,
            blockID: blockID,
            responseValue: value,
            queuedAt: Date()
        )
        entries.append(entry)
        save()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([OfflineQueueEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
