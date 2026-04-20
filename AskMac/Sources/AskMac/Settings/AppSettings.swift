import Foundation
import IOKit
import Observation
import SystemConfiguration

@Observable
final class AppSettings {
    private enum Key {
        static let machineID = "machineID"
        static let machineName = "machineName"
        static let vaultPath = "vaultPath"
        static let disabledScripts = "disabledScripts"
        static let feedScheduleOverrides = "feedScheduleOverrides"
        static let usesBundledScripts = "usesBundledScripts"
        static let skippedDepChecks = "skippedDepChecks"
        static let brandColorOverrides = "brandColorOverrides"
        static let svgOverrides = "svgOverrides"
        static let pinnedScripts = "pinnedScripts"
        static let grantedPermissions = "grantedPermissions"
        static let deniedScriptIDs = "deniedScriptIDs"
        static let permissionsMigrationDone = "permissionsMigrationDone"
        static let showPermissionMigrationBanner = "showPermissionMigrationBanner"
        static let nudgeDismissed = "nudgeDismissed"
        static let hasSeenOnboarding = "hasSeenOnboarding"
    }

    static let maxPins = 20

    private let defaults: UserDefaults

    // Stable machine identity, generated once and persisted
    let machineID: String

    var machineName: String {
        didSet { defaults.set(machineName, forKey: Key.machineName) }
    }

    var vaultPath: URL? {
        didSet {
            defaults.set(vaultPath?.path, forKey: Key.vaultPath)
        }
    }

    var disabledScripts: Set<String> {
        didSet { defaults.set(Array(disabledScripts), forKey: Key.disabledScripts) }
    }

    var usesBundledScripts: Bool {
        didSet { defaults.set(usesBundledScripts, forKey: Key.usesBundledScripts) }
    }

    /// Keys are "scriptID:depID". If present, the dep check is skipped (treated as passing).
    var skippedDepChecks: Set<String> {
        didSet { defaults.set(Array(skippedDepChecks), forKey: Key.skippedDepChecks) }
    }

    /// Schedule overrides from iOS, keyed by scriptID → cron expression.
    private(set) var feedScheduleOverrides: [String: String] = [:]

    /// Per-script brand background color overrides, keyed by scriptID → "#RRGGBB".
    var brandColorOverrides: [String: String] {
        didSet { defaults.set(brandColorOverrides, forKey: Key.brandColorOverrides) }
    }

    /// Per-script SVG icon overrides, keyed by scriptID → raw SVG markup.
    var svgOverrides: [String: String] {
        didSet { defaults.set(svgOverrides, forKey: Key.svgOverrides) }
    }

    /// Ordered list of pinned script IDs shown in the menu bar panel (max 5).
    var pinnedScripts: [String] {
        didSet { defaults.set(pinnedScripts, forKey: Key.pinnedScripts) }
    }

    /// Per-script granted permission tokens. Keys are script IDs, values are arrays of token strings.
    var grantedPermissions: [String: [String]] {
        didSet { defaults.set(grantedPermissions, forKey: Key.grantedPermissions) }
    }

    /// Script IDs where the user explicitly denied permissions.
    var deniedScriptIDs: Set<String> {
        didSet { defaults.set(Array(deniedScriptIDs), forKey: Key.deniedScriptIDs) }
    }

    /// True after the one-time migration that auto-grants permissions for existing scripts.
    var permissionsMigrationDone: Bool {
        didSet { defaults.set(permissionsMigrationDone, forKey: Key.permissionsMigrationDone) }
    }

    /// True until the user dismisses the one-time migration notice in the popover.
    var showPermissionMigrationBanner: Bool {
        didSet { defaults.set(showPermissionMigrationBanner, forKey: Key.showPermissionMigrationBanner) }
    }

