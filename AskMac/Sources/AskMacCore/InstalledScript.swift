/// Minimal interface required by ScriptCatalogService to detect available updates.
/// ManagedScript (in AskMac) conforms to this protocol.
public protocol InstalledScript {
    var id: String { get }
    var version: String? { get }
}
