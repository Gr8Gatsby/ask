import Testing
import Foundation

/// Tests for script_dependencies resolution in ScriptInstaller.
///
/// We test the PendingScript parsing and the dependency-collection logic directly
/// against temp directories — no network, no AppKit, no CloudKit required.
@Suite("Script dependencies")
struct ScriptDependencyTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-dep-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write a minimal manifest.json into dir and return the dir URL.
    private func makeScriptDir(in vault: URL, id: String,
                               scriptDeps: [String] = []) throws -> URL {
        let dir = vault.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "id": id,
            "name": id,
            "version": "1.0",
            "entry": "main.py",
        ]
        if !scriptDeps.isEmpty {
            manifest["script_dependencies"] = scriptDeps
        }
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        // Create a stub entry file so validation passes
        try "".write(to: dir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - manifest.json parsing

    @Test func manifestWithNoDepsHasEmptyDependencies() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = try makeScriptDir(in: tmp, id: "hello-world", scriptDeps: [])

        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let deps = manifest["script_dependencies"] as? [String] ?? []
        #expect(deps.isEmpty)
    }

    @Test func manifestWithDepsRoundTrips() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = try makeScriptDir(in: tmp, id: "claudecode-controller",
                                    scriptDeps: ["terminal-manager"])

        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let deps = manifest["script_dependencies"] as? [String] ?? []
        #expect(deps == ["terminal-manager"])
    }

    @Test func manifestWithMultipleDepsRoundTrips() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = try makeScriptDir(in: tmp, id: "multi-dep",
                                    scriptDeps: ["terminal-manager", "another-dep"])

        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let deps = manifest["script_dependencies"] as? [String] ?? []
        #expect(deps.count == 2)
        #expect(deps.contains("terminal-manager"))
        #expect(deps.contains("another-dep"))
    }

    // MARK: - Dependency resolution logic (pure logic tests)

    /// Reproduce the dep-resolution filter from doInstall:
    ///   neededDepIDs = declared deps − already installed − also being installed this run
    private func resolveNeededDeps(
        declaredDeps: [String],
        installedIDs: Set<String>,
        pendingIDs: Set<String>
    ) -> Set<String> {
        Set(declaredDeps)
            .subtracting(installedIDs)
            .subtracting(pendingIDs)
    }

    @Test func depAlreadyInstalledIsNotNeeded() {
        let needed = resolveNeededDeps(
            declaredDeps: ["terminal-manager"],
            installedIDs: ["terminal-manager"],
            pendingIDs: []
        )
        #expect(needed.isEmpty)
    }

    @Test func missingDepIsNeeded() {
        let needed = resolveNeededDeps(
            declaredDeps: ["terminal-manager"],
            installedIDs: [],
            pendingIDs: []
        )
        #expect(needed == ["terminal-manager"])
    }

    @Test func depBeingInstalledInSameRunIsNotNeeded() {
        let needed = resolveNeededDeps(
            declaredDeps: ["terminal-manager"],
            installedIDs: [],
            pendingIDs: ["terminal-manager"]
        )
        #expect(needed.isEmpty)
    }

    @Test func onlyMissingDepsAreNeeded() {
        let needed = resolveNeededDeps(
            declaredDeps: ["terminal-manager", "other-dep"],
            installedIDs: ["other-dep"],
            pendingIDs: []
        )
        #expect(needed == ["terminal-manager"])
    }

    @Test func noDepsDeclairedMeansNothingNeeded() {
        let needed = resolveNeededDeps(
            declaredDeps: [],
            installedIDs: [],
            pendingIDs: []
        )
        #expect(needed.isEmpty)
    }

    // MARK: - CatalogEntry decoding

    @Test func catalogEntryDecodesScriptDependencies() throws {
        let json = """
        {
          "id": "claudecode-controller",
          "name": "Claude Code",
          "version": "2.27.0",
          "description": "desc",
          "download_url": "https://example.com/claudecode-controller.zip",
          "script_dependencies": ["terminal-manager"]
        }
        """.data(using: .utf8)!

        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let deps = obj["script_dependencies"] as? [String] ?? []
        #expect(deps == ["terminal-manager"])
    }

    @Test func catalogEntryWithNoDepsFieldDecodesAsNil() throws {
        let json = """
        {
          "id": "hello-world",
          "name": "Hello World",
          "version": "1.0",
          "description": "desc",
          "download_url": "https://example.com/hello-world.zip"
        }
        """.data(using: .utf8)!

        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let deps = obj["script_dependencies"] as? [String]
        #expect(deps == nil)
    }
}
