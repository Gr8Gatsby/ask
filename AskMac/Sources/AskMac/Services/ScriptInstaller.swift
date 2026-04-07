import AskMacCore
import Foundation
import SwiftUI

// MARK: - ScriptInstaller

@Observable
final class ScriptInstaller {

    // MARK: Types

    enum InstallKind {
        case fresh       // ID not in vault
        case update      // ID in vault, incoming version is newer
        case downgrade   // ID in vault, incoming version is older — show warning
        case reinstall   // ID in vault, same version
    }

    struct PendingScript: Identifiable {
        let id: String
        let name: String
        let version: String
        let description: String
        let icon: String?
        let iconImage: NSImage?      // loaded from icon_file / icon.svg in the zip
        let svgString: String?       // raw SVG markup for dark-mode colour inversion
        let scriptType: String?
        let sourceDir: URL
        let installKind: InstallKind
        let existingVersion: String?
        let warnings: [String]       // non-blocking issues surfaced in the sheet
    }

    struct SkippedScript: Identifiable {
        var id = UUID()
        let folderName: String
        let reason: String
    }

    enum Phase { case idle, parsing, ready, installing, done }

    // MARK: State

    var phase: Phase = .idle
    var pending: [PendingScript] = []
    var skipped: [SkippedScript] = []
    var errorMessage: String?
    var showSheet = false
    var installProgressLabel: String?

    private var tempDir: URL?

    // MARK: Entry points

    func load(zipURL: URL, existingScripts: [ManagedScript]) {
        Task { await parse(zipURL: zipURL, existingScripts: existingScripts) }
    }

    func cancel() {
        cleanup()
        reset()
    }

    // MARK: - Parsing

    @MainActor
    private func parse(zipURL: URL, existingScripts: [ManagedScript]) async {
        phase = .parsing
        errorMessage = nil

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-install-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp

            let exitCode = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", zipURL.path, "-d", tmp.path]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus
            }.value

            guard exitCode == 0 else {
                fail("Could not extract the zip archive. Make sure it's a valid .zip file.")
                return
            }

            let scriptDirs = try findScriptDirs(in: tmp)

            guard !scriptDirs.isEmpty else {
                fail("No installable scripts were found in this zip.\nExpected folders containing manifest.json.")
                return
            }

            var valid: [PendingScript] = []
            var invalid: [SkippedScript] = []

            for dir in scriptDirs {
                switch validate(dir: dir, existingScripts: existingScripts) {
                case .success(let ps):  valid.append(ps)
                case .failure(let e):   invalid.append(SkippedScript(folderName: dir.lastPathComponent, reason: e.message))
                }
            }

            // Cross-script checks: duplicate IDs within the bundle
            var seen: [String: String] = [:]  // id → name of first occurrence
            var deduped: [PendingScript] = []
            for script in valid {
                if let first = seen[script.id] {
                    invalid.append(SkippedScript(
                        folderName: script.name,
                        reason: "Duplicate id '\(script.id)' — already provided by '\(first)' in this zip"
                    ))
                } else {
                    seen[script.id] = script.name
                    deduped.append(script)
                }
            }

            guard !deduped.isEmpty else {
                let reasons = invalid.map { "• \($0.folderName): \($0.reason)" }.joined(separator: "\n")
                fail("None of the scripts in this zip could be installed:\n\(reasons)")
                return
            }

