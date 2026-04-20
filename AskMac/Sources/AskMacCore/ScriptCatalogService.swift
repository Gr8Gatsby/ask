import Foundation
import Observation

@MainActor
@Observable
public final class ScriptCatalogService {

    private static let catalogURL = URL(string: "https://github.com/Gr8Gatsby/ask/releases/download/scripts-latest/catalog.json")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60  // 24 hours

    /// All scripts available in the remote catalog.
    public private(set) var allEntries: [CatalogEntry] = []

    /// Subset of allEntries where the catalog version is strictly newer than the installed version.
    /// Keyed by script ID.
    public private(set) var availableUpdates: [String: CatalogEntry] = [:]

    /// Script IDs whose manifest `requires` checks all passed on this machine.
    /// Scripts with no `requires` are always included. Populated after each fetch.
    public private(set) var compatibleScriptIDs: Set<String> = []

    public private(set) var isFetching = false
    public private(set) var isCheckingCompatibility = false
    public private(set) var lastFetchError: String?
    public private(set) var lastFetchDate: Date?

    // MARK: - Init

    public init() {}

    /// Testing initializer — seeds allEntries without a network fetch.
    public init(entries: [CatalogEntry]) {
        allEntries = entries
    }

    // MARK: - Public API

    /// Fetch the catalog and compute available updates against the provided installed scripts.
    /// Safe to call multiple times — skips the network request if fetched within the last 24 hours.
    public func fetch(installedScripts: [any InstalledScript], force: Bool = false) {
        guard !isFetching else { return }
        if !force, let last = lastFetchDate, Date().timeIntervalSince(last) < Self.checkInterval {
            recomputeUpdates(installedScripts: installedScripts)
            return
        }
        Task { await performFetch(installedScripts: installedScripts) }
    }

    /// Downloads the zip for a catalog entry to a temp file and returns the URL.
    public func downloadZip(for entry: CatalogEntry) async throws -> URL {
        let (localURL, _) = try await URLSession.shared.download(from: entry.downloadURL)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(entry.version).zip")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: localURL, to: dest)
        return dest
    }

    // MARK: - Private

    private func performFetch(installedScripts: [any InstalledScript]) async {
        isFetching = true
        lastFetchError = nil

        do {
            let (data, _) = try await URLSession.shared.data(from: Self.catalogURL)
            let catalog = try JSONDecoder().decode(ScriptCatalog.self, from: data)
            allEntries = catalog.scripts
            lastFetchDate = Date()
            recomputeUpdates(installedScripts: installedScripts)
        } catch {
            lastFetchError = error.localizedDescription
        }

        isFetching = false
        Task { await checkCompatibility() }
    }

    private func checkCompatibility() async {
        guard !allEntries.isEmpty else { return }
        isCheckingCompatibility = true

        let entries = allEntries
        let compatible = await Task.detached(priority: .utility) { () -> Set<String> in
            var result: Set<String> = []
            for entry in entries {
                let reqs = entry.requires ?? []
                var passes = true
                for req in reqs {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                    proc.arguments = ["-c", req.check]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try? proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 { passes = false; break }
                }
                if passes { result.insert(entry.id) }
            }
            return result
        }.value

        compatibleScriptIDs = compatible
        isCheckingCompatibility = false
    }

    public func recomputeUpdates(installedScripts: [any InstalledScript]) {
        var updates: [String: CatalogEntry] = [:]
        for entry in allEntries {
            guard let installed = installedScripts.first(where: { $0.id == entry.id }),
                  let installedVersion = installed.version else { continue }
            if VersionComparison.compare(entry.version, installedVersion) == .orderedDescending {
                updates[entry.id] = entry
            }
        }
        availableUpdates = updates
    }

}
