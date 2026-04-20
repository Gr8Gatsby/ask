import Foundation

public struct CatalogEntry: Identifiable, Decodable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let icon: String?
    public let type: String?
    public let changelog: String?
    public let downloadURL: URL
    /// Permissions declared in the script's manifest (e.g. ["shell", "network"]).
    /// Optional — nil when the catalog was generated without this field.
    public let permissions: [String]?

    public enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, type, changelog, permissions
        case downloadURL = "download_url"
    }

    public init(id: String, name: String, version: String, description: String,
                icon: String?, type: String?, changelog: String?, downloadURL: URL,
                permissions: [String]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.type = type
        self.changelog = changelog
        self.downloadURL = downloadURL
        self.permissions = permissions
    }
}

struct ScriptCatalog: Decodable {
    let generated: String
    let scripts: [CatalogEntry]
}
