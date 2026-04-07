import Foundation

/// Shared semver-style version comparison used by ScriptCatalogService and ScriptInstaller.
public enum VersionComparison {

    /// Compare two version strings component by component (dot-separated integers).
    /// Falls back to string comparison for non-numeric versions.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let length = max(aParts.count, bParts.count)
        for i in 0..<length {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        // Non-numeric fallback (e.g. "1.0.0-beta")
        if aParts.isEmpty || bParts.isEmpty { return a.compare(b) }
        return .orderedSame
    }
}
