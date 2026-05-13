#if canImport(AskMacCore)
import AskMacCore
#endif
import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "ScriptInstaller")

// MARK: - ScriptInstallTarget

/// The subset of ScriptManager that ScriptInstaller needs — extracted so tests can inject a mock.
protocol ScriptInstallTarget: AnyObject {
    var scripts: [ManagedScript] { get }
    func beginInstall()
    func endInstall()
    func stopScriptForUpdate(id: String)
    func markInstalledByUser(ids: [String])
}

extension ScriptManager: ScriptInstallTarget {}

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
        let scriptDependencies: [String]  // other script IDs required before this one runs
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
                proc.arguments = ["-q", "-o", zipURL.path, "-d", tmp.path]   // -q: quiet, so the pipe stays empty
                let outPipe = Pipe(); let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                try? proc.run()
                // Drain BEFORE waitUntilExit. Otherwise a >64KB pipe write
                // fills the buffer, the child blocks writing, and the parent
                // blocks waiting for exit — classic deadlock. `-q` keeps output
                // tiny but we drain anyway for safety.
                _ = try? outPipe.fileHandleForReading.readToEnd()
                _ = try? errPipe.fileHandleForReading.readToEnd()
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

        let scriptDeps = manifest["script_dependencies"] as? [String] ?? []

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
            warnings: warnings,
            scriptDependencies: scriptDeps
        ))
    }

    // MARK: - Installation

    func install(to vaultURL: URL, scriptManager: any ScriptInstallTarget,
                 catalog: ScriptCatalogService? = nil) {
        Task { await doInstall(to: vaultURL, scriptManager: scriptManager, catalog: catalog) }
    }

    @MainActor
    private func doInstall(to vaultURL: URL, scriptManager: any ScriptInstallTarget,
                           catalog: ScriptCatalogService? = nil) async {
        logger.info("[doInstall] begin · pending=\(self.pending.count) vault=\(vaultURL.path, privacy: .public)")
        phase = .installing
        showSheet = false
        scriptManager.beginInstall()
        // Guarantee the install lock + UI phase are released even if a
        // throwing await escapes this scope. Without this, the prior code's
        // defer was log-only — a thrown error mid-install would leave
        // installLockCount stuck > 0 forever, blocking every future reload
        // and making AskMac feel "frozen" to the user. The flag prevents
        // double-release when the happy path also calls endInstall().
        var endInstallCalled = false
        defer {
            if !endInstallCalled {
                logger.error("[doInstall] abnormal exit — releasing install lock")
                scriptManager.endInstall()
            }
            logger.info("[doInstall] exit · phase=\(String(describing: self.phase), privacy: .public)")
        }

        // Prime the vault and copy ask_sdk.py from the app bundle before any setup.py runs.
        // Catalog zips don't include ask_sdk.py at their root, so without this, setup.py
        // fails with ModuleNotFoundError on machines that never had scripts deployed via dev tools.
        let fm = FileManager.default
        try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let sdkDest = vaultURL.appendingPathComponent("ask_sdk.py")
        if let bundleSDK = Bundle.main.resourceURL?.appendingPathComponent("Scripts/ask_sdk.py"),
           fm.fileExists(atPath: bundleSDK.path) {
            try? fm.removeItem(at: sdkDest)
            try? fm.copyItem(at: bundleSDK, to: sdkDest)
        }

        // Resolve script dependencies: install any missing deps silently before main scripts.
        if let catalog {
            let installedIDs = Set(scriptManager.scripts.map(\.id))
            let neededDepIDs = Set(pending.flatMap(\.scriptDependencies))
                .subtracting(installedIDs)
                .subtracting(Set(pending.map(\.id)))  // also being installed this run

            for depID in neededDepIDs {
                guard let depEntry = catalog.allEntries.first(where: { $0.id == depID }) else {
                    skipped.append(SkippedScript(
                        folderName: depID,
                        reason: "Required dependency '\(depID)' not found in catalog — install it manually"
                    ))
                    continue
                }
                installProgressLabel = "Installing dependency: \(depEntry.name)…"
                do {
                    let zipURL = try await catalog.downloadZip(for: depEntry)
                    await installFromZip(zipURL: zipURL, vaultURL: vaultURL,
                                         scriptManager: scriptManager, label: depEntry.name)
                } catch {
                    skipped.append(SkippedScript(
                        folderName: depID,
                        reason: "Could not download dependency '\(depID)': \(error.localizedDescription)"
                    ))
                }
            }
        }

        var installationErrors: [SkippedScript] = []

        for script in pending {
            installProgressLabel = "Installing \(script.name)…"
            logger.info("[doInstall] installing \(script.id, privacy: .public) v\(script.version, privacy: .public)")

            let destDir = vaultURL.appendingPathComponent(script.id)

            do {
                if fm.fileExists(atPath: destDir.path) {
                    // Stop the running script before touching its files.
                    // Without this, the process crashes when its directory is moved
                    // out from under it. reload() after endInstall() restarts it cleanly.
                    logger.info("[doInstall] stopping running \(script.id, privacy: .public) before replace")
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
                logger.info("[doInstall] copied \(script.id, privacy: .public) → \(destDir.path, privacy: .public)")
            } catch {
                logger.error("[doInstall] file copy failed for \(script.id, privacy: .public): \(String(describing: error), privacy: .public)")
                installationErrors.append(SkippedScript(folderName: script.name,
                                                        reason: error.localizedDescription))
                continue
            }

            let setupPath = destDir.appendingPathComponent("setup.py")
            if fm.fileExists(atPath: setupPath.path) {
                installProgressLabel = "Running setup for \(script.name)…"
                logger.info("[doInstall] running setup.py --install for \(script.id, privacy: .public)")
                await runSetup(scriptPath: setupPath, scriptDir: destDir, argument: "--install")
                logger.info("[doInstall] setup.py --install done for \(script.id, privacy: .public)")
            }
        }

        skipped.append(contentsOf: installationErrors)

        // If the zip archive included ask_sdk.py at its root, copy it over the bundle version.
        // This allows custom zips to ship an updated SDK alongside their scripts.
        if let tmp = tempDir {
            let sdkSrc = tmp.appendingPathComponent("ask_sdk.py")
            if fm.fileExists(atPath: sdkSrc.path) {
                try? fm.removeItem(at: sdkDest)
                try? fm.copyItem(at: sdkSrc, to: sdkDest)
            }
        }

        // Mark all pending scripts as known+enabled so the reload triggered by endInstall()
        // starts them immediately. Scripts that failed to copy won't have a valid manifest
        // in the vault, so the reload simply won't find them.
        scriptManager.markInstalledByUser(ids: pending.map(\.id))

        cleanup()
        installProgressLabel = nil
        phase = .done

        // endInstall() releases the install lock and triggers a reload (including any
        // pending file-watcher reload that was deferred during the install).
        scriptManager.endInstall()
        endInstallCalled = true
        phase = .idle
    }

    // MARK: - Helpers

    /// Extract a zip and install all valid scripts found inside it, used for silent dep installs.
    @MainActor
    private func installFromZip(zipURL: URL, vaultURL: URL,
                                scriptManager: any ScriptInstallTarget, label: String) async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-dep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let exitCode = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-q", "-o", zipURL.path, "-d", tmp.path]
                let outPipe = Pipe(); let errPipe = Pipe()
                proc.standardOutput = outPipe; proc.standardError = errPipe
                try? proc.run()
                _ = try? outPipe.fileHandleForReading.readToEnd()
                _ = try? errPipe.fileHandleForReading.readToEnd()
                proc.waitUntilExit()
                return proc.terminationStatus
            }.value
            guard exitCode == 0 else { return }
            let dirs = (try? findScriptDirs(in: tmp)) ?? []
            let fm = FileManager.default
            try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            for dir in dirs {
                guard case .success(let ps) = validate(dir: dir, existingScripts: scriptManager.scripts) else { continue }
                let destDir = vaultURL.appendingPathComponent(ps.id)
                if fm.fileExists(atPath: destDir.path) {
                    scriptManager.stopScriptForUpdate(id: ps.id)
                    let oldSetup = destDir.appendingPathComponent("setup.py")
                    if fm.fileExists(atPath: oldSetup.path) {
                        await runSetup(scriptPath: oldSetup, scriptDir: destDir, argument: "--uninstall")
                    }
                    let backup = vaultURL.appendingPathComponent("\(ps.id).previous")
                    try? fm.removeItem(at: backup)
                    try? fm.moveItem(at: destDir, to: backup)
                }
                try fm.copyItem(at: ps.sourceDir, to: destDir)
                let setup = destDir.appendingPathComponent("setup.py")
                if fm.fileExists(atPath: setup.path) {
                    await runSetup(scriptPath: setup, scriptDir: destDir, argument: "--install")
                }
                scriptManager.markInstalledByUser(ids: [ps.id])
            }
        } catch {}
    }

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
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try? proc.run()

            // Drain stdout/stderr concurrently with waitUntilExit. The previous
            // code captured both streams via Pipe() but never read them — a
            // setup.py that printed >64KB to stdout/stderr would fill the pipe
            // buffer, block on its next write, and deadlock waitUntilExit
            // forever. AskMac itself then appears hung; if macOS terminates it,
            // it presents as a crash to the user. Reading via background tasks
            // keeps the pipes drained without blocking the parent's wait.
            let drainOut = Task.detached { _ = try? outPipe.fileHandleForReading.readToEnd() }
            let drainErr = Task.detached { _ = try? errPipe.fileHandleForReading.readToEnd() }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(300))
                if proc.isRunning { proc.terminate() }
            }
            proc.waitUntilExit()
            timeoutTask.cancel()
            // Drains finish naturally on pipe EOF after the child exits.
            _ = await drainOut.value
            _ = await drainErr.value
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
