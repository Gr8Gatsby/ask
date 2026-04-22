import Foundation

public struct CatalogRequirement: Decodable, Sendable {
    public let id: String
    public let name: String
    /// Shell command that exits 0 when the dependency is present (e.g. "brew --version").
    public let check: String
    public let installURL: String?

    public enum CodingKeys: String, CodingKey {
        case id, name, check
        case installURL = "install_url"
    }
}

public struct CatalogEntry: Identifiable, Decodable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let icon: String?
    /// Raw SVG markup embedded from the script's icon_file, if present.
    public let svg: String?
    public let type: String?
    public let changelog: String?
    public let downloadURL: URL
    /// Permissions declared in the script's manifest (e.g. ["shell", "network"]).
    /// Optional — nil when the catalog was generated without this field.
    public let permissions: [String]?
    /// Prerequisite checks from the script's manifest requires array.
    /// Optional — nil when the catalog was generated without this field.
    public let requires: [CatalogRequirement]?
    /// Other script IDs that must be installed before this script runs.
    public let scriptDependencies: [String]?

    public enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, svg, type, changelog, permissions, requires
        case downloadURL = "download_url"
        case scriptDependencies = "script_dependencies"
    }

    public init(id: String, name: String, version: String, description: String,
                icon: String?, svg: String? = nil, type: String?, changelog: String?, downloadURL: URL,
                permissions: [String]? = nil, requires: [CatalogRequirement]? = nil,
                scriptDependencies: [String]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.svg = svg
        self.type = type
        self.changelog = changelog
        self.downloadURL = downloadURL
        self.permissions = permissions
        self.requires = requires
        self.scriptDependencies = scriptDependencies
    }
}

struct ScriptCatalog: Decodable {
    let generated: String
    let scripts: [CatalogEntry]
}
