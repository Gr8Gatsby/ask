import Foundation
import Observation

/// Manages one-shot agents: local persistence via AppSettings, CloudKit sync for iOS discovery.
@Observable
final class AgentManager {
    private let settings: AppSettings
    private let cloudKit: CloudKitService
    private let machineID: String

    var agents: [AgentConfig] { settings.agents }

    init(cloudKit: CloudKitService, settings: AppSettings) {
        self.cloudKit = cloudKit
        self.settings = settings
        self.machineID = settings.machineID
    }

    /// Publishes all locally-stored agents to CloudKit on startup.
    func publishAll() async {
        for agent in settings.agents {
            let record = agent.toAgentRecord(machineID: machineID)
            do {
                try await cloudKit.saveAgent(record)
            } catch {
                print("[AgentManager] Failed to publish agent \(agent.id): \(error)")
            }
        }
    }

    func add(_ config: AgentConfig) async {
        settings.addAgent(config)
        let record = config.toAgentRecord(machineID: machineID)
        do {
            try await cloudKit.saveAgent(record)
        } catch {
            print("[AgentManager] Failed to save agent \(config.id) to CloudKit: \(error)")
        }
    }

    func update(_ config: AgentConfig) async {
        settings.updateAgent(config)
        let record = config.toAgentRecord(machineID: machineID)
        do {
            try await cloudKit.saveAgent(record)
        } catch {
            print("[AgentManager] Failed to update agent \(config.id) in CloudKit: \(error)")
        }
    }

    func delete(id: String) async {
        let record = settings.agents.first(where: { $0.id == id })?.toAgentRecord(machineID: machineID)
        settings.removeAgent(id: id)
        if let record {
            do {
                try await cloudKit.deleteAgent(recordName: record.recordName)
            } catch {
                print("[AgentManager] Failed to delete agent \(id) from CloudKit: \(error)")
            }
        }
    }
}
