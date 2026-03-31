import Foundation
import Observation

@Observable
final class AppSettings {
    private enum Key {
        static let machineID = "machineID"
        static let machineName = "machineName"
        static let vaultPath = "vaultPath"
        static let disabledScripts = "disabledScripts"
        static let feedScheduleOverrides = "feedScheduleOverrides"
    }

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

    /// Schedule overrides from iOS, keyed by scriptID → cron expression.
    private(set) var feedScheduleOverrides: [String: String] = [:]

    var isConfigured: Bool {
        !machineName.isEmpty
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
            let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            self.machineName = hostname
            defaults.set(hostname, forKey: Key.machineName)
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
    }

    func setScriptEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledScripts.remove(id)
        } else {
            disabledScripts.insert(id)
        }
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
