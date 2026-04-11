import AppKit
import CoreServices
#if canImport(AskMacCore)
import AskMacCore
#endif
import Foundation
import Observation

// MARK: - Manifest

struct ScriptDependency: Codable {
    let id: String
    let name: String
    let check: String       // shell command; exit 0 = installed
    let minVersion: String? // semver minimum, compared against stdout of check
    let install: String?    // install command to surface to the user
    let installURL: String? // URL for full setup instructions

    enum CodingKeys: String, CodingKey {
        case id, name, check, install
        case minVersion  = "min_version"
        case installURL  = "install_url"
    }
}

struct ScriptToolParam: Codable {
    let name: String
    let type: String?
    let required: Bool?
}

struct ScriptTool: Codable {
    let name: String
    let description: String?
    let params: [ScriptToolParam]?
}

// MARK: - Setup & config

/// A single check result emitted by `setup.py --check`.
struct SetupCheck: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let ok: Bool
    let message: String?
    let fixable: Bool?
    let needsTerminal: Bool?

    enum CodingKeys: String, CodingKey {
        case id, label, ok, message, fixable
        case needsTerminal = "needs_terminal"
    }
}

/// A piece of configuration a script needs, declared in its manifest.
struct ScriptConfigItem: Codable, Identifiable, Sendable {
    let key: String
    let label: String
    let type: String        // "secret" | "string" | "boolean"
    let required: Bool?
    let description: String?
    let helpURL: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, type, required, description
        case helpURL = "help_url"
    }
}

struct ScriptManifest: Codable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let entry: String       // relative path to the executable entry point
    let icon: String?
    let iconFile: String?   // relative path to an image file (SVG/PNG)
    let type: String?       // "tile" (default), "feed", or "system"
    let schedule: String?   // cron expression, e.g. "0 9 * * *" (feed scripts only)
    let requires: [ScriptDependency]?
    let tools: [ScriptTool]?
    let setup: String?              // relative path to setup script (e.g. "setup.py")
    let config: [ScriptConfigItem]? // configuration values the script needs
    let timeoutSeconds: Int?        // feed script max runtime in seconds (default 300)

    var isFeed: Bool   { type == "feed" }
    var isSystem: Bool { type == "system" }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, entry, icon, type, schedule, requires, tools, setup, config
        case iconFile       = "icon_file"
        case timeoutSeconds = "timeout_seconds"
    }
}

// MARK: - UI model

struct ManagedScript: Identifiable, InstalledScript {
    let id: String          // manifest.id
    let name: String
    let version: String?    // manifest.version
    let description: String? // manifest.description
    let icon: String?       // SF Symbol fallback
    var iconImage: NSImage? // loaded from icon_file
    var svgString: String?  // raw SVG markup, used for dark-mode colour manipulation
    var status: ScriptStatus
    var isEnabled: Bool
    var lastError: String?  // last stderr output before most recent crash
    var lastEmitTime: Date? // last time this script emitted a block to CloudKit
    var missingDeps: [ScriptDependency] = []
    var scriptType: String?              // "tile" (default), "feed", or "system"
    var schedule: String?               // cron expression for feed scripts

    var isSystem: Bool { scriptType == "system" }
    var requires: [ScriptDependency] = [] // all declared dependencies
    var tools: [ScriptTool] = []         // public tools declared in manifest
    var entry: String?                  // manifest entry point (relative path)
    var manifestPath: URL?              // path to the manifest.json file

    // Setup & config
    var setupScript: String?            // relative path to setup.py
    var configItems: [ScriptConfigItem] = []  // declared config from manifest
    var setupChecks: [SetupCheck] = []        // last --check results
    var setupCheckRunning: Bool = false        // true while --check is in flight
    var stderrLog: [String] = []              // last 50 lines of stderr from most recent run
    var isBundled: Bool = false               // true if the script lives in the app bundle

    var hasSetup: Bool { setupScript != nil || !configItems.isEmpty }
    var needsSetup: Bool {
        guard hasSetup else { return false }
        let hasFailedCheck = setupChecks.contains { !$0.ok }
        let hasMissingRequired = configItems.contains {
            $0.required == true && KeychainService.shared.get(scriptID: id, key: $0.key) == nil
        }
        return hasFailedCheck || hasMissingRequired
    }

    enum ScriptStatus {
        case starting, running, crashed, stopped, missingDependencies, needsSetup

        var label: String {
            switch self {
            case .starting:             "Starting"
            case .running:              "Running"
            case .crashed:              "Crashed"
            case .stopped:              "Stopped"
            case .missingDependencies:  "Missing dependencies"
            case .needsSetup:           "Needs setup"
            }
        }
    }
}

// MARK: - Manager

/// Discovers scripts under ~/.ask/scripts/*/manifest.json, launches each one
/// as a subprocess via MCPConnection, and auto-restarts on crash.
@Observable
final class ScriptManager: @unchecked Sendable {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let settings: AppSettings

    private(set) var scripts: [ManagedScript] = []
    /// Live blocks currently emitted by each script, keyed by scriptID → blockID.
    private(set) var activeBlocks: [String: [String: LiveBlock]] = [:]

    // Internal — not exposed to UI
    private var connections: [String: MCPConnection] = [:]
    private var systemConnections: [String: SystemScriptConnection] = [:]
    private var restartDelays: [String: TimeInterval] = [:]
    // Cached manifests so we can re-launch after enable
    private var manifests: [String: (manifest: ScriptManifest, dir: URL, icon: NSImage?, svgString: String?)] = [:]

    private let actionHistory: ActionHistoryService
    private let feedScheduler: FeedScheduler
    private let terminalMonitor = TerminalMonitorService()

    // Vault file watcher
    private var vaultWatcher: VaultWatcher?
    private var reloadDebounceWork: DispatchWorkItem?

    // Install lock: reload() defers while an install is in progress
    private var installLockCount = 0
    private var pendingReload = false

    // In-flight dep-check guard: prevents double-launch when reload() fires twice
    // rapidly (e.g. endInstall + stale file-watcher debounce both calling reload()).
    private var launchingScripts: Set<String> = []

    // Circuit breaker: tracks recent crash timestamps per script
    private var crashHistory: [String: [Date]] = [:]
    private static let circuitBreakerLimit   = 5
    private static let circuitBreakerWindow: TimeInterval = 300  // 5 minutes

    // Feed timeout tasks: cancelled when feed exits cleanly
    private var feedTimeoutTasks: [String: Task<Void, Never>] = [:]

