import Foundation
import UserNotifications
import Observation

/// Polls CloudKit for messages sent from the iPhone and shows macOS notifications.
/// Also sends outbound messages from the Mac to the iPhone.
@Observable
final class MessageWatcherService {
    private let cloudKit: CloudKitService
    private let machineID: String
    private var pollTask: Task<Void, Never>?
    private var lastChecked: Date = .distantPast

    init(cloudKit: CloudKitService, machineID: String) {
        self.cloudKit = cloudKit
        self.machineID = machineID
    }

    func start() {
        requestNotificationPermission()
        // Start slightly in the future so only new messages after launch are shown
        lastChecked = Date()
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(10))
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
            showNotification(text: message.text)
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
