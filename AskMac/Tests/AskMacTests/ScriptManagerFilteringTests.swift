import Testing
import Foundation

/// Tests for the ScriptManager vault-scan filtering that excludes rollback directories.
///
/// ScriptManager skips any directory whose name ends in ".previous" so that backup
/// copies created by ScriptInstaller are never treated as installed scripts.
/// These tests verify that predicate and the broader vault-scan directory-selection
/// logic in isolation.
@Suite("ScriptManager vault filtering")
struct ScriptManagerFilteringTests {

    // MARK: - .previous suffix predicate

    @Test func previousSuffixRejected() {
        let names = ["my-script.previous", "claudecode-controller.previous", "a.previous"]
        for name in names {
            #expect(name.hasSuffix(".previous"), "\(name) should be detected as a backup directory")
        }
    }

    @Test func regularScriptNamesAccepted() {
        let names = ["claudecode-controller", "brew-monitor", "my-script", "previous", "previous-script"]
        for name in names {
            #expect(!name.hasSuffix(".previous"), "\(name) should not be filtered out")
        }
    }

    @Test func emptyStringNotRejected() {
        #expect(!"".hasSuffix(".previous"))
    }

    // MARK: - Vault directory scan simulation

    /// Simulate the directory scan that ScriptManager performs: collect subdirectories
    /// that contain a `manifest.json` and whose name does NOT end in `.previous`.
    private func simulateScan(in vaultURL: URL) throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            guard !url.lastPathComponent.hasSuffix(".previous") else { return nil }
            guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    private func makeScriptDir(in vault: URL, name: String) throws {
        let dir = vault.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    @Test func backupDirsExcludedFromScan() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        // Create normal scripts and their backups
        try makeScriptDir(in: vaultURL, name: "claudecode-controller")
        try makeScriptDir(in: vaultURL, name: "claudecode-controller.previous")
        try makeScriptDir(in: vaultURL, name: "brew-monitor")
        try makeScriptDir(in: vaultURL, name: "brew-monitor.previous")

        let found = try simulateScan(in: vaultURL)

        #expect(found == ["brew-monitor", "claudecode-controller"], "only live scripts should be returned")
        #expect(!found.contains(where: { $0.hasSuffix(".previous") }), "no backup dir should appear")
    }

    @Test func noBackupsDirsMeansNoneFiltered() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try makeScriptDir(in: vaultURL, name: "script-a")
        try makeScriptDir(in: vaultURL, name: "script-b")

        let found = try simulateScan(in: vaultURL)
        #expect(found == ["script-a", "script-b"])
    }

    @Test func dirsWithoutManifestExcluded() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        // A directory without manifest.json should be ignored
        let noManifestDir = vaultURL.appendingPathComponent("orphan-dir")
        try FileManager.default.createDirectory(at: noManifestDir, withIntermediateDirectories: true)
        try makeScriptDir(in: vaultURL, name: "valid-script")

        let found = try simulateScan(in: vaultURL)
        #expect(found == ["valid-script"])
        #expect(!found.contains("orphan-dir"))
    }

    @Test func onlyBackupDirsReturnsEmpty() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try makeScriptDir(in: vaultURL, name: "my-script.previous")

        let found = try simulateScan(in: vaultURL)
        #expect(found.isEmpty)
    }
}
