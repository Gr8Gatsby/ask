import Testing
import Foundation
@testable import AskMacCore

private struct StubScript: InstalledScript {
    let id: String
    let version: String?
}

// MARK: - CatalogEntry JSON decoding

@Suite("CatalogEntry decoding")
struct CatalogEntryDecodingTests {

    private func decode(_ json: String) throws -> CatalogEntry {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(CatalogEntry.self, from: data)
    }

    @Test func decodesRequiredFields() throws {
        let json = """
        {
            "id": "my-script",
            "name": "My Script",
            "version": "1.2.3",
            "description": "Does things",
            "download_url": "https://example.com/my-script.zip"
        }
        """
        let entry = try decode(json)
        #expect(entry.id          == "my-script")
        #expect(entry.name        == "My Script")
        #expect(entry.version     == "1.2.3")
        #expect(entry.description == "Does things")
        #expect(entry.downloadURL == URL(string: "https://example.com/my-script.zip")!)
    }

    @Test func decodesOptionalFields() throws {
        let json = """
        {
            "id": "script-a",
            "name": "Script A",
            "version": "0.1.0",
            "description": "",
            "download_url": "https://example.com/script-a.zip",
            "icon": "terminal.fill",
            "type": "tile",
            "changelog": "Fixed a bug"
        }
        """
        let entry = try decode(json)
        #expect(entry.icon      == "terminal.fill")
        #expect(entry.type      == "tile")
        #expect(entry.changelog == "Fixed a bug")
    }

    @Test func optionalFieldsNilWhenAbsent() throws {
        let json = """
        {
            "id": "x",
            "name": "X",
            "version": "1.0",
            "description": "",
            "download_url": "https://example.com/x.zip"
        }
        """
        let entry = try decode(json)
        #expect(entry.icon      == nil)
        #expect(entry.type      == nil)
        #expect(entry.changelog == nil)
    }

    @Test func throwsOnMissingRequiredField() {
        let json = """
        {
            "id": "x",
            "name": "X",
            "version": "1.0",
            "description": ""
        }
        """
        // download_url is missing — decoding must throw
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))
        }
    }

    @Test func idMatchesIdentifiable() throws {
        let json = """
        {
            "id": "unique-id",
            "name": "N",
            "version": "1.0",
            "description": "",
            "download_url": "https://example.com/n.zip"
        }
        """
        let entry = try decode(json)
        #expect(entry.id == "unique-id")  // Identifiable.id == CodingKeys.id
    }
}

// MARK: - ScriptCatalogService.recomputeUpdates

@Suite("ScriptCatalogService.recomputeUpdates")
@MainActor
struct ScriptCatalogServiceRecomputeTests {

    private func makeService(entries: [CatalogEntry]) -> ScriptCatalogService {
        ScriptCatalogService(entries: entries)
    }

    private func catalogEntry(id: String, version: String) -> CatalogEntry {
        CatalogEntry(
            id: id,
            name: id,
            version: version,
            description: "",
            icon: nil,
            type: nil,
            changelog: nil,
            downloadURL: URL(string: "https://example.com/\(id).zip")!
        )
    }

    private func managedScript(id: String, version: String) -> StubScript {
        StubScript(id: id, version: version)
    }

    @Test func noUpdatesWhenCatalogEmpty() {
        let svc = makeService(entries: [])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.0")])
        #expect(svc.availableUpdates.isEmpty)
    }

    @Test func noUpdatesWhenNothingInstalled() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "2.0.0")])
        svc.recomputeUpdates(installedScripts: [])
        #expect(svc.availableUpdates.isEmpty)
    }

    @Test func noUpdateWhenSameVersion() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "1.0.0")])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.0")])
        #expect(svc.availableUpdates.isEmpty)
    }

    @Test func noUpdateWhenInstalledIsNewer() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "1.0.0")])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "2.0.0")])
        #expect(svc.availableUpdates.isEmpty)
    }

    @Test func detectsUpdate() {
        let entry = catalogEntry(id: "a", version: "2.0.0")
        let svc = makeService(entries: [entry])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.0")])
        #expect(svc.availableUpdates["a"]?.version == "2.0.0")
    }

    @Test func detectsPatchUpdate() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "1.0.1")])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.0")])
        #expect(svc.availableUpdates["a"] != nil)
    }

    @Test func detectsMinorUpdate() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "1.1.0")])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.9")])
        #expect(svc.availableUpdates["a"] != nil)
    }

    @Test func mixedScripts() {
        let svc = makeService(entries: [
            catalogEntry(id: "a", version: "2.0.0"),   // update available
            catalogEntry(id: "b", version: "1.0.0"),   // same version
            catalogEntry(id: "c", version: "0.9.0"),   // catalog older than installed
            catalogEntry(id: "d", version: "3.0.0"),   // not installed
        ])
        svc.recomputeUpdates(installedScripts: [
            managedScript(id: "a", version: "1.0.0"),
            managedScript(id: "b", version: "1.0.0"),
            managedScript(id: "c", version: "1.0.0"),
        ])
        #expect(svc.availableUpdates.count == 1)
        #expect(svc.availableUpdates["a"] != nil)
        #expect(svc.availableUpdates["b"] == nil)
        #expect(svc.availableUpdates["c"] == nil)
        #expect(svc.availableUpdates["d"] == nil)
    }

    @Test func recomputeClearsStaleUpdates() {
        let svc = makeService(entries: [catalogEntry(id: "a", version: "2.0.0")])
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "1.0.0")])
        #expect(svc.availableUpdates["a"] != nil)

        // Now "install" the update — recompute should clear it
        svc.recomputeUpdates(installedScripts: [managedScript(id: "a", version: "2.0.0")])
        #expect(svc.availableUpdates.isEmpty)
    }
}