    init(cloudKit: CloudKitService, machineID: String, settings: AppSettings, actionHistory: ActionHistoryService) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.settings = settings
        self.actionHistory = actionHistory
        self.feedScheduler = FeedScheduler()
    }

    /// Ordered list of directories to scan for scripts.
    /// Bundled scripts come first; vault scripts come second and override bundled ones with the same ID.
    private func scriptDirs() -> [URL] {
        var dirs: [URL] = []
        if settings.usesBundledScripts,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("Scripts") {
            dirs.append(bundled)
        }
        if let vault = settings.vaultPath {
            dirs.append(vault)
        }
        return dirs
    }

    func start() {
        discoverAndLaunch()
        purgeBlocksForDisabledScripts()
        startVaultWatcher()
    }

    /// Deletes CloudKit blocks for any scripts that are currently disabled.
    /// Handles stale blocks left over from before the script was disabled (e.g. no-TTL blocks).
    private func purgeBlocksForDisabledScripts() {
        let disabled = settings.disabledScripts
        guard !disabled.isEmpty else { return }
        Task {
            for scriptID in disabled {
                let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: scriptID)
                do {
                    try await blockService.clearAllBlocks()
                    print("[ScriptManager] Purged stale blocks for disabled script: \(scriptID)")
                } catch {
                    print("[ScriptManager] Failed to purge blocks for \(scriptID): \(error)")
                }
            }
        }
    }

    func stop() {
        vaultWatcher = nil
        reloadDebounceWork?.cancel()
        for (_, conn) in connections { conn.stop() }
        connections = [:]
        for (_, conn) in systemConnections { conn.stop() }
        systemConnections = [:]
        feedScheduler.cancelAll()
        feedTimeoutTasks.values.forEach { $0.cancel() }
        feedTimeoutTasks = [:]
        launchingScripts = []
    }

    /// Rescans the scripts directory, picks up newly discovered scripts, and restarts
    /// all already-tracked enabled scripts (tile scripts restart; feed scripts get an
    /// immediate run if not currently running).
    func reload() {
        guard installLockCount == 0 else {
            pendingReload = true
            return
        }
        let fm = FileManager.default
        // Collect all script directories from all sources; later sources override earlier ones.
        var allDirs: [(dir: URL, manifestURL: URL)] = []
        var seen: [String: Int] = [:]
        for sourceDir in scriptDirs() {
            guard let subdirs = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in subdirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                // Skip rollback backup directories (created by ScriptInstaller on update)
                guard !dir.lastPathComponent.hasSuffix(".previous") else { continue }
                let manifestURL = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(ScriptManifest.self, from: data)
                else { continue }
                if let existing = seen[manifest.id] {
                    allDirs[existing] = (dir, manifestURL)
                } else {
                    seen[manifest.id] = allDirs.count
                    allDirs.append((dir, manifestURL))
                }
            }
        }

        for (dir, _) in allDirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(ScriptManifest.self, from: data)
            else { continue }

            let iconCandidate = manifest.iconFile ?? "icon.svg"
            let iconURL = dir.appendingPathComponent(iconCandidate)
            let resolvedIcon = iconURL.resolvingSymlinksInPath()
            let resolvedDirForIcon = dir.resolvingSymlinksInPath()
            let iconInBounds = resolvedIcon.path.hasPrefix(resolvedDirForIcon.path + "/")
                            || resolvedIcon.path == resolvedDirForIcon.path
            let iconImage: NSImage? = iconInBounds ? NSImage(contentsOf: iconURL) : nil
            let svgString: String? = iconInBounds && iconURL.pathExtension.lowercased() == "svg"
                ? try? String(contentsOf: iconURL, encoding: .utf8)
                : nil

            let isNew = manifests[manifest.id] == nil
            manifests[manifest.id] = (manifest, dir, iconImage, svgString)

            // System scripts: re-launch as persistent background service, not shown in UI.
            if manifest.isSystem {
                systemConnections[manifest.id]?.stop()
                systemConnections.removeValue(forKey: manifest.id)
                launchSystemWithDepCheck(manifest: manifest, scriptDir: dir)
                continue
            }

            let isEnabled = !settings.disabledScripts.contains(manifest.id)
            guard isEnabled else {
                upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon,
                             iconImage: iconImage, status: .stopped, isEnabled: false)
                publishScript(manifest, status: "disabled")
                continue
            }

            if manifest.isFeed {
                // Stop any existing tile connection for this script (handles tile→feed transition)
                if let conn = connections[manifest.id] {
                    conn.stop()
                    connections.removeValue(forKey: manifest.id)
                    activeBlocks.removeValue(forKey: manifest.id)
                }
                // Set up the cron schedule if not already scheduled
                if feedScheduler.task(for: manifest.id) == nil {
                    feedScheduler.schedule(manifest: manifest, scriptDir: dir, settings: settings) { [weak self] m, d in
                        self?.launchFeedRunWithDepCheck(manifest: m, scriptDir: d)
                    }
                }
                // Publish idle state with next scheduled run time before launching
                publishScript(manifest, status: "idle", nextRunAt: computeNextRun(for: manifest))
                // Trigger an immediate run
                launchFeedRunWithDepCheck(manifest: manifest, scriptDir: dir)
            } else {
                // Tile script: stop existing connection then re-launch
                if !isNew, let conn = connections[manifest.id] {
                    conn.stop()
                    connections.removeValue(forKey: manifest.id)
                    activeBlocks.removeValue(forKey: manifest.id)
                }
                publishScript(manifest, status: "running")
                launchWithDepCheck(manifest: manifest, scriptDir: dir)
            }
            print("[ScriptManager] \(isNew ? "Loaded" : "Refreshed") script: \(manifest.id)")
        }
    }

    func connection(for scriptID: String) -> MCPConnection? {
        connections[scriptID]
    }

    // MARK: - Private

    func disableScript(id: String) {
        let name = scripts.first(where: { $0.id == id })?.name ?? id
        settings.setScriptEnabled(id, enabled: false)
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = false
            scripts[idx].status = .stopped
        }
        actionHistory.recordScriptToggle(scriptName: name, enabled: false)
        connections[id]?.stop()
        connections.removeValue(forKey: id)
        restartDelays.removeValue(forKey: id)
        activeBlocks.removeValue(forKey: id)
        feedScheduler.cancel(scriptID: id)
        if let m = manifests[id]?.manifest { publishScript(m, status: "disabled") }
        Task {
            let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: id)
            try? await blockService.clearAllBlocks()
        }
    }

    func uninstallScript(id: String) {
        // System scripts cannot be deleted — users can only disable them
        guard scripts.first(where: { $0.id == id })?.isSystem != true else {
            print("[ScriptManager] Refusing to uninstall system script: \(id)")
            return
        }

        // Stop all connections
        connections[id]?.stop()
        connections.removeValue(forKey: id)
        systemConnections[id]?.stop()
        systemConnections.removeValue(forKey: id)

        // Cancel feed scheduler + timeout tasks
        feedScheduler.cancel(scriptID: id)
        feedTimeoutTasks[id]?.cancel()
        feedTimeoutTasks.removeValue(forKey: id)

        // Clear all runtime state
        launchingScripts.remove(id)
        crashHistory.removeValue(forKey: id)
        restartDelays.removeValue(forKey: id)
        activeBlocks.removeValue(forKey: id)

        // Remove from disabled-scripts list (cleanup, the script is gone)
        settings.setScriptEnabled(id, enabled: true)

        // Clear CloudKit blocks and remove script registry record
        Task {
            let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: id)
            try? await blockService.clearAllBlocks()
            await cloudKit.deleteScript(machineID: machineID, scriptID: id)
        }

        // Capture directory before removing from cache
        let isBundled = scripts.first(where: { $0.id == id })?.isBundled ?? true
        let scriptDir = manifests[id]?.dir

        // Remove from cache and UI
        manifests.removeValue(forKey: id)
        scripts.removeAll { $0.id == id }

        // Move vault folder to Trash (bundled scripts are never trashed)
        guard !isBundled, let dir = scriptDir else { return }

        // Run setup --uninstall before trashing so the script can clean up any
        // system state it registered (e.g. hooks in ~/.claude/settings.json).
        let setupPath = dir.appendingPathComponent("setup.py")
        if FileManager.default.fileExists(atPath: setupPath.path) {
            Task {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [setupPath.path, "--uninstall"]
                var env = ProcessInfo.processInfo.environment
                let vaultRoot = dir.deletingLastPathComponent().path
                let existing = env["PYTHONPATH"].map { ":\($0)" } ?? ""
                env["PYTHONPATH"] = "\(vaultRoot):\(dir.path)\(existing)"
                proc.environment = env
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                proc.waitUntilExit()

                do {
                    try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                    print("[ScriptManager] Moved script \(id) to trash: \(dir.path)")
                } catch {
                    print("[ScriptManager] Failed to move script \(id) to trash: \(error)")
                }
            }
        } else {
            do {
                try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                print("[ScriptManager] Moved script \(id) to trash: \(dir.path)")
            } catch {
                print("[ScriptManager] Failed to move script \(id) to trash: \(error)")
            }
        }
    }

    /// Deliver a user response to a block directly from the Mac UI.
    func respondToBlock(scriptID: String, blockID: String, value: String) {
        connections[scriptID]?.deliverResponse(blockID: blockID, value: value)
        if activeBlocks[scriptID]?[blockID]?.blockType != "agent_session" {
            activeBlocks[scriptID]?.removeValue(forKey: blockID)
        }
        if MacUITestingSupport.isUITesting {
            MacUITestingSupport.markResponded(blockID)
        }
    }

    // MARK: - UI Testing

    /// Injects mock scripts and blocks for XCUITest runs.
    /// Call before any service is started (i.e. from AskMacApp.init when --uitesting).
    func loadMockScenario(_ scenario: String) {
        scripts = MacUITestingSupport.scripts(for: scenario)
        activeBlocks = MacUITestingSupport.activeBlocks(for: scenario)
    }

    func enableScript(id: String) {
        launchingScripts.remove(id)  // Clear stale guard from any previous failed launch
        let name = scripts.first(where: { $0.id == id })?.name ?? id
        settings.setScriptEnabled(id, enabled: true)
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = true
        }
        actionHistory.recordScriptToggle(scriptName: name, enabled: true)
        // Reset circuit-breaker state so the script gets a clean slate
        crashHistory.removeValue(forKey: id)
        restartDelays.removeValue(forKey: id)
        if let cached = manifests[id] {
            if cached.manifest.isFeed {
                feedScheduler.schedule(manifest: cached.manifest, scriptDir: cached.dir, settings: settings) { [weak self] m, d in
                    self?.launchFeedRunWithDepCheck(manifest: m, scriptDir: d)
                }
                launchFeedRunWithDepCheck(manifest: cached.manifest, scriptDir: cached.dir)
            } else {
                launchWithDepCheck(manifest: cached.manifest, scriptDir: cached.dir)
            }
        }
    }

    func retryDependencies(id: String) {
        guard let cached = manifests[id],
              !settings.disabledScripts.contains(id) else { return }
        if cached.manifest.isFeed {
            launchFeedRunWithDepCheck(manifest: cached.manifest, scriptDir: cached.dir)
        } else {
            launchWithDepCheck(manifest: cached.manifest, scriptDir: cached.dir)
        }
    }

    // MARK: - AskScript registry (CloudKit)

    /// Publishes the current state of a script to CloudKit so iOS can enumerate and monitor it.
    private func publishScript(_ manifest: ScriptManifest, status: String,
                               lastRunAt: Date? = nil, nextRunAt: Date? = nil) {
        let scriptType = manifest.isSystem ? "system" : (manifest.isFeed ? "feed" : "tile")
        let record = AskScriptRecord(
            machineID:  machineID,
            scriptID:   manifest.id,
            scriptName: manifest.name,
            scriptType: scriptType,
            scriptIcon: manifest.icon,
            version:    manifest.version,
            status:     status,
            lastRunAt:  lastRunAt,
            nextRunAt:  nextRunAt,
            updatedAt:  Date()
        )
        Task { try? await cloudKit.upsertScript(record) }
    }

    /// Computes the next scheduled run time for a feed script from its cron expression.
    private func computeNextRun(for manifest: ScriptManifest) -> Date? {
        let cronExpr = settings.feedScheduleOverride(for: manifest.id)
            ?? manifest.schedule
            ?? "0 * * * *"
        return CronExpression.nextFireDate(from: cronExpr)
    }

    /// Manually triggers a feed script run. Called when iOS sends an AskInvokeRequest.
    func invokeScript(id: String) {
        guard let cached = manifests[id] else {
            print("[ScriptManager] invokeScript: \(id) not found in manifests")
            return
        }
        guard cached.manifest.isFeed else {
            print("[ScriptManager] invokeScript: \(id) is not a feed script, ignoring")
            return
        }
        print("[ScriptManager] invokeScript: launching feed run for \(id)")
        launchFeedRunWithDepCheck(manifest: cached.manifest, scriptDir: cached.dir)
    }

    // MARK: - Install lock

    /// Stop a running script's connection before its files are replaced on disk.
    /// Does NOT modify the scripts list, settings, or CloudKit state — the script
    /// will be cleanly restarted by reload() after endInstall() completes.
    func stopScriptForUpdate(id: String) {
        connections[id]?.stop()
        connections.removeValue(forKey: id)
        systemConnections[id]?.stop()
        systemConnections.removeValue(forKey: id)
        feedScheduler.cancel(scriptID: id)
        feedTimeoutTasks[id]?.cancel()
        feedTimeoutTasks.removeValue(forKey: id)
        launchingScripts.remove(id)
        restartDelays.removeValue(forKey: id)
    }

    /// Call before starting an install to block file-watcher reloads mid-install.
    func beginInstall() {
        installLockCount += 1
    }

    /// Call after install completes (success or failure). Flushes any deferred reload.
    func endInstall() {
        installLockCount = max(0, installLockCount - 1)
        if installLockCount == 0 {
            // Cancel any file-watcher debounce that fired during the install.
            // Without this, the stale work item calls reload() ~0.5s after we do,
            // causing double-launch of every newly installed script.
            reloadDebounceWork?.cancel()
            reloadDebounceWork = nil
            pendingReload = false
            reload()
        }
    }

    // MARK: - Private

    private func discoverAndLaunch() {
        let fm = FileManager.default
        // Collect all script directories from all sources; later sources override earlier ones.
        var allDirs: [(dir: URL, manifestURL: URL)] = []
        var seen: [String: Int] = [:]  // scriptID → index in allDirs
        for sourceDir in scriptDirs() {
            guard let subdirs = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in subdirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                // Skip rollback backup directories (created by ScriptInstaller on update)
                guard !dir.lastPathComponent.hasSuffix(".previous") else { continue }
                let manifestURL = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(ScriptManifest.self, from: data)
                else { continue }
                if let existing = seen[manifest.id] {
                    allDirs[existing] = (dir, manifestURL)  // vault overrides bundled
                } else {
                    seen[manifest.id] = allDirs.count
                    allDirs.append((dir, manifestURL))
                }
            }
        }

        for (dir, _) in allDirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(ScriptManifest.self, from: data)
            else { continue }
            let iconCandidate = manifest.iconFile ?? "icon.svg"
            let iconURL = dir.appendingPathComponent(iconCandidate)
            let resolvedIcon = iconURL.resolvingSymlinksInPath()
            let resolvedDirForIcon = dir.resolvingSymlinksInPath()
            let iconInBounds = resolvedIcon.path.hasPrefix(resolvedDirForIcon.path + "/")
                            || resolvedIcon.path == resolvedDirForIcon.path
            let iconImage: NSImage? = iconInBounds ? NSImage(contentsOf: iconURL) : nil
            let svgString: String? = iconInBounds && iconURL.pathExtension.lowercased() == "svg"
                ? try? String(contentsOf: iconURL, encoding: .utf8)
                : nil
            manifests[manifest.id] = (manifest, dir, iconImage, svgString)

            // System scripts: launch as persistent background service, not shown in UI.
            if manifest.isSystem {
                launchSystemWithDepCheck(manifest: manifest, scriptDir: dir)
                continue
            }

            let isEnabled = !settings.disabledScripts.contains(manifest.id)
            if isEnabled {
                if manifest.isFeed {
                    feedScheduler.schedule(manifest: manifest, scriptDir: dir, settings: settings) { [weak self] m, d in
                        self?.launchFeedRunWithDepCheck(manifest: m, scriptDir: d)
                    }
                    launchFeedRunWithDepCheck(manifest: manifest, scriptDir: dir)
                } else {
                    launchWithDepCheck(manifest: manifest, scriptDir: dir)
                }
            } else {
                upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .stopped, isEnabled: false)
            }
        }
    }

    private func launch(manifest: ScriptManifest, scriptDir: URL) {
        // Defense in depth: stop any orphaned connection before launching a new one.
        // Normally launchWithDepCheck's guard prevents double-launch, but if something
        // slips through we don't want two processes running for the same script.
        if let orphan = connections[manifest.id] {
            orphan.stop()
            connections.removeValue(forKey: manifest.id)
            activeBlocks.removeValue(forKey: manifest.id)
        }

        let entryURL = scriptDir.appendingPathComponent(manifest.entry)
        let fm = FileManager.default

        // Reject path traversal: resolved path must stay within scriptDir
        let resolvedEntry = entryURL.resolvingSymlinksInPath()
        let resolvedDir   = scriptDir.resolvingSymlinksInPath()
        guard resolvedEntry.path.hasPrefix(resolvedDir.path + "/") || resolvedEntry.path == resolvedDir.path else {
            print("[ScriptManager] \(manifest.id): path traversal rejected for entry '\(manifest.entry)'")
            return
        }

        let canRun = fm.isExecutableFile(atPath: entryURL.path)
            || entryURL.pathExtension == "py"
            || entryURL.pathExtension == "sh"

        // Use cached icon (already loaded in discoverAndLaunch)
        let iconImage = manifests[manifest.id]?.icon

        guard canRun else {
            print("[ScriptManager] \(manifest.id): entry not runnable at \(entryURL.path)")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .stopped, isEnabled: true)
            return
        }

        let iconData = iconImage.flatMap { ScriptManager.iconPNGBase64($0) }
        let svgString = manifests[manifest.id]?.svgString
        let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData, scriptIconSVG: svgString, scriptType: "tile")
        let taskService = TaskService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData)
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService, terminalMonitor: terminalMonitor, taskService: taskService)

        // Expose system script tools in tools/list so scripts can discover them.
        conn.systemTools = manifests.values
            .filter { $0.manifest.isSystem }
            .flatMap { cached -> [[String: Any]] in
                guard let tools = cached.manifest.tools else { return [] }
                return tools.map { tool in
                    var entry: [String: Any] = ["name": tool.name]
                    if let desc = tool.description { entry["description"] = desc }
                    if let params = tool.params, !params.isEmpty {
                        let props = params.reduce(into: [String: Any]()) { dict, p in
                            dict[p.name] = ["type": p.type ?? "string"]
                        }
                        let required = params.filter { $0.required == true }.map(\.name)
                        var schema: [String: Any] = ["type": "object", "properties": props]
                        if !required.isEmpty { schema["required"] = required }
                        entry["inputSchema"] = schema
                    }
                    return entry
                }
            }

        // Route unknown tool calls to system scripts via their declared tool list.
        conn.systemProxy = { [weak self] toolName, args in
            guard let self else { return nil }
            let sysConn = await MainActor.run { [weak self] in
                guard let self,
                      let sysID = self.manifests.first(where: { _, cached in
                          cached.manifest.isSystem &&
                          (cached.manifest.tools?.contains { $0.name == toolName } ?? false)
                      })?.key
                else { return nil as SystemScriptConnection? }
                return self.systemConnections[sysID]
            }
            guard let sysConn else { return nil }
            return try? await sysConn.callTool(toolName, args: args)
        }

        conn.onTerminate = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCrash(manifest: manifest, scriptDir: scriptDir)
            }
        }

        // Forward stderr lines to the script's stderrLog for live display in Settings UI.
        conn.onStderrLine = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.scripts.firstIndex(where: { $0.id == manifest.id }) else { return }
                self.scripts[idx].stderrLog.append(line)
                if self.scripts[idx].stderrLog.count > 50 { self.scripts[idx].stderrLog.removeFirst() }
            }
        }

        // Track live blocks for Mac-side preview
        activeBlocks.removeValue(forKey: manifest.id)
        conn.onBlockEmitted = { [weak self] block in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeBlocks[manifest.id, default: [:]][block.id] = block
                if let idx = self.scripts.firstIndex(where: { $0.id == manifest.id }) {
                    self.scripts[idx].lastEmitTime = Date()
                }
                // Record emission with title/options extracted from payload
                let (title, options) = Self.extractBlockContext(payloadJSON: block.payloadJSON, blockType: block.blockType)
                self.actionHistory.recordBlockEmitted(
                    scriptName: manifest.name,
                    blockID: block.id,
                    blockType: block.blockType,
                    title: title,
                    options: options,
                    payloadJSON: block.payloadJSON
                )
            }
        }
        conn.onBlockCleared = { [weak self] blockID in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id]?.removeValue(forKey: blockID)
            }
        }

        connections[manifest.id] = conn
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .starting, isEnabled: true)

        conn.start()
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .running, isEnabled: true)

        let wasRestart = (restartDelays[manifest.id] ?? 0) > 0
        actionHistory.recordScriptStarted(
            scriptName: manifest.name,
            scriptVersion: manifest.version,
            afterCrash: wasRestart
        )
        print("[ScriptManager] \(manifest.id) started (v\(manifest.version ?? "?"), afterCrash=\(wasRestart))")

        // Run setup check in the background if this script has a setup script
        if manifest.setup != nil || !(manifest.config ?? []).isEmpty {
            runSetupCheck(id: manifest.id)
        }
    }

    // MARK: - Feed script lifecycle

    private func launchFeedRun(manifest: ScriptManifest, scriptDir: URL) {
        let entryURL = scriptDir.appendingPathComponent(manifest.entry)
        let fm = FileManager.default

        let resolvedEntry = entryURL.resolvingSymlinksInPath()
        let resolvedDir   = scriptDir.resolvingSymlinksInPath()
        guard resolvedEntry.path.hasPrefix(resolvedDir.path + "/") || resolvedEntry.path == resolvedDir.path else {
            print("[ScriptManager] \(manifest.id): path traversal rejected")
            return
        }

        let canRun = fm.isExecutableFile(atPath: entryURL.path)
            || entryURL.pathExtension == "py"
            || entryURL.pathExtension == "sh"
        guard canRun else {
            print("[ScriptManager] \(manifest.id): entry not runnable")
            return
        }

        let iconImage = manifests[manifest.id]?.icon
        let iconData  = iconImage.flatMap { ScriptManager.iconPNGBase64($0) }
        let svgString = manifests[manifest.id]?.svgString
        let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData, scriptIconSVG: svgString, scriptType: "feed")
        let taskService = TaskService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData)
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService, terminalMonitor: terminalMonitor, taskService: taskService)

        conn.onTerminate = { [weak self, weak conn] in
            DispatchQueue.main.async {
                self?.handleFeedExit(manifest: manifest, scriptDir: scriptDir, conn: conn)
            }
        }

        // Forward stderr lines to the script's stderrLog for live display in Settings UI.
        conn.onStderrLine = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.scripts.firstIndex(where: { $0.id == manifest.id }) else { return }
                self.scripts[idx].stderrLog.append(line)
                if self.scripts[idx].stderrLog.count > 50 { self.scripts[idx].stderrLog.removeFirst() }
            }
        }

        activeBlocks.removeValue(forKey: manifest.id)
        conn.onBlockEmitted = { [weak self] block in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeBlocks[manifest.id, default: [:]][block.id] = block
                if let idx = self.scripts.firstIndex(where: { $0.id == manifest.id }) {
                    self.scripts[idx].lastEmitTime = Date()
                }
                let (title, options) = Self.extractBlockContext(payloadJSON: block.payloadJSON, blockType: block.blockType)
                self.actionHistory.recordBlockEmitted(
                    scriptName: manifest.name,
                    blockID: block.id,
                    blockType: block.blockType,
                    title: title,
                    options: options,
                    payloadJSON: block.payloadJSON
                )
            }
        }
        conn.onBlockCleared = { [weak self] blockID in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id]?.removeValue(forKey: blockID)
            }
        }

        connections[manifest.id] = conn
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .running, isEnabled: true)
        publishScript(manifest, status: "running")
        conn.start()

        // Feed execution timeout: kill the run if it exceeds the configured limit.
        let timeoutSecs = Double(manifest.timeoutSeconds ?? 300)
        let timeoutTask = Task { @MainActor [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(timeoutSecs))
            guard !Task.isCancelled else { return }
            guard let self, let conn, self.connections[manifest.id] === conn else { return }
            print("[ScriptManager] \(manifest.id): feed run timed out after \(Int(timeoutSecs))s — terminating")
            conn.stop()
            // onTerminate will fire → handleFeedExit with non-zero exit
        }
        feedTimeoutTasks[manifest.id] = timeoutTask

        print("[ScriptManager] \(manifest.id): feed run started (timeout=\(Int(timeoutSecs))s)")
    }

    private func handleFeedExit(manifest: ScriptManifest, scriptDir: URL, conn: MCPConnection?) {
        guard !settings.disabledScripts.contains(manifest.id) else { return }

        // Cancel any pending timeout for this feed run
        feedTimeoutTasks.removeValue(forKey: manifest.id)?.cancel()

        let exitCode = conn?.exitCode ?? 0
        let bySignal = conn?.exitedBySignal ?? false
        let stderr   = conn?.lastStderrSummary ?? "no output"

        // Only clear the connections entry if it's still this connection (not a replacement)
        if connections[manifest.id] === conn {
            connections.removeValue(forKey: manifest.id)
            activeBlocks.removeValue(forKey: manifest.id)
        }

        if exitCode == 0 {
            print("[ScriptManager] \(manifest.id): feed run completed cleanly")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: manifests[manifest.id]?.icon, status: .stopped, isEnabled: true)
            if let m = manifests[manifest.id]?.manifest {
                publishScript(m, status: "idle", lastRunAt: Date(), nextRunAt: computeNextRun(for: m))
            }
        } else {
            let reason = bySignal ? "signal \(exitCode)" : "exit \(exitCode)"
            print("[ScriptManager] \(manifest.id): feed run failed (\(reason)) — last stderr: \(stderr)")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: manifests[manifest.id]?.icon, status: .crashed, isEnabled: true)
            if let m = manifests[manifest.id]?.manifest {
                publishScript(m, status: "crashed", lastRunAt: Date())
            }
            let feedIconData  = manifests[manifest.id]?.icon.flatMap { ScriptManager.iconPNGBase64($0) }
            let feedSvgString = manifests[manifest.id]?.svgString
            Task {
                let bs = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: feedIconData, scriptIconSVG: feedSvgString, scriptType: "feed")
                let payload: [String: Any] = ["title": "\(manifest.name) failed", "body": "Feed script exited with code \(exitCode)"]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let json = String(data: data, encoding: .utf8) {
                    try? await bs.emitBlock(blockID: "\(manifest.id)-error", blockType: "alert", payload: json, expiresAt: Date().addingTimeInterval(3600))
                }
            }
        }
    }

    private func handleCrash(manifest: ScriptManifest, scriptDir: URL) {
        // Don't restart if the script was disabled
        guard !settings.disabledScripts.contains(manifest.id) else { return }

        // Capture all stderr lines and exit info before removing the connection
        let conn = connections[manifest.id]
        let allStderrLines = conn?.allStderrLines ?? []
        let exitCode       = conn?.exitCode ?? 0
        let exitedBySignal = conn?.exitedBySignal ?? false
        let errorSummary   = conn?.lastStderrSummary

        let iconImage = manifests[manifest.id]?.icon
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .crashed, isEnabled: true)
        publishScript(manifest, status: "crashed")
        connections.removeValue(forKey: manifest.id)
        activeBlocks.removeValue(forKey: manifest.id)

        // Surface the last error line in the Mac UI
        if let error = errorSummary, let idx = scripts.firstIndex(where: { $0.id == manifest.id }) {
            scripts[idx].lastError = error
        }

        actionHistory.recordScriptCrash(
            scriptName: manifest.name,
            exitCode: exitCode,
            exitedBySignal: exitedBySignal,
            stderrLines: allStderrLines,
            scriptVersion: manifest.version
        )

        // Circuit breaker: record this crash and check if we've hit the limit
        let now = Date()
        var history = crashHistory[manifest.id] ?? []
        history.append(now)
        history = history.filter { now.timeIntervalSince($0) < Self.circuitBreakerWindow }
        crashHistory[manifest.id] = history

        if history.count >= Self.circuitBreakerLimit {
            crashHistory.removeValue(forKey: manifest.id)
            print("[ScriptManager] \(manifest.id): circuit breaker tripped (\(history.count) crashes in \(Int(Self.circuitBreakerWindow))s)")
            tripCircuitBreaker(manifest: manifest)
            return
        }

        let delay = restartDelays[manifest.id] ?? 1.0
        restartDelays[manifest.id] = min(delay * 2, 30.0)

        let reason = exitedBySignal ? "signal \(exitCode)" : "exit \(exitCode)"
        print("[ScriptManager] \(manifest.id) crashed (\(reason)) — restarting in \(Int(delay))s")

        // Emit alert to iOS so user sees it on iPhone
        let alertBody = errorSummary ?? "Script exited unexpectedly"
        let iconData = manifests[manifest.id]?.icon.flatMap { ScriptManager.iconPNGBase64($0) }
        let svgString = manifests[manifest.id]?.svgString
        Task {
            let bs = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData, scriptIconSVG: svgString)
            let payload: [String: Any] = ["title": "\(manifest.name) stopped", "body": alertBody]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                try? await bs.emitBlock(
                    blockID: "\(manifest.id)-crash",
                    blockType: "alert",
                    payload: json,
                    expiresAt: Date().addingTimeInterval(3600)
                )
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !self.settings.disabledScripts.contains(manifest.id) else { return }
            self.launch(manifest: manifest, scriptDir: scriptDir)
        }
    }

    private func tripCircuitBreaker(manifest: ScriptManifest) {
        settings.setScriptEnabled(manifest.id, enabled: false)
        if let idx = scripts.firstIndex(where: { $0.id == manifest.id }) {
            scripts[idx].isEnabled = false
            scripts[idx].status = .stopped
            scripts[idx].lastError = "Auto-disabled: crashed \(Self.circuitBreakerLimit) times in \(Int(Self.circuitBreakerWindow / 60)) minutes"
        }
        let iconData  = manifests[manifest.id]?.icon.flatMap { ScriptManager.iconPNGBase64($0) }
        let svgString = manifests[manifest.id]?.svgString
        Task {
            let bs = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id,
                                  scriptName: manifest.name, scriptIcon: manifest.icon,
                                  scriptIconData: iconData, scriptIconSVG: svgString)
            let payload: [String: Any] = [
                "title": "\(manifest.name) auto-disabled",
                "body": "Script crashed \(Self.circuitBreakerLimit) times in \(Int(Self.circuitBreakerWindow / 60)) minutes and was disabled. Re-enable it in Settings."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                try? await bs.emitBlock(blockID: "\(manifest.id)-circuit-breaker", blockType: "alert",
                                        payload: json, expiresAt: Date().addingTimeInterval(86400))
            }
        }
    }

    // MARK: - Dependency checking

    private func launchWithDepCheck(manifest: ScriptManifest, scriptDir: URL) {
        guard !launchingScripts.contains(manifest.id) else {
            print("[ScriptManager] \(manifest.id): launch already in-flight, skipping duplicate")
            return
        }
        launchingScripts.insert(manifest.id)
        Task { @MainActor in
            defer { self.launchingScripts.remove(manifest.id) }
            let failed = await checkDependencies(manifest)
            guard !self.settings.disabledScripts.contains(manifest.id) else { return }
            if !failed.isEmpty {
                self.handleMissingDependencies(manifest: manifest, failed: failed)
            } else {
                self.clearMissingDepsState(manifest: manifest)
                self.launch(manifest: manifest, scriptDir: scriptDir)
            }
        }
    }

    private func launchFeedRunWithDepCheck(manifest: ScriptManifest, scriptDir: URL) {
        guard !launchingScripts.contains(manifest.id) else {
            print("[ScriptManager] \(manifest.id): feed launch already in-flight, skipping duplicate")
            return
        }
        launchingScripts.insert(manifest.id)
        Task { @MainActor in
            defer { self.launchingScripts.remove(manifest.id) }
            let failed = await checkDependencies(manifest)
            guard !self.settings.disabledScripts.contains(manifest.id) else { return }
            if !failed.isEmpty {
                self.handleMissingDependencies(manifest: manifest, failed: failed)
            } else {
                self.clearMissingDepsState(manifest: manifest)
                self.launchFeedRun(manifest: manifest, scriptDir: scriptDir)
            }
        }
    }

    // MARK: - System script lifecycle

    private func launchSystemWithDepCheck(manifest: ScriptManifest, scriptDir: URL) {
        guard !launchingScripts.contains(manifest.id) else {
            print("[ScriptManager] \(manifest.id): system launch already in-flight, skipping duplicate")
            return
        }
        launchingScripts.insert(manifest.id)
        Task { @MainActor in
            defer { self.launchingScripts.remove(manifest.id) }
            let failed = await checkDependencies(manifest)
            if !failed.isEmpty {
                print("[ScriptManager] \(manifest.id): system script missing deps — \(failed.map(\.name).joined(separator: ", "))")
            } else {
                self.launchSystem(manifest: manifest, scriptDir: scriptDir)
            }
        }
    }

    private func launchSystem(manifest: ScriptManifest, scriptDir: URL) {
        let entryURL = scriptDir.appendingPathComponent(manifest.entry)
        let fm = FileManager.default

        let resolvedEntry = entryURL.resolvingSymlinksInPath()
        let resolvedDir   = scriptDir.resolvingSymlinksInPath()
        guard resolvedEntry.path.hasPrefix(resolvedDir.path + "/") || resolvedEntry.path == resolvedDir.path else {
            print("[ScriptManager] \(manifest.id): path traversal rejected")
            return
        }

        let canRun = fm.isExecutableFile(atPath: entryURL.path)
            || entryURL.pathExtension == "py"
            || entryURL.pathExtension == "sh"
        guard canRun else {
            print("[ScriptManager] \(manifest.id): entry not runnable at \(entryURL.path)")
            return
        }

        systemConnections[manifest.id]?.stop()
        let conn = SystemScriptConnection(scriptID: manifest.id, entryURL: entryURL)

        conn.onTerminate = { [weak self, weak conn] in
            guard let self else { return }
            guard self.systemConnections[manifest.id] === conn else { return }
            self.systemConnections.removeValue(forKey: manifest.id)
            self.upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon,
                              iconImage: self.manifests[manifest.id]?.icon, status: .crashed, isEnabled: true)
            let delay = self.restartDelays[manifest.id] ?? 1.0
            self.restartDelays[manifest.id] = min(delay * 2, 30.0)
            print("[ScriptManager] System script \(manifest.id) terminated — restarting in \(Int(delay))s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.launchSystem(manifest: manifest, scriptDir: scriptDir)
            }
        }

        systemConnections[manifest.id] = conn
        conn.start()
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon,
                     iconImage: manifests[manifest.id]?.icon, status: .running, isEnabled: true)
        print("[ScriptManager] System script running: \(manifest.id)")
    }

    private func checkDependencies(_ manifest: ScriptManifest) async -> [ScriptDependency] {
        guard let requires = manifest.requires, !requires.isEmpty else { return [] }
        var failed: [ScriptDependency] = []
        for dep in requires {
            if settings.isDepCheckSkipped(scriptID: manifest.id, depID: dep.id) { continue }
            let passed = await runDepCheck(dep)
            if !passed { failed.append(dep) }
        }
        return failed
    }

    private func runDepCheck(_ dep: ScriptDependency) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", dep.check]
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: false)
                        return
                    }
                    if let minVersion = dep.minVersion {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: ScriptManager.versionSatisfied(output: output, minVersion: minVersion))
                    } else {
                        continuation.resume(returning: true)
                    }
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func versionSatisfied(output: String, minVersion: String) -> Bool {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges >= 4,
              let r1 = Range(match.range(at: 1), in: output),
              let r2 = Range(match.range(at: 2), in: output),
              let r3 = Range(match.range(at: 3), in: output),
              let foundMajor = Int(output[r1]),
              let foundMinor = Int(output[r2]),
              let foundPatch = Int(output[r3])
        else { return true } // can't parse version — treat as satisfied

        let parts = minVersion.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return true }
        if foundMajor != parts[0] { return foundMajor > parts[0] }
        if foundMinor != parts[1] { return foundMinor > parts[1] }
        return foundPatch >= parts[2]
    }

    private func handleMissingDependencies(manifest: ScriptManifest, failed: [ScriptDependency]) {
        let iconImage = manifests[manifest.id]?.icon
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage,
                     status: .missingDependencies, isEnabled: true)
        if let idx = scripts.firstIndex(where: { $0.id == manifest.id }) {
            scripts[idx].missingDeps = failed
        }
        let depNames = failed.map(\.name)
        print("[ScriptManager] \(manifest.id): missing dependencies — \(depNames.joined(separator: ", "))")
        actionHistory.recordDependencyMissing(scriptName: manifest.name, missingDeps: depNames)
        let iconData  = iconImage.flatMap { ScriptManager.iconPNGBase64($0) }
        let svgString = manifests[manifest.id]?.svgString
        Task {
            let bs = BlockService(cloudKit: cloudKit, machineID: machineID,
                                  scriptID: manifest.id, scriptName: manifest.name,
                                  scriptIcon: manifest.icon, scriptIconData: iconData,
                                  scriptIconSVG: svgString)
            let payload: [String: Any] = [
                "label": "\(manifest.name) unavailable",
                "value": "\(depNames) not installed",
                "color": "orange"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                try? await bs.emitBlock(blockID: "\(manifest.id)-missing-dep",
                                        blockType: "status", payload: json,
                                        expiresAt: Date().addingTimeInterval(86400))
            }
        }
    }

    private func clearMissingDepsState(manifest: ScriptManifest) {
        if let idx = scripts.firstIndex(where: { $0.id == manifest.id }),
           scripts[idx].status == .missingDependencies {
            scripts[idx].missingDeps = []
        }
    }

    // MARK: - Shell PATH helpers

    /// Returns an augmented PATH string that includes common user binary locations
    /// (e.g. ~/.local/bin, ~/bin, homebrew) that GUI apps miss because they don't
    /// source ~/.zshrc. Used when launching setup scripts.
    private static func augmentedShellPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.opencode/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return extras.joined(separator: ":") + (existing.isEmpty ? "" : ":\(existing)")
    }

    // MARK: - Block payload helpers

    /// Extracts a human-readable title and option list from a block's JSON payload.
    /// Returns `(title, options)` — either may be nil if the payload doesn't contain them.
    static func extractBlockContext(payloadJSON: String, blockType: String) -> (title: String?, options: [String]?) {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }

        // Title: try common keys in order
        let title = (dict["title"] as? String)
            ?? (dict["message"] as? String)
            ?? (dict["body"] as? String)

        // Options: picker/confirmation/list blocks use different keys
        var options: [String]? = nil
        if let arr = dict["options"] as? [[String: Any]] {
            // picker-style: [{label: "...", value: "..."}, ...]
            options = arr.compactMap { $0["label"] as? String }
        } else if let arr = dict["options"] as? [String] {
            options = arr
        } else if let arr = dict["choices"] as? [String] {
            options = arr
        } else if blockType == "confirmation" {
            // Implicit binary options
            options = ["Confirm", "Deny"]
        }

        return (title, options?.isEmpty == true ? nil : options)
    }

    // MARK: - Icon helpers

    /// Renders `image` at 32×32, encodes as PNG, returns base64 string.
    private static func iconPNGBase64(_ image: NSImage) -> String? {
        let size = NSSize(width: 32, height: 32)
        let offscreen = NSImage(size: size)
        offscreen.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1.0)
        offscreen.unlockFocus()
        guard let tiff = offscreen.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }

    private func upsertStatus(_ id: String, name: String, icon: String?, iconImage: NSImage?, status: ManagedScript.ScriptStatus, isEnabled: Bool) {
        let manifest = manifests[id]?.manifest
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].status = status
            scripts[idx].isEnabled = isEnabled
            if let img = iconImage { scripts[idx].iconImage = img }
        } else {
            let svgString = manifests[id]?.svgString
            let dir = manifests[id]?.dir
            let bundledScriptsPath = Bundle.main.resourceURL?.appendingPathComponent("Scripts").path
            let isBundled: Bool = {
                guard let bundledPath = bundledScriptsPath, let d = dir else { return false }
                return d.path.hasPrefix(bundledPath)
            }()
            scripts.append(ManagedScript(
                id: id, name: name, version: manifest?.version,
                description: manifest?.description, icon: icon, iconImage: iconImage,
                svgString: svgString, status: status, isEnabled: isEnabled,
                scriptType: manifest?.type, schedule: manifest?.schedule,
                requires: manifest?.requires ?? [], tools: manifest?.tools ?? [],
                entry: manifest?.entry,
                manifestPath: dir.map { $0.appendingPathComponent("manifest.json") },
                setupScript: manifest?.setup,
                configItems: manifest?.config ?? [],
                isBundled: isBundled
            ))
        }
    }

    // MARK: - Setup checks

    /// Runs `setup.py --check` and updates the script's setupChecks array.
    func runSetupCheck(id: String) {
        guard let entry = manifests[id],
              let setupFile = entry.manifest.setup
        else { return }

        let setupURL = entry.dir.appendingPathComponent(setupFile)
        guard FileManager.default.fileExists(atPath: setupURL.path) else { return }

        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].setupCheckRunning = true
        }

        let configItems = entry.manifest.config ?? []
        let vaultRoot = entry.dir.deletingLastPathComponent().path

        Task.detached(priority: .utility) { [weak self] in
            let checks = await Self.executeSetupCheck(
                setupURL: setupURL,
                scriptID: id,
                configItems: configItems,
                vaultRoot: vaultRoot
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.scripts.firstIndex(where: { $0.id == id }) {
                    self.scripts[idx].setupChecks = checks
                    self.scripts[idx].setupCheckRunning = false
                    let currentStatus = self.scripts[idx].status
                    if self.scripts[idx].needsSetup {
                        // Surface the problem in the status badge without disrupting an active run
                        if currentStatus == .running || currentStatus == .stopped {
                            self.scripts[idx].status = .needsSetup
                        }
                    } else if currentStatus == .needsSetup {
                        // Checks now pass — restore to the actual runtime state
                        let isActive = self.connections[id] != nil
                        self.scripts[idx].status = isActive ? .running : .stopped
                    }
                }
            }
        }
    }

    private nonisolated static func executeSetupCheck(
        setupURL: URL, scriptID: String,
        configItems: [ScriptConfigItem], vaultRoot: String
    ) async -> [SetupCheck] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [setupURL.path, "--check"]

                // Build env: inherit + augmented PATH + config secrets + vault on PYTHONPATH
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = Self.augmentedShellPath()
                env["PYTHONPATH"] = vaultRoot + (env["PYTHONPATH"].map { ":\($0)" } ?? "")
                for item in configItems {
                    if let val = KeychainService.shared.get(scriptID: scriptID, key: item.key) {
                        env["ASK_CONFIG_\(item.key.uppercased())"] = val
                    }
                }
                process.environment = env
                process.currentDirectoryURL = setupURL.deletingLastPathComponent()

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    // 30-second timeout for setup --check
                    let timeoutTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        if process.isRunning { process.terminate() }
                    }
                    process.waitUntilExit()
                    timeoutTask.cancel()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    // Decode into local nonisolated mirror types to avoid using an actor-isolated Decodable conformance.
                    struct RawSetupCheckOutput: Decodable { let checks: [RawSetupCheck] }
                    struct RawSetupCheck: Decodable {
                        let id: String
                        let label: String
                        let ok: Bool
                        let message: String?
                        let fixable: Bool?
                        let needs_terminal: Bool?
                    }
                    if let raw = try? JSONDecoder().decode(RawSetupCheckOutput.self, from: data) {
                        let mapped: [SetupCheck] = raw.checks.map { r in
                            SetupCheck(
                                id: r.id,
                                label: r.label,
                                ok: r.ok,
                                message: r.message,
                                fixable: r.fixable,
                                needsTerminal: r.needs_terminal
                            )
                        }
                        continuation.resume(returning: mapped)
                    } else {
                        continuation.resume(returning: [])
                    }
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Opens the setup script in an in-app streaming sheet (non-terminal path).
    /// The caller is responsible for showing the UI; this returns an AsyncStream of output lines.
    func setupInstallStream(id: String) -> AsyncStream<String> {
        guard let entry = manifests[id], let setupFile = entry.manifest.setup else {
            return AsyncStream { $0.finish() }
        }
        let setupURL = entry.dir.appendingPathComponent(setupFile)
        let configItems = entry.manifest.config ?? []
        let vaultRoot = entry.dir.deletingLastPathComponent().path
        let scriptID = id

        // Pre-capture keychain values on current actor before entering Task.detached.
        var configEnv: [String: String] = [:]
        for item in configItems {
            if let val = KeychainService.shared.get(scriptID: scriptID, key: item.key) {
                configEnv["ASK_CONFIG_\(item.key.uppercased())"] = val
            }
        }

        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                var env = ProcessInfo.processInfo.environment
                env["PYTHONPATH"] = vaultRoot + (env["PYTHONPATH"].map { ":\($0)" } ?? "")
                for (key, val) in configEnv {
                    env[key] = val
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [setupURL.path, "--install"]
                process.environment = env
                process.currentDirectoryURL = setupURL.deletingLastPathComponent()

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = outPipe  // merge stderr into output stream

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                    for l in line.components(separatedBy: "\n") where !l.isEmpty {
                        continuation.yield(l)
                    }
                }

                do {
                    try process.run()
                    // 5-minute timeout for setup --install
                    let timeoutTask = Task {
                        try? await Task.sleep(for: .seconds(300))
                        if process.isRunning {
                            process.terminate()
                            continuation.yield("⚠️ Setup timed out after 5 minutes")
                        }
                    }
                    process.waitUntilExit()
                    timeoutTask.cancel()
                } catch {
                    continuation.yield("Error: \(error.localizedDescription)")
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }
        }
    }

    /// Opens the setup script in Terminal.app for interactive installs.
    func setupInstallInTerminal(id: String) {
        guard let entry = manifests[id], let setupFile = entry.manifest.setup else { return }
        let setupURL = entry.dir.appendingPathComponent(setupFile)
        let dir = setupURL.deletingLastPathComponent().path
        let cmd = "cd \(dir.shellEscaped) && python3 \(setupFile.shellEscaped) --install; echo; read -p 'Press Enter to close…'"
        let appleScript = "tell application \"Terminal\" to do script \"\(cmd)\""
        NSAppleScript(source: appleScript)?.executeAndReturnError(nil)
    }

    // MARK: - Vault file watcher

    private func startVaultWatcher() {
        var paths: [String] = []
        if settings.usesBundledScripts,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("Scripts") {
            paths.append(bundled.path)
        }
        if let vault = settings.vaultPath {
            paths.append(vault.path)
        }
        guard !paths.isEmpty else { return }
        vaultWatcher = VaultWatcher(paths: paths) { [weak self] in
            DispatchQueue.main.async { self?.scheduleVaultReload() }
        }
        print("[ScriptManager] Vault watcher started: \(paths.joined(separator: ", "))")
    }

    @MainActor
    private func scheduleVaultReload() {
        reloadDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.installLockCount > 0 {
                self.pendingReload = true
            } else {
                self.reload()
            }
        }
        reloadDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - VaultWatcher

/// Watches a set of paths (recursively) for file system changes using FSEventStream.
/// The `onChange` callback is called on an unspecified queue; callers must dispatch
/// to the appropriate thread themselves.
private final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()

        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        stream = FSEventStreamCreate(
            nil, cb, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // 300 ms latency — coalesces rapid saves
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

// MARK: - Helpers

private extension String {
    /// Single-quote escapes for use in shell commands.
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
