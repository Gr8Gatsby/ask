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
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func poll(scriptManager: ScriptManager) async {
        guard let responses = try? await cloudKit.drainRKResponses(machineID: machineID) else { return }
        for response in responses {
            print("[ResponsePoller] blockID=\(response.blockID) scriptID=\(response.scriptID) value=\(response.value)")

            // Look up the script name for history logging
            let scriptName = scriptManager.scripts.first(where: { $0.id == response.scriptID })?.name
                ?? response.scriptID

            actionHistory.recordBlockResponse(scriptName: scriptName, value: response.value)

            guard let conn = scriptManager.connection(for: response.scriptID) else {
                print("[ResponsePoller] No connection for scriptID=\(response.scriptID)")
                continue
            }
            conn.deliverResponse(blockID: response.blockID, value: response.value)
        }
    }
}
