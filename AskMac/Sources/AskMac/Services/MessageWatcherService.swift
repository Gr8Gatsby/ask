import Foundation
import Observation

/// Polls CloudKit for messages sent from the iPhone into an active session.
/// Messages with a sessionID are routed to the owning script via MCPConnection,
/// then `readAt` is written back so the iPhone can show a "Delivered" status.
@Observable
final class MessageWatcherService {
    private let cloudKit: CloudKitService
    private let machineID: String
    private var pollTask: Task<Void, Never>?
    private var lastChecked: Date = .distantPast
    private weak var scriptManager: ScriptManager?

    init(cloudKit: CloudKitService, machineID: String) {
        self.cloudKit = cloudKit
        self.machineID = machineID
    }

    func start(scriptManager: ScriptManager? = nil) {
        self.scriptManager = scriptManager
        // Start slightly in the future so only new messages after launch are delivered
        lastChecked = Date()
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func poll() async {
        let since = lastChecked
        lastChecked = Date()
        // Use a 30s lookback buffer to catch messages delayed by CloudKit propagation.
        let queryFrom = since.addingTimeInterval(-30)
        guard let messages = try? await cloudKit.fetchNewMessages(machineID: machineID, since: queryFrom),
              !messages.isEmpty
        else { return }

        for message in messages {
            guard let sessionID = message.sessionID, let scriptID = message.scriptID else { continue }
            if let conn = scriptManager?.connection(for: scriptID) {
                conn.deliverChatMessage(
                    sessionID: sessionID,
                    messageID: message.messageID,
                    text: message.text
                )
                print("[MessageWatcher] chat_message → scriptID=\(scriptID) sessionID=\(sessionID)")
            } else {
                print("[MessageWatcher] no connection for scriptID=\(scriptID), dropping message")
            }
            // Write readAt regardless — confirms receipt even if script is offline
            await cloudKit.markMessageRead(messageID: message.messageID)
        }
    }
}
