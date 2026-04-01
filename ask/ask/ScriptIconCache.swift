import Foundation

/// A single cached script entry — enough to render an icon and name without
/// a live CloudKit response. Persisted across launches so the loading scene
/// has data on the very first frame.
struct CachedScriptEntry: Codable, Identifiable {
    let id: String          // scriptID
    var name: String
    var sfSymbol: String?   // SF Symbol name fallback
    var iconData: String?   // base64 PNG (preferred)
}

/// Persists script icon/name data across launches so the loading scene
/// can show real icons immediately, before CloudKit returns.
@Observable
final class ScriptIconCache {
    private(set) var entries: [CachedScriptEntry] = []

    private static let defaultsKey = "ask.cachedScriptIcons.v1"

    init() { load() }

    /// Call after each successful block fetch to keep the cache current.
    /// `groups` is a sequence of (id, name, sfSymbol?, iconData?) tuples —
    /// matches the `ScriptGroup` fields the caller extracts.
    func update(from groups: [(id: String, name: String, sfSymbol: String?, iconData: String?)]) {
        guard !groups.isEmpty else { return }
        var updated = groups.map {
            CachedScriptEntry(id: $0.id, name: $0.name, sfSymbol: $0.sfSymbol, iconData: $0.iconData)
        }
        // Preserve entries for scripts not in this load (could be from another
        // machine or temporarily offline), capped at 20 total to avoid stale bloat.
        let currentIDs = Set(updated.map(\.id))
        let preserved = entries.filter { !currentIDs.contains($0.id) }
        entries = Array((updated + preserved).prefix(20))
        save()
    }

    // MARK: - Private

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CachedScriptEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
