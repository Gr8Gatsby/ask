import Foundation
import Observation

// MARK: - Agent configuration (stored locally in UserDefaults)

struct AgentConfig: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var scriptName: String           // filename within vault directory
    var capabilityNetwork: Bool
    var capabilitySubprocess: Bool
    var capabilityReadPaths: [String]
    var capabilityWritePaths: [String]
    var capabilityEnvKeys: [String]  // Keychain item names
    var timeout: Int                 // seconds

    init(
        id: String = UUID().uuidString,
        name: String,
        scriptName: String,
        capabilityNetwork: Bool = false,
        capabilitySubprocess: Bool = false,
        capabilityReadPaths: [String] = [],
        capabilityWritePaths: [String] = [],
        capabilityEnvKeys: [String] = [],
        timeout: Int = 60
    ) {
        self.id = id
        self.name = name
        self.scriptName = scriptName
        self.capabilityNetwork = capabilityNetwork
        self.capabilitySubprocess = capabilitySubprocess
        self.capabilityReadPaths = capabilityReadPaths
        self.capabilityWritePaths = capabilityWritePaths
        self.capabilityEnvKeys = capabilityEnvKeys
        self.timeout = timeout
    }

    func toAgentRecord(machineID: String) -> AgentRecord {
        AgentRecord(
            agentID: id,
            machineID: machineID,
            name: name,
            scriptName: scriptName,
            capabilities: AgentCapabilities(
                network: capabilityNetwork,
                subprocess: capabilitySubprocess,
                readPaths: capabilityReadPaths,
                writePaths: capabilityWritePaths,
                envKeys: capabilityEnvKeys,
                timeout: timeout
            )
        )
    }
}

// MARK: - AppSettings

@Observable
final class AppSettings {
    private enum Key {
        static let machineID = "machineID"
        static let machineName = "machineName"
        static let vaultPath = "vaultPath"
        static let agents = "agents"
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

    var agents: [AgentConfig] {
        didSet { saveAgents() }
    }

    var isConfigured: Bool {
        !machineName.isEmpty && vaultPath != nil && !agents.isEmpty
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

        self.machineName = defaults.string(forKey: Key.machineName) ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        if let path = defaults.string(forKey: Key.vaultPath) {
            self.vaultPath = URL(fileURLWithPath: path)
        } else {
            let defaultVault = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ask/scripts")
            self.vaultPath = defaultVault
            defaults.set(defaultVault.path, forKey: Key.vaultPath)
        }

        self.agents = Self.loadAgents(from: defaults)
    }

    func scriptURL(for agent: AgentConfig) -> URL? {
        guard let vault = vaultPath else { return nil }
        let url = vault.appendingPathComponent(agent.scriptName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func addAgent(_ agent: AgentConfig) {
        agents.append(agent)
    }

    func removeAgent(id: String) {
        agents.removeAll { $0.id == id }
    }

    func updateAgent(_ updated: AgentConfig) {
        guard let index = agents.firstIndex(where: { $0.id == updated.id }) else { return }
        agents[index] = updated
    }

    // MARK: - Private

    private func saveAgents() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        defaults.set(data, forKey: Key.agents)
    }

    private static func loadAgents(from defaults: UserDefaults) -> [AgentConfig] {
        guard
            let data = defaults.data(forKey: Key.agents),
            let decoded = try? JSONDecoder().decode([AgentConfig].self, from: data)
        else { return [] }
        return decoded
    }
}
