import CloudKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "Sessions")

/// Loads and unifies session state from local daemon registries and
/// CloudKit AskTask records across all known machines. Polls CloudKit
/// every 30 seconds while the view is visible.
@MainActor
@Observable
final class SessionsService {
    private let cloudKit: CloudKitService
    private let settings: AppSettings
    private let scriptManager: ScriptManager

    private(set) var sessions: [UnifiedSession] = []
    private(set) var remoteUnavailable: String? = nil
    private(set) var localUnavailable: String? = nil
    private(set) var isRefreshing: Bool = false
    private(set) var lastRefreshAt: Date? = nil

    /// Machine display-name cache, keyed by machineID. Refreshed on each
    /// remote tick.
    private var machineNames: [String: String] = [:]
    private var pollTask: Task<Void, Never>? = nil
    private var visible: Bool = false

    /// Daemon registries this service is aware of, in `(scriptID, path)`
    /// pairs. The scriptID is used to look up the manifest version via
    /// `ScriptManager.scripts`.
    private let localRegistries: [(scriptID: String, path: String)] = [
        ("claude-3", "~/.ask/claude3-sessions.json"),
        ("codex-3",  "~/.ask/codex3-sessions.json"),
    ]

    init(cloudKit: CloudKitService, settings: AppSettings, scriptManager: ScriptManager) {
        self.cloudKit = cloudKit
        self.settings = settings
        self.scriptManager = scriptManager
    }

    // MARK: - Lifecycle

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            refreshNow()
            startPolling()
        } else {
            stopPolling()
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                guard self.visible else { return }
                await self.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefreshAt = Date() }

        let now = Date()
        let localSessions = loadLocalSessions(now: now)
        let remoteSessions = await loadRemoteSessions(now: now)

        // Merge keyed by sessionID. Locals first.
        var byID: [String: UnifiedSession] = [:]
        for s in localSessions { byID[s.sessionID] = s }
        for s in remoteSessions {
            if let existing = byID[s.sessionID] {
                byID[s.sessionID] = UnifiedSession.merge(local: existing, remote: s)
            } else {
                byID[s.sessionID] = s
            }
        }

        // Filter to active.
        let merged = byID.values.filter { $0.isActive(now: now) }

        // Sort: last-activity desc.
        self.sessions = merged.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    // MARK: - Local

    private func loadLocalSessions(now: Date) -> [UnifiedSession] {
        var collected: [UnifiedSession] = []
        var anyReadFailure: String? = nil

        let machineID = settings.machineID
        let machineName = settings.machineName.isEmpty ? machineID : settings.machineName

        for (scriptID, path) in localRegistries {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
                anyReadFailure = "Couldn't read \(path)"
                logger.warning("Sessions: read failed for \(expanded)")
                continue
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
                anyReadFailure = "Couldn't parse \(path)"
                logger.warning("Sessions: parse failed for \(expanded)")
                continue
            }

            let script = scriptManager.scripts.first { $0.id == scriptID }
            let scriptName = script?.name ?? scriptID
            let scriptVersion = script?.version

            for (_, raw) in json {
                guard let entry = LocalSessionEntry(scriptID: scriptID, raw: raw) else { continue }
                collected.append(
                    UnifiedSession.fromLocal(
                        entry,
                        machineID: machineID,
                        machineName: machineName,
                        scriptName: scriptName,
                        scriptVersion: scriptVersion,
                        now: now
                    )
                )
            }
        }

        localUnavailable = anyReadFailure
        return collected
    }

    // MARK: - Remote

    private func loadRemoteSessions(now: Date) async -> [UnifiedSession] {
        guard cloudKit.accountStatus == .available else {
            remoteUnavailable = "iCloud account is not available."
            return []
        }

        // Refresh machine name cache first, so rows render with names
        // instead of machineID strings.
        await refreshMachineNames()

        // Fetch tasks across all known machines. This Mac's tasks are
        // included but will be dedup'd against local sessions by sessionID.
        let allMachineIDs = Array(machineNames.keys)
        let myID = settings.machineID
        let machineIDs = allMachineIDs.isEmpty ? [myID] : allMachineIDs

        var tasks: [AskTaskRecord] = []
        var failure: String? = nil
        for mid in machineIDs {
            do {
                let machineTasks = try await cloudKit.fetchTasks(machineID: mid)
                tasks.append(contentsOf: machineTasks)
            } catch {
                logger.error("fetchTasks failed for \(mid): \(error)")
                failure = "CloudKit fetch failed: \(error.localizedDescription)"
            }
        }
        remoteUnavailable = failure

        return tasks.map { task in
            let name = machineNames[task.machineID]
                ?? (task.machineID == myID ? (settings.machineName.isEmpty ? myID : settings.machineName) : task.machineID)
            return UnifiedSession.fromRemote(task, machineName: name, now: now)
        }
    }

    private func refreshMachineNames() async {
        do {
            let machines = try await cloudKit.fetchAllMachines()
            var fresh: [String: String] = [:]
            for m in machines {
                fresh[m.machineID] = m.name.isEmpty ? m.machineID : m.name
            }
            // Always keep our own entry so local-only sessions can render.
            let myID = settings.machineID
            if fresh[myID] == nil {
                fresh[myID] = settings.machineName.isEmpty ? myID : settings.machineName
            }
            machineNames = fresh
        } catch {
            logger.error("fetchAllMachines failed: \(error)")
            // Leave the existing cache in place.
        }
    }
}

extension SessionsService {
    /// Convenience grouping for the view. Returns sessions grouped by
    /// machineID, with this Mac first.
    struct MachineGroup: Identifiable {
        let machineID: String
        let machineName: String
        let isThisMac: Bool
        let sessions: [UnifiedSession]
        var id: String { machineID }
    }

    func groupedByMachine() -> [MachineGroup] {
        let myID = settings.machineID
        let groups = Dictionary(grouping: sessions, by: { $0.machineID })
        return groups.map { mid, items in
            let name = items.first?.machineName ?? mid
            return MachineGroup(
                machineID: mid,
                machineName: name,
                isThisMac: mid == myID,
                sessions: items.sorted { $0.lastActivityAt > $1.lastActivityAt }
            )
        }
        .sorted { lhs, rhs in
            if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
            return lhs.machineName.localizedCaseInsensitiveCompare(rhs.machineName) == .orderedAscending
        }
    }
}
