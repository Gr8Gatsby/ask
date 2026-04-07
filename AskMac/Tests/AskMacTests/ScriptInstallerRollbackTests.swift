import Testing
import Foundation

/// Tests for the rollback / backup logic applied during script installation.
///
/// The installer rule (from ScriptInstaller.doInstall):
///   1. Fresh install  — destination doesn't exist → just copy, no backup created.
///   2. First update   — destination exists, no `.previous` → move dest → `{id}.previous`, then copy.
///   3. Second update  — destination exists, `.previous` already exists → remove old `.previous`,
///                       move dest → `{id}.previous`, then copy.
///
/// These tests reproduce that exact logic against a temporary vault directory so they stay
/// independent of the full ScriptInstaller class (which requires AppKit + CloudKit).
@Suite("ScriptInstaller rollback")
struct ScriptInstallerRollbackTests {

    // MARK: - Helpers

    /// Simulate the installer's copy-with-backup step for a single script.
    private func simulateInstall(scriptID: String, vaultURL: URL, sourceDir: URL) throws {
        let fm = FileManager.default
        let destDir = vaultURL.appendingPathComponent(scriptID)

        if fm.fileExists(atPath: destDir.path) {
            let backupDir = vaultURL.appendingPathComponent("\(scriptID).previous")
            if fm.fileExists(atPath: backupDir.path) {
                try fm.removeItem(at: backupDir)
            }
            try fm.moveItem(at: destDir, to: backupDir)
        }
        try fm.copyItem(at: sourceDir, to: destDir)
    }

    /// Create a temp vault URL, run the block, and clean up afterwards.
    private func withTempVault(_ body: (URL) throws -> Void) throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        try body(vaultURL)
    }

    /// Create a minimal "script source directory" with a single sentinel file.
    private func makeSourceDir(version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-test-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Tests

    @Test func freshInstallCreatesNoBackup() throws {
        let src = try makeSourceDir(version: "1.0.0")
        defer { try? FileManager.default.removeItem(at: src) }

        try withTempVault { vault in
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src)

            let destDir    = vault.appendingPathComponent("my-script")
            let backupDir  = vault.appendingPathComponent("my-script.previous")

            #expect(FileManager.default.fileExists(atPath: destDir.path),   "destination must exist after fresh install")
            #expect(!FileManager.default.fileExists(atPath: backupDir.path), "no backup on fresh install")
        }
    }

    @Test func firstUpdateCreatesBackup() throws {
        let src1 = try makeSourceDir(version: "1.0.0")
        let src2 = try makeSourceDir(version: "1.1.0")
        defer {
            try? FileManager.default.removeItem(at: src1)
            try? FileManager.default.removeItem(at: src2)
        }

        try withTempVault { vault in
            // Install v1
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src1)
            // Update to v2
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src2)

            let destDir   = vault.appendingPathComponent("my-script")
            let backupDir = vault.appendingPathComponent("my-script.previous")

            #expect(FileManager.default.fileExists(atPath: destDir.path),  "destination must exist after update")
            #expect(FileManager.default.fileExists(atPath: backupDir.path), "backup must exist after first update")

            // Verify backup contains v1 content and dest contains v2 content
            let backupVersion = try String(contentsOf: backupDir.appendingPathComponent("version.txt"), encoding: .utf8)
            let destVersion   = try String(contentsOf: destDir.appendingPathComponent("version.txt"),   encoding: .utf8)
            #expect(backupVersion == "1.0.0", "backup should hold the previous version")
            #expect(destVersion   == "1.1.0", "destination should hold the new version")
        }
    }

    @Test func secondUpdateReplacesOldBackup() throws {
        let src1 = try makeSourceDir(version: "1.0.0")
        let src2 = try makeSourceDir(version: "1.1.0")
        let src3 = try makeSourceDir(version: "1.2.0")
        defer {
            try? FileManager.default.removeItem(at: src1)
            try? FileManager.default.removeItem(at: src2)
            try? FileManager.default.removeItem(at: src3)
        }

        try withTempVault { vault in
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src1)
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src2)
            try simulateInstall(scriptID: "my-script", vaultURL: vault, sourceDir: src3)

            let destDir   = vault.appendingPathComponent("my-script")
            let backupDir = vault.appendingPathComponent("my-script.previous")

            // Only one generation of backup is kept
            #expect(FileManager.default.fileExists(atPath: backupDir.path), "backup must still exist")

            let backupVersion = try String(contentsOf: backupDir.appendingPathComponent("version.txt"), encoding: .utf8)
            let destVersion   = try String(contentsOf: destDir.appendingPathComponent("version.txt"),   encoding: .utf8)
            #expect(backupVersion == "1.1.0", "backup should be the immediately-previous version (v2), not v1")
            #expect(destVersion   == "1.2.0", "destination should be the latest version")
        }
    }

    @Test func independentScriptsDontShareBackups() throws {
        let srcA = try makeSourceDir(version: "1.0.0")
        let srcB = try makeSourceDir(version: "2.0.0")
        let srcA2 = try makeSourceDir(version: "1.1.0")
        defer {
            try? FileManager.default.removeItem(at: srcA)
            try? FileManager.default.removeItem(at: srcB)
            try? FileManager.default.removeItem(at: srcA2)
        }

        try withTempVault { vault in
            try simulateInstall(scriptID: "script-a", vaultURL: vault, sourceDir: srcA)
            try simulateInstall(scriptID: "script-b", vaultURL: vault, sourceDir: srcB)
            try simulateInstall(scriptID: "script-a", vaultURL: vault, sourceDir: srcA2)

            let backupA = vault.appendingPathComponent("script-a.previous")
            let backupB = vault.appendingPathComponent("script-b.previous")

            #expect(FileManager.default.fileExists(atPath: backupA.path),  "script-a should have a backup")
            #expect(!FileManager.default.fileExists(atPath: backupB.path), "script-b had no update so no backup")
        }
    }
}
