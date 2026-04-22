// Integration tests that require Xcode's test-host app (AskMac.app) to link
// against Sparkle and SwiftUI. Excluded from `swift test` (SPM) via the guard.
#if !SWIFT_PACKAGE
import Testing
import Foundation
@testable import AskMac
#if canImport(AskMacCore)
import AskMacCore
#endif

// MARK: - Mock

/// Minimal ScriptInstallTarget for testing — tracks what was installed, starts with no scripts.
@MainActor
final class MockScriptManager: ScriptInstallTarget {
    var scripts: [ManagedScript] = []
    private(set) var markedInstalledIDs: [String] = []

    func beginInstall() {}
    func endInstall() {}
    func stopScriptForUpdate(id: String) {}
    func markInstalledByUser(ids: [String]) { markedInstalledIDs.append(contentsOf: ids) }
}

// MARK: - Helpers

private func repoRoot() -> URL {
    // Test bundle is deep inside DerivedData; walk up to find the repo root by
    // looking for the ask/scripts directory.
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
        if FileManager.default.fileExists(
            atPath: url.appendingPathComponent("ask/scripts").path) {
            return url
        }
        url = url.deletingLastPathComponent()
    }
    preconditionFailure("Could not find repo root from \(#filePath)")
}

/// Zip a script directory from the repo into a temp file and return the zip URL.
private func zipScript(id: String, repoRoot: URL) throws -> URL {
    let scriptDir = repoRoot.appendingPathComponent("ask/scripts/\(id)")
    guard FileManager.default.fileExists(atPath: scriptDir.path) else {
        throw TestError("Script directory not found: \(scriptDir.path)")
    }
    let zipURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(id)-test-\(UUID().uuidString).zip")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    proc.arguments = ["-r", zipURL.path, id,
                      "--exclude", "\(id)/__pycache__/*",
                      "--exclude", "\(id)/*.pyc"]
    proc.currentDirectoryURL = repoRoot.appendingPathComponent("ask/scripts")
    proc.standardOutput = Pipe(); proc.standardError = Pipe()
    try proc.run(); proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw TestError("zip failed for \(id)")
    }
    return zipURL
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

// MARK: - Integration tests

@Suite("Script dependency install integration")
struct ScriptDependencyInstallTests {

    /// Core scenario: install claudecode-controller with an empty vault.
    /// Expects terminal-manager to be auto-installed as a dependency.
    @Test func installsTerminalManagerWhenClaudeCodeControllerInstalled() async throws {
        let repo = repoRoot()

        // 1. Build local zips
        let controllerZip = try zipScript(id: "claudecode-controller", repoRoot: repo)
        let tmZip         = try zipScript(id: "terminal-manager",       repoRoot: repo)
        defer {
            try? FileManager.default.removeItem(at: controllerZip)
            try? FileManager.default.removeItem(at: tmZip)
        }

        // 2. Temp vault — starts empty (no terminal-manager)
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-dep-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // 3. Catalog seeded with terminal-manager entry pointing to local file:// zip
        let tmEntry = CatalogEntry(
            id: "terminal-manager",
            name: "Terminal Manager",
            version: "1.6.0",
            description: "test",
            icon: nil,
            type: "system",
            changelog: nil,
            downloadURL: tmZip
        )
        let catalog = await MainActor.run { ScriptCatalogService(entries: [tmEntry]) }

        // 4. Mock manager — no scripts installed
        let manager = await MockScriptManager()

        // 5. Installer — parse claudecode-controller zip
        let installer = await ScriptInstaller()
        await MainActor.run { installer.load(zipURL: controllerZip, existingScripts: []) }

        // Wait for parsing to start, then complete
        var waited = 0
        while await installer.phase == .idle, waited < 50 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        while await installer.phase == .parsing, waited < 200 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let phase = await installer.phase
        #expect(phase == .ready, "installer should reach .ready, got \(phase)")

        // 6. Run the install with the catalog (dep resolution fires here)
        await MainActor.run {
            installer.showSheet = false
            installer.install(to: vault, scriptManager: manager, catalog: catalog)
        }

        // Wait for install to finish
        waited = 0
        while await installer.phase != .idle, waited < 300 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }

        // 7. Assert both scripts landed in the vault
        let fm = FileManager.default
        let controllerInVault = vault.appendingPathComponent("claudecode-controller")
        let tmInVault         = vault.appendingPathComponent("terminal-manager")

        #expect(fm.fileExists(atPath: controllerInVault.path),
                "claudecode-controller should be in vault after install")
        #expect(fm.fileExists(atPath: tmInVault.path),
                "terminal-manager should be auto-installed as a dependency")

        // 8. Both should have been marked as installed
        let marked = await manager.markedInstalledIDs
        #expect(marked.contains("terminal-manager"),
                "terminal-manager should be marked installed by user")
    }

    /// Regression: if terminal-manager is already present, it should NOT be reinstalled.
    @Test func skipsDepInstallWhenAlreadyPresent() async throws {
        let repo = repoRoot()
        let controllerZip = try zipScript(id: "claudecode-controller", repoRoot: repo)
        let tmZip         = try zipScript(id: "terminal-manager",       repoRoot: repo)
        defer {
            try? FileManager.default.removeItem(at: controllerZip)
            try? FileManager.default.removeItem(at: tmZip)
        }

        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-dep-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let tmEntry = CatalogEntry(
            id: "terminal-manager", name: "Terminal Manager", version: "1.6.0",
            description: "test", icon: nil, type: "system", changelog: nil, downloadURL: tmZip
        )
        let catalog = await MainActor.run { ScriptCatalogService(entries: [tmEntry]) }

        // terminal-manager is already installed — inject as existing script
        let existingTM = ManagedScript(
            id: "terminal-manager", name: "Terminal Manager",
            version: "1.6.0", description: "test",
            icon: nil, iconImage: nil, svgString: nil,
            status: .running, isEnabled: true
        )
        let manager = await MockScriptManager()
        await MainActor.run { manager.scripts = [existingTM] }

        let installer = await ScriptInstaller()
        await MainActor.run { installer.load(zipURL: controllerZip, existingScripts: [existingTM]) }

        var waited = 0
        while await installer.phase == .idle, waited < 50 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        while await installer.phase == .parsing, waited < 200 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }

        await MainActor.run {
            installer.showSheet = false
            installer.install(to: vault, scriptManager: manager, catalog: catalog)
        }

        waited = 0
        while await installer.phase != .idle, waited < 300 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }

        // terminal-manager should NOT be in the vault (it was already there, we didn't re-copy)
        // and it should NOT be re-marked as installed
        let marked = await manager.markedInstalledIDs
        #expect(!marked.contains("terminal-manager"),
                "terminal-manager should not be re-installed if already present")
    }
}
#endif // !SWIFT_PACKAGE
