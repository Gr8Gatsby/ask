import Foundation
import Observation

/// Polls CloudKit for RKResponse records and routes each one to the
/// MCPConnection that owns the corresponding script.
@Observable
final class ResponsePoller {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let actionHistory: ActionHistoryService
    private var pollTask: Task<Void, Never>?

    init(cloudKit: CloudKitService, machineID: String, actionHistory: ActionHistoryService) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.actionHistory = actionHistory
    }

    func start(scriptManager: ScriptManager) {
        pollTask = Task {
            while !Task.isCancelled {
                await poll(scriptManager: scriptManager)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func poll(scriptManager: ScriptManager) async {
        // Drain block responses
        if let responses = try? await cloudKit.drainRKResponses(machineID: machineID) {
            for response in responses {
                print("[ResponsePoller] blockID=\(response.blockID) scriptID=\(response.scriptID) value=\(response.value)")

                let scriptName = scriptManager.scripts.first(where: { $0.id == response.scriptID })?.name
                    ?? response.scriptID
                actionHistory.recordBlockResponse(scriptName: scriptName, value: response.value, blockID: response.blockID)

                guard let conn = scriptManager.connection(for: response.scriptID) else {
                    print("[ResponsePoller] No connection for scriptID=\(response.scriptID)")
                    continue
                }
                conn.deliverResponse(blockID: response.blockID, value: response.value)
            }
        }

        // Drain iOS invoke requests
        if let scriptIDs = try? await cloudKit.drainInvokeRequests(machineID: machineID) {
            for scriptID in scriptIDs {
                print("[ResponsePoller] invoke request for scriptID=\(scriptID)")
                scriptManager.invokeScript(id: scriptID)
            }
        }
    }
}