            pending = deduped
            skipped = invalid
            phase = .ready
            showSheet = true

        } catch {
            fail("Failed to process zip: \(error.localizedDescription)")
        }
    }

    private func findScriptDirs(in root: URL) throws -> [URL] {
        let fm = FileManager.default

        if fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
            return [root]
        }

        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
        }
    }

    // MARK: - Validation

    private struct ValidationError: Error { let message: String }
    private static let validIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    private static let validScriptTypes: Set<String> = ["tile", "feed"]

    private func validate(dir: URL, existingScripts: [ManagedScript]) -> Result<PendingScript, ValidationError> {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(ValidationError(message: "manifest.json is missing or not valid JSON")) }

        // Required fields
        guard let id = manifest["id"] as? String, !id.isEmpty
        else { return .failure(ValidationError(message: "'id' field is missing or empty")) }

        guard let name = manifest["name"] as? String, !name.isEmpty
        else { return .failure(ValidationError(message: "'name' field is missing or empty")) }

        guard let version = manifest["version"] as? String, !version.isEmpty
        else { return .failure(ValidationError(message: "'version' field is missing or empty")) }

        guard let entry = manifest["entry"] as? String, !entry.isEmpty
        else { return .failure(ValidationError(message: "'entry' field is missing or empty")) }

        // ID format: alphanumeric + hyphens + underscores only
        guard id.unicodeScalars.allSatisfy({ Self.validIDCharacters.contains($0) })
        else { return .failure(ValidationError(message: "id '\(id)' contains invalid characters — use letters, numbers, hyphens, and underscores only")) }

        // Entry file must exist in the archive
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry).path)
        else { return .failure(ValidationError(message: "Entry file '\(entry)' not found in the archive")) }

        // Non-blocking warnings
        var warnings: [String] = []

        // scriptType — if present must be a known value
        let scriptType = manifest["type"] as? String ?? manifest["scriptType"] as? String
        if let t = scriptType, !Self.validScriptTypes.contains(t) {
            warnings.append("Unknown script type '\(t)' — expected 'tile' or 'feed'")
        }

        // icon format — basic sanity check (no spaces, non-empty if provided)
        if let icon = manifest["icon"] as? String {
            if icon.isEmpty || icon.contains(" ") {
                warnings.append("Icon value '\(icon)' looks invalid — expected an SF Symbol name like 'terminal.fill'")
            }
        }

        // Icon file — same logic as ScriptManager (path-traversal checked)
        let iconCandidate = manifest["icon_file"] as? String ?? "icon.svg"
        let iconURL = dir.appendingPathComponent(iconCandidate)
        let resolvedIcon = iconURL.resolvingSymlinksInPath()
        let resolvedDir  = dir.resolvingSymlinksInPath()
        let iconInBounds = resolvedIcon.path.hasPrefix(resolvedDir.path + "/")
                        || resolvedIcon.path == resolvedDir.path
        let iconImage: NSImage? = iconInBounds ? NSImage(contentsOf: iconURL) : nil
        let svgString: String? = iconInBounds && iconURL.pathExtension.lowercased() == "svg"
            ? try? String(contentsOf: iconURL, encoding: .utf8)
            : nil

        // Determine install kind by comparing with existing vault
        let existing = existingScripts.first { $0.id == id }
        let installKind: InstallKind
        let existingVersion = existing?.version

        if existing != nil {
            let comparison = VersionComparison.compare(version, existingVersion ?? "")
            switch comparison {
            case .orderedDescending:  installKind = .update
            case .orderedSame:        installKind = .reinstall
            case .orderedAscending:   installKind = .downgrade
            }
            if installKind == .downgrade {
                warnings.append("This is older than the installed version (\(existingVersion ?? "?") → \(version))")
            }
        } else {
            installKind = .fresh
        }

        // Name collision — different ID but same display name as an existing script
        if let conflicting = existingScripts.first(where: { $0.name == name && $0.id != id }) {
            warnings.append("Name '\(name)' is already used by script '\(conflicting.id)' — both will appear in the sidebar")
        }

        return .success(PendingScript(
            id: id,
            name: name,
            version: version,
            description: manifest["description"] as? String ?? "",
            icon: manifest["icon"] as? String,
            iconImage: iconImage,
            svgString: svgString,
            scriptType: scriptType,
            sourceDir: dir,
            installKind: installKind,
            existingVersion: existingVersion,
            warnings: warnings
        ))
    }

    // MARK: - Installation

    func install(to vaultURL: URL, scriptManager: ScriptManager) {
        Task { await doInstall(to: vaultURL, scriptManager: scriptManager) }
    }

    @MainActor
    private func doInstall(to vaultURL: URL, scriptManager: ScriptManager) async {
        phase = .installing
        showSheet = false
        scriptManager.beginInstall()

        let fm = FileManager.default
        var installationErrors: [SkippedScript] = []

        for script in pending {
            installProgressLabel = "Installing \(script.name)…"

            let destDir = vaultURL.appendingPathComponent(script.id)

            do {
                if fm.fileExists(atPath: destDir.path) {
                    // Stop the running script before touching its files.
                    // Without this, the process crashes when its directory is moved
                    // out from under it. reload() after endInstall() restarts it cleanly.
                    scriptManager.stopScriptForUpdate(id: script.id)

                    // Run the old version's setup --uninstall before replacing files.
                    // This lets the previous setup clean up any system state it registered
                    // (e.g. hooks in ~/.claude/settings.json).
                    let oldSetupPath = destDir.appendingPathComponent("setup.py")
                    if fm.fileExists(atPath: oldSetupPath.path) {
                        await runSetup(scriptPath: oldSetupPath, scriptDir: destDir, argument: "--uninstall")
                    }

                    // Preserve the previous version so it can be rolled back.
                    // Only one generation is kept: {id}.previous
                    let backupDir = vaultURL.appendingPathComponent("\(script.id).previous")
                    if fm.fileExists(atPath: backupDir.path) {
                        try? fm.removeItem(at: backupDir)
                    }
                    try fm.moveItem(at: destDir, to: backupDir)
                }
                try fm.copyItem(at: script.sourceDir, to: destDir)
            } catch {
                installationErrors.append(SkippedScript(folderName: script.name,
                                                        reason: error.localizedDescription))
                continue
            }

            let setupPath = destDir.appendingPathComponent("setup.py")
            if fm.fileExists(atPath: setupPath.path) {
                installProgressLabel = "Running setup for \(script.name)…"
                await runSetup(scriptPath: setupPath, scriptDir: destDir, argument: "--install")
            }
        }

        skipped.append(contentsOf: installationErrors)
        cleanup()
        installProgressLabel = nil
        phase = .done

        // endInstall() releases the install lock and triggers a reload (including any
        // pending file-watcher reload that was deferred during the install).
        scriptManager.endInstall()
        phase = .idle
    }

    // MARK: - Helpers

    /// Run `setup.py --install` or `setup.py --uninstall` with a 5-minute timeout.
    private func runSetup(scriptPath: URL, scriptDir: URL, argument: String) async {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [scriptPath.path, argument]
            var env = ProcessInfo.processInfo.environment
            // Include the vault root (parent of scriptDir) so that ask_sdk.py — which
            // lives at vault root — is importable alongside the script's own directory.
            let vaultRoot = scriptDir.deletingLastPathComponent().path
            let existing = env["PYTHONPATH"].map { ":\($0)" } ?? ""
            env["PYTHONPATH"] = "\(vaultRoot):\(scriptDir.path)\(existing)"
            proc.environment = env
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(300))
                if proc.isRunning { proc.terminate() }
            }
            proc.waitUntilExit()
            timeoutTask.cancel()
        }.value
    }

    private func cleanup() {
        if let tmp = tempDir {
            try? FileManager.default.removeItem(at: tmp)
            tempDir = nil
        }
    }

    private func reset() {
        pending = []
        skipped = []
        errorMessage = nil
        showSheet = false
        installProgressLabel = nil
        phase = .idle
    }

    @MainActor
    private func fail(_ message: String) {
        errorMessage = message
        phase = .idle
        showSheet = true
        cleanup()
    }
}
