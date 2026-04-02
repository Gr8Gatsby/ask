import Foundation
import UserNotifications
import Observation

/// Polls CloudKit for messages sent from the iPhone.
/// - Chat messages (sessionID present): routed to the owning script via MCPConnection,
///   then `readAt` is written back so the iPhone can show a "Delivered" status.
/// - Legacy messages (no sessionID): shown as macOS notifications.
/// Also sends outbound messages from the Mac to the iPhone.
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
        requestNotificationPermission()
        // Start slightly in the future so only new messages after launch are shown
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

    /// Sends a message from this Mac to the iPhone.
    func send(text: String) async throws {
        try await cloudKit.saveMessage(machineID: machineID, text: text, messageID: UUID().uuidString)
    }

    // MARK: - Private

    private func poll() async {
        let since = lastChecked
        lastChecked = Date()
        guard let messages = try? await cloudKit.fetchNewMessages(machineID: machineID, since: since),
              !messages.isEmpty
        else { return }

        for message in messages {
            if let sessionID = message.sessionID, let scriptID = message.scriptID {
                // Route to the script's MCP connection and write readAt for delivery confirmation
                if let conn = scriptManager?.connection(for: scriptID) {
                    conn.deliverChatMessage(
                        sessionID: sessionID,
                        messageID: message.messageID,
                        text: message.text
                    )
                    print("[MessageWatcher] chat_message → scriptID=\(scriptID) sessionID=\(sessionID)")
                } else {
                    print("[MessageWatcher] no connection for scriptID=\(scriptID), queuing notification")
                    showNotification(text: message.text)
                }
                // Write readAt regardless — confirms receipt even if script is offline
                await cloudKit.markMessageRead(messageID: message.messageID)
            } else {
                // Legacy Messages-screen message — show notification
                showNotification(text: message.text)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Message from iPhone"
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
