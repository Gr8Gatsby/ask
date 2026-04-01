import Foundation
import SwiftUI

// MARK: - Model

struct ScriptUpdate: Identifiable {
    let id: String              // script folder name (matches manifest "id")
    let name: String
    let bundledVersion: String
    let vaultVersion: String

    var displayDescription: String {
        "\(name): \(vaultVersion) → \(bundledVersion)"
    }
}

// MARK: - Service

@MainActor
@Observable
final class ScriptUpdateService {
    private(set) var pendingUpdates: [ScriptUpdate] = []
    var showUpdatePrompt = false

    private let vaultURL: URL

    init() {
        let expanded = ("~/.ask/scripts" as NSString).expandingTildeInPath
        self.vaultURL = URL(fileURLWithPath: expanded)
    }

    // Call once at launch.
    func checkForUpdates() {
        guard let scriptsURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts") else { return }

        var found: [ScriptUpdate] = []

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: scriptsURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.hasDirectoryPath {
            let scriptID = entry.lastPathComponent
            guard let bundledVersion = manifestVersion(at: entry) else { continue }

            let vaultScriptURL = vaultURL.appendingPathComponent(scriptID)
            guard fm.fileExists(atPath: vaultScriptURL.path),
                  let vaultVersion = manifestVersion(at: vaultScriptURL) else { continue }

            if compareVersions(bundledVersion, vaultVersion) > 0 {
                let name = manifestName(at: entry) ?? scriptID
                found.append(ScriptUpdate(
                    id: scriptID,
                    name: name,
                    bundledVersion: bundledVersion,
                    vaultVersion: vaultVersion
                ))
            }
        }

        pendingUpdates = found
        if !found.isEmpty {
            showUpdatePrompt = true
        }
    }

    func applyUpdates(_ updates: [ScriptUpdate]) {
        let fm = FileManager.default
        guard let scriptsURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts") else { return }

        for update in updates {
            let src = scriptsURL.appendingPathComponent(update.id)
            let dst = vaultURL.appendingPathComponent(update.id)

            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
            } catch {
                print("ScriptUpdateService: failed to update \(update.id): \(error)")
            }
        }

        pendingUpdates.removeAll { u in updates.contains { $0.id == u.id } }
        showUpdatePrompt = !pendingUpdates.isEmpty
    }

    func dismissUpdates() {
        showUpdatePrompt = false
    }

    // MARK: - Helpers

    private func manifestVersion(at url: URL) -> String? {
        let manifest = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        return version
    }

    private func manifestName(at url: URL) -> String? {
        let manifest = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return name
    }

    /// Returns 1 if a > b, -1 if a < b, 0 if equal.
    /// Compares dot-separated numeric components (e.g. "2.13.3" vs "2.1").
    private func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv ? 1 : -1 }
        }
        return 0
    }
}
