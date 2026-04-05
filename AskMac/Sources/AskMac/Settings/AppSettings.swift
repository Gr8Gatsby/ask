import Foundation
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
    }

    static let maxPins = 5

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

    var isConfigured: Bool {
        !machineName.isEmpty
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

        // Generate a stable machineID on first launch
        if let existing = defaults.string(forKey: Key.machineID) {
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
            let defaultVault = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ask/scripts")
            self.vaultPath = defaultVault
            defaults.set(defaultVault.path, forKey: Key.vaultPath)
        }

        let storedDisabled = defaults.stringArray(forKey: Key.disabledScripts) ?? []
        self.disabledScripts = Set(storedDisabled)

        self.feedScheduleOverrides = (defaults.dictionary(forKey: Key.feedScheduleOverrides) as? [String: String]) ?? [:]

        // Default to true so app bundle scripts load out of the box
        if defaults.object(forKey: Key.usesBundledScripts) == nil {
            defaults.set(true, forKey: Key.usesBundledScripts)
        }
        self.usesBundledScripts = defaults.bool(forKey: Key.usesBundledScripts)

        let storedSkipped = defaults.stringArray(forKey: Key.skippedDepChecks) ?? []
        self.skippedDepChecks = Set(storedSkipped)

        self.brandColorOverrides = (defaults.dictionary(forKey: Key.brandColorOverrides) as? [String: String]) ?? [:]
        self.svgOverrides = (defaults.dictionary(forKey: Key.svgOverrides) as? [String: String]) ?? [:]
        self.pinnedScripts = defaults.stringArray(forKey: Key.pinnedScripts) ?? []
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
}