    /// True once the user dismisses the post-onboarding "Add more scripts" nudge.
    var nudgeDismissed: Bool {
        didSet { defaults.set(nudgeDismissed, forKey: Key.nudgeDismissed) }
    }

    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Key.hasSeenOnboarding) }
    }

    var isConfigured: Bool {
        !machineName.isEmpty
    }

    /// Returns the IOPlatformUUID — a hardware-level identifier stable across reinstalls.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? String
    }

    /// The Mac's computer name as set in System Settings › General › About.
    /// This is the same name shown in Finder and About This Mac.
    static var defaultMachineName: String {
        if let cfName = SCDynamicStoreCopyComputerName(nil, nil) {
            return cfName as String
        }
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Use hardware UUID as stable machine identity — survives reinstalls and dev cycles.
        // Falls back to a stored random UUID only if IOKit is unavailable.
        if let hwUUID = AppSettings.hardwareUUID() {
            self.machineID = hwUUID
        } else if let existing = defaults.string(forKey: Key.machineID) {
            self.machineID = existing
        } else {
            let newID = UUID().uuidString
            defaults.set(newID, forKey: Key.machineID)
            self.machineID = newID
        }

        let storedName = defaults.string(forKey: Key.machineName) ?? ""
        if storedName.isEmpty {
            let name = AppSettings.defaultMachineName
            self.machineName = name
            defaults.set(name, forKey: Key.machineName)
        } else {
            self.machineName = storedName
        }

        if let path = defaults.string(forKey: Key.vaultPath) {
            self.vaultPath = URL(fileURLWithPath: path)
        } else {
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ask/scripts")
            self.vaultPath = fallback
            defaults.set(fallback.path, forKey: Key.vaultPath)
        }

        // In dev builds, override vault to ~/.ask/dev-vault in memory only.
        // Using ~/.ask/ avoids TCC prompts that fire when accessing ~/Documents/.
        // Debug and prod share the same UserDefaults domain (same bundle ID), so we
        // must not write this override to disk.
        let exe = CommandLine.arguments.first ?? ""
        if exe.contains("DerivedData") || exe.contains("/.build/") {
            let devVault = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ask/dev-vault")
            if FileManager.default.fileExists(atPath: devVault.path) {
                self.vaultPath = devVault
            }
        }

        let storedDisabled = defaults.stringArray(forKey: Key.disabledScripts) ?? []
        self.disabledScripts = Set(storedDisabled)

        self.feedScheduleOverrides = (defaults.dictionary(forKey: Key.feedScheduleOverrides) as? [String: String]) ?? [:]

        // Dev builds default to false so bundled scripts don't interfere with onboarding testing.
        // Release builds default to true so scripts load out of the box.
        if defaults.object(forKey: Key.usesBundledScripts) == nil {
            let exe = CommandLine.arguments.first ?? ""
            let isDevBuild = exe.contains("DerivedData") || exe.contains("/.build/")
            defaults.set(!isDevBuild, forKey: Key.usesBundledScripts)
        }
        self.usesBundledScripts = defaults.bool(forKey: Key.usesBundledScripts)

        let storedSkipped = defaults.stringArray(forKey: Key.skippedDepChecks) ?? []
        self.skippedDepChecks = Set(storedSkipped)

        self.brandColorOverrides = (defaults.dictionary(forKey: Key.brandColorOverrides) as? [String: String]) ?? [:]
        self.svgOverrides = (defaults.dictionary(forKey: Key.svgOverrides) as? [String: String]) ?? [:]
        self.pinnedScripts = defaults.stringArray(forKey: Key.pinnedScripts) ?? []

        self.grantedPermissions = (defaults.dictionary(forKey: Key.grantedPermissions) as? [String: [String]]) ?? [:]
        self.deniedScriptIDs = Set(defaults.stringArray(forKey: Key.deniedScriptIDs) ?? [])
        self.permissionsMigrationDone = defaults.bool(forKey: Key.permissionsMigrationDone)
        self.showPermissionMigrationBanner = defaults.bool(forKey: Key.showPermissionMigrationBanner)
        self.nudgeDismissed = defaults.bool(forKey: Key.nudgeDismissed)

        // Dev builds always start with onboarding unseen so it can be tested repeatedly.
        let isDevExe = (CommandLine.arguments.first ?? "").contains("DerivedData")
            || (CommandLine.arguments.first ?? "").contains("/.build/")
        self.hasSeenOnboarding = isDevExe ? false : defaults.bool(forKey: Key.hasSeenOnboarding)
    }

    func isDepCheckSkipped(scriptID: String, depID: String) -> Bool {
        skippedDepChecks.contains("\(scriptID):\(depID)")
    }

    func setDepCheckSkipped(scriptID: String, depID: String, skipped: Bool) {
        let key = "\(scriptID):\(depID)"
        if skipped { skippedDepChecks.insert(key) } else { skippedDepChecks.remove(key) }
    }

    func setScriptEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledScripts.remove(id)
        } else {
            disabledScripts.insert(id)
        }
    }

    func brandColorOverride(for scriptID: String) -> String? { brandColorOverrides[scriptID] }
    func setBrandColorOverride(scriptID: String, hex: String?) {
        if let hex { brandColorOverrides[scriptID] = hex } else { brandColorOverrides.removeValue(forKey: scriptID) }
    }
    func svgOverride(for scriptID: String) -> String? { svgOverrides[scriptID] }
    func setSVGOverride(scriptID: String, svg: String?) {
        if let svg { svgOverrides[scriptID] = svg } else { svgOverrides.removeValue(forKey: scriptID) }
    }

    func isPinned(_ id: String) -> Bool { pinnedScripts.contains(id) }

    func pinScript(_ id: String) {
        guard !pinnedScripts.contains(id) else { return }
        guard pinnedScripts.count < AppSettings.maxPins else { return }
        pinnedScripts.append(id)
    }

    func unpinScript(_ id: String) {
        pinnedScripts.removeAll { $0 == id }
    }

    func feedScheduleOverride(for scriptID: String) -> String? {
        feedScheduleOverrides[scriptID]
    }

    func setFeedScheduleOverride(scriptID: String, schedule: String?) {
        if let schedule {
            feedScheduleOverrides[scriptID] = schedule
        } else {
            feedScheduleOverrides.removeValue(forKey: scriptID)
        }
        defaults.set(feedScheduleOverrides, forKey: Key.feedScheduleOverrides)
    }

    // MARK: - Script permissions

    func permissionsGranted(for scriptID: String) -> Set<String> {
        Set(grantedPermissions[scriptID] ?? [])
    }

    func grantPermissions(_ permissions: [String], for scriptID: String) {
        var existing = Set(grantedPermissions[scriptID] ?? [])
        existing.formUnion(permissions)
        grantedPermissions[scriptID] = Array(existing)
        deniedScriptIDs.remove(scriptID)
    }

    func denyScript(_ scriptID: String) {
        deniedScriptIDs.insert(scriptID)
    }

    func resetScriptPermissions(for scriptID: String) {
        grantedPermissions.removeValue(forKey: scriptID)
        deniedScriptIDs.remove(scriptID)
    }
}
