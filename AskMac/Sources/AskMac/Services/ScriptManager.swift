import AppKit
import Foundation
import Observation

// MARK: - Manifest

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

    var isFeed: Bool { type == "feed" }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, entry, icon, type, schedule
        case iconFile = "icon_file"
    }
}

// MARK: - UI model

struct ManagedScript: Identifiable {
    let id: String          // manifest.id
    let name: String
    let icon: String?       // SF Symbol fallback
    var iconImage: NSImage? // loaded from icon_file
    var status: ScriptStatus
    var isEnabled: Bool
    var lastError: String?  // last stderr output before most recent crash

    enum ScriptStatus {
        case starting, running, crashed, stopped

        var label: String {
            switch self {
            case .starting: "Starting"
            case .running:  "Running"
            case .crashed:  "Crashed"
            case .stopped:  "Stopped"
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
    private let scriptsDir: URL
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

    init(cloudKit: CloudKitService, machineID: String, settings: AppSettings, actionHistory: ActionHistoryService) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.settings = settings
        self.actionHistory = actionHistory
        self.feedScheduler = FeedScheduler()
        self.scriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask/scripts")
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
        guard let subdirs = try? fm.contentsOfDirectory(
            at: scriptsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for dir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
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
                        self?.launchFeedRun(manifest: m, scriptDir: d)
                    }
                }
                // Trigger an immediate run
                launchFeedRun(manifest: manifest, scriptDir: dir)
            } else {
                // Tile script: stop existing connection then re-launch
                if !isNew, let conn = connections[manifest.id] {
                    conn.stop()
                    connections.removeValue(forKey: manifest.id)
                    activeBlocks.removeValue(forKey: manifest.id)
                }
                launch(manifest: manifest, scriptDir: dir)
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
                    self?.launchFeedRun(manifest: m, scriptDir: d)
                }
                launchFeedRun(manifest: cached.manifest, scriptDir: cached.dir)
            } else {
                launch(manifest: cached.manifest, scriptDir: cached.dir)
            }
        }
    }

    // MARK: - Private

    private func discoverAndLaunch() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: scriptsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for dir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
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
                        self?.launchFeedRun(manifest: m, scriptDir: d)
                    }
                    launchFeedRun(manifest: manifest, scriptDir: dir)
                } else {
                    launch(manifest: manifest, scriptDir: dir)
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
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService)

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
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService)

        conn.onTerminate = { [weak self] in
            DispatchQueue.main.async {
                self?.handleFeedExit(manifest: manifest, scriptDir: scriptDir)
            }
        }

        activeBlocks.removeValue(forKey: manifest.id)
        conn.onBlockEmitted = { [weak self] block in
            Task { @MainActor [weak self] in
                self?.activeBlocks[manifest.id, default: [:]][block.id] = block
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

    private func handleFeedExit(manifest: ScriptManifest, scriptDir: URL) {
        guard !settings.disabledScripts.contains(manifest.id) else { return }

        let exitCode = connections[manifest.id]?.terminationStatus ?? 0
        connections.removeValue(forKey: manifest.id)
        activeBlocks.removeValue(forKey: manifest.id)

        if exitCode == 0 {
            print("[ScriptManager] \(manifest.id): feed run completed cleanly")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: manifests[manifest.id]?.icon, status: .stopped, isEnabled: true)
        } else {
            print("[ScriptManager] \(manifest.id): feed run failed (exit \(exitCode)) — not restarting")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: manifests[manifest.id]?.icon, status: .crashed, isEnabled: true)
            Task {
                let iconData  = manifests[manifest.id]?.icon.flatMap { ScriptManager.iconPNGBase64($0) }
                let svgString = manifests[manifest.id]?.svgString
                let bs = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id, scriptName: manifest.name, scriptIcon: manifest.icon, scriptIconData: iconData, scriptIconSVG: svgString, scriptType: "feed")
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
        Task {
            let iconData = manifests[manifest.id]?.icon.flatMap { ScriptManager.iconPNGBase64($0) }
            let svgString = manifests[manifest.id]?.svgString
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

        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !self.settings.disabledScripts.contains(manifest.id) else { return }
            launch(manifest: manifest, scriptDir: scriptDir)
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
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].status = status
            scripts[idx].isEnabled = isEnabled
            if let img = iconImage { scripts[idx].iconImage = img }
        } else {
            scripts.append(ManagedScript(id: id, name: name, icon: icon, iconImage: iconImage, status: status, isEnabled: isEnabled))
        }
    }
}
