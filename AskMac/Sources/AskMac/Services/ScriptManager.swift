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

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, entry, icon
        case iconFile = "icon_file"
    }
}

// MARK: - UI model

struct ManagedScript: Identifiable {
    let id: String          // manifest.id
    let name: String
    let icon: String?       // SF Symbol fallback
    let iconImage: NSImage? // loaded from icon_file
    var status: ScriptStatus
    var isEnabled: Bool

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

    // Internal — not exposed to UI
    private var connections: [String: MCPConnection] = [:]
    private var restartDelays: [String: TimeInterval] = [:]
    // Cached manifests so we can re-launch after enable
    private var manifests: [String: (manifest: ScriptManifest, dir: URL)] = [:]

    init(cloudKit: CloudKitService, machineID: String, settings: AppSettings) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.settings = settings
        self.scriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask/scripts")
    }

    func start() {
        discoverAndLaunch()
    }

    func stop() {
        for (_, conn) in connections { conn.stop() }
        connections = [:]
    }

    func connection(for scriptID: String) -> MCPConnection? {
        connections[scriptID]
    }

    // MARK: - Private

    func disableScript(id: String) {
        settings.setScriptEnabled(id, enabled: false)
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = false
            scripts[idx].status = .stopped
        }
        connections[id]?.stop()
        connections.removeValue(forKey: id)
        restartDelays.removeValue(forKey: id)
        Task {
            let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: id)
            try? await blockService.clearAllBlocks()
        }
    }

    func enableScript(id: String) {
        settings.setScriptEnabled(id, enabled: true)
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = true
        }
        if let cached = manifests[id] {
            launch(manifest: cached.manifest, scriptDir: cached.dir)
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
            manifests[manifest.id] = (manifest, dir)
            let isEnabled = !settings.disabledScripts.contains(manifest.id)
            if isEnabled {
                launch(manifest: manifest, scriptDir: dir)
            } else {
                upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: nil, status: .stopped, isEnabled: false)
            }
        }
    }

    private func launch(manifest: ScriptManifest, scriptDir: URL) {
        let entryURL = scriptDir.appendingPathComponent(manifest.entry)
        let fm = FileManager.default
        let canRun = fm.isExecutableFile(atPath: entryURL.path)
            || entryURL.pathExtension == "py"
            || entryURL.pathExtension == "sh"

        guard canRun else {
            print("[ScriptManager] \(manifest.id): entry not runnable at \(entryURL.path)")
            upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: nil, status: .stopped, isEnabled: true)
            return
        }

        // Load icon image from icon_file, or try icon.svg by convention
        let iconImage: NSImage? = {
            let candidate = manifest.iconFile ?? "icon.svg"
            let url = scriptDir.appendingPathComponent(candidate)
            return NSImage(contentsOf: url)
        }()

        let blockService = BlockService(cloudKit: cloudKit, machineID: machineID, scriptID: manifest.id)
        let conn = MCPConnection(scriptID: manifest.id, entryURL: entryURL, blockService: blockService)

        conn.onTerminate = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCrash(manifest: manifest, scriptDir: scriptDir)
            }
        }

        connections[manifest.id] = conn
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .starting, isEnabled: true)

        conn.start()
        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: iconImage, status: .running, isEnabled: true)
    }

    private func handleCrash(manifest: ScriptManifest, scriptDir: URL) {
        // Don't restart if the script was disabled
        guard !settings.disabledScripts.contains(manifest.id) else { return }

        upsertStatus(manifest.id, name: manifest.name, icon: manifest.icon, iconImage: nil, status: .crashed, isEnabled: true)
        connections.removeValue(forKey: manifest.id)

        let delay = restartDelays[manifest.id] ?? 1.0
        restartDelays[manifest.id] = min(delay * 2, 30.0)

        print("[ScriptManager] \(manifest.id) crashed — restarting in \(Int(delay))s")

        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !self.settings.disabledScripts.contains(manifest.id) else { return }
            launch(manifest: manifest, scriptDir: scriptDir)
        }
    }

    private func upsertStatus(_ id: String, name: String, icon: String?, iconImage: NSImage?, status: ManagedScript.ScriptStatus, isEnabled: Bool) {
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].status = status
            scripts[idx].isEnabled = isEnabled
        } else {
            scripts.append(ManagedScript(id: id, name: name, icon: icon, iconImage: iconImage, status: status, isEnabled: isEnabled))
        }
    }
}
