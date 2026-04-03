import AppKit
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

struct ScriptManifest: Codable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let entry: String       // relative path to the executable entry point
    let icon: String?
    let iconFile: String?   // relative path to an image file (SVG/PNG)
    let type: String?       // "tile" (default) or "feed"
    let schedule: String?   // cron expression, e.g. "0 9 * * *" (feed scripts only)
    let requires: [ScriptDependency]?
    let tools: [ScriptTool]?

    var isFeed: Bool { type == "feed" }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, entry, icon, type, schedule, requires, tools
        case iconFile = "icon_file"
    }
}

// MARK: - UI model

struct ManagedScript: Identifiable {
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
    var scriptType: String?              // "tile" (default) or "feed"
    var schedule: String?               // cron expression for feed scripts
    var requires: [ScriptDependency] = [] // all declared dependencies
    var tools: [ScriptTool] = []         // public tools declared in manifest
    var entry: String?                  // manifest entry point (relative path)
    var manifestPath: URL?              // path to the manifest.json file

    enum ScriptStatus {
        case starting, running, crashed, stopped, missingDependencies

        var label: String {
            switch self {
            case .starting:             "Starting"
            case .running:              "Running"
            case .crashed:              "Crashed"
            case .stopped:              "Stopped"
            case .missingDependencies:  "Missing dependencies"
            }
        }
    }
}

// MARK: - Manager

/// Discovers scripts under ~/.ask/scripts/*/manifest.json, launches each one
/// as a subprocess via MCPConnection, and auto-restarts on crash.
@Observable
final class ScriptManager {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let settings: AppSettings

    private(set) var scripts: [ManagedScript] = []
    /// Live blocks currently emitted by each script, keyed by scriptID → blockID.
    private(set) var activeBlocks: [String: [String: LiveBlock]] = [:]

    // Internal — not exposed to UI
    private var connections: [String: MCPConnection] = [:]
    private var restartDelays: [String: TimeInterval] = [:]
    // Cached manifests so we can re-launch after enable
    private var manifests: [String: (manifest: ScriptManifest, dir: URL, icon: NSImage?, svgString: String?)] = [:]

    private let actionHistory: ActionHistoryService
    private let feedScheduler: FeedScheduler
    private let terminalMonitor = TerminalMonitorService()

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
        for (_, conn) in connections { conn.stop() }
        connections = [:]
        feedScheduler.cancelAll()
    }

    /// Rescans the scripts directory, picks up newly discovered scripts, and restarts
    /// all already-tracked enabled scripts (tile scripts restart; feed scripts get an
    /// immediate run if not currently running).
    func reload() {
        let fm = FileManager.default
        // Collect all script directories from all sources; later sources override earlier ones.
        var allDirs: [(dir: URL, manifestURL: URL)] = []
        var seen: [String: Int] = [:]
        for sourceDir in scriptDirs() {
            guard let subdirs = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in subdirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
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

            let isEnabled = !settings.disabledScripts.contains(manifest.id)
            guard isEnabled else {
                upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon,
                             iconImage: iconImage, status: .stopped, isEnabled: false)
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
                // Trigger an immediate run
                launchFeedRunWithDepCheck(manifest: manifest, scriptDir: dir)
            } else {
                // Tile script: stop existing connection then re-launch
                if !isNew, let conn = connections[manifest.id] {
                    conn.stop()
                    connections.removeValue(forKey: manifest.id)
                    activeBlocks.removeValue(forKey: manifest.id)
                }
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
        Task {
            let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: id)
            try? await blockService.clearAllBlocks()
        }
    }

    /// Deliver a user response to a block directly from the Mac UI.
    func respondToBlock(scriptID: String, blockID: String, value: String) {
        connections[scriptID]?.deliverResponse(blockID: blockID, value: value)
        activeBlocks[scriptID]?.removeValue(forKey: blockID)
    }

    func enableScript(id: String) {
        let name = scripts.first(where: { $0.id == id })?.name ?? id
        settings.setScriptEnabled(id, enabled: true)
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = true
        }
        actionHistory.recordScriptToggle(scriptName: name, enabled: true)
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
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService, terminalMonitor: terminalMonitor)

        conn.onTerminate = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCrash(manifest: manifest, scriptDir: scriptDir)
            }
        }

        // Track live blocks for Mac-side preview
        activeBlocks.removeValue(forKey: manifest.id)
        conn.onBlockEmitted = { [weak self] block in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id, default: [:]][block.id] = block
                if let idx = self?.scripts.firstIndex(where: { $0.id == manifest.id }) {
                    self?.scripts[idx].lastEmitTime = Date()
                }
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
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService, terminalMonitor: terminalMonitor)

        conn.onTerminate = { [weak self, weak conn] in
            DispatchQueue.main.async {
                self?.handleFeedExit(manifest: manifest, scriptDir: scriptDir, conn: conn)
            }
        }

        activeBlocks.removeValue(forKey: manifest.id)
        conn.onBlockEmitted = { [weak self] block in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id, default: [:]][block.id] = block
                if let idx = self?.scripts.firstIndex(where: { $0.id == manifest.id }) {
                    self?.scripts[idx].lastEmitTime = Date()
                }
            }
        }
        conn.onBlockCleared = { [weak self] blockID in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id]?.removeValue(forKey: blockID)
            }
        }

        connections[manifest.id] = conn
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .running, isEnabled: true)
        conn.start()
        print("[ScriptManager] \(manifest.id): feed run started")
    }

    private func handleFeedExit(manifest: ScriptManifest, scriptDir: URL, conn: MCPConnection?) {
        guard !settings.disabledScripts.contains(manifest.id) else { return }

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
        } else {
            let reason = bySignal ? "signal \(exitCode)" : "exit \(exitCode)"
            print("[ScriptManager] \(manifest.id): feed run failed (\(reason)) — last stderr: \(stderr)")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: manifests[manifest.id]?.icon, status: .crashed, isEnabled: true)
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

        // Capture last stderr before removing the connection
        let errorSummary = connections[manifest.id]?.lastStderrSummary

        let iconImage = manifests[manifest.id]?.icon
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .crashed, isEnabled: true)
        connections.removeValue(forKey: manifest.id)
        activeBlocks.removeValue(forKey: manifest.id)

        // Surface the error in the Mac UI
        if let error = errorSummary, let idx = scripts.firstIndex(where: { $0.id == manifest.id }) {
            scripts[idx].lastError = error
        }

        actionHistory.recordScriptCrash(scriptName: manifest.name, lastStderr: errorSummary)

        let delay = restartDelays[manifest.id] ?? 1.0
        restartDelays[manifest.id] = min(delay * 2, 30.0)

        print("[ScriptManager] \(manifest.id) crashed — restarting in \(Int(delay))s")

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

    // MARK: - Dependency checking

    private func launchWithDepCheck(manifest: ScriptManifest, scriptDir: URL) {
        Task { @MainActor in
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
        Task { @MainActor in
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
        let depNames = failed.map(\.name).joined(separator: ", ")
        print("[ScriptManager] \(manifest.id): missing dependencies — \(depNames)")
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
            scripts.append(ManagedScript(id: id, name: name, version: manifest?.version, description: manifest?.description, icon: icon, iconImage: iconImage, svgString: svgString, status: status, isEnabled: isEnabled, scriptType: manifest?.type, schedule: manifest?.schedule, requires: manifest?.requires ?? [], tools: manifest?.tools ?? [], entry: manifest?.entry, manifestPath: dir.map { $0.appendingPathComponent("manifest.json") }))
        }
    }
}
