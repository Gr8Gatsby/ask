import Foundation
import CloudKit
import UserNotifications
import UIKit

/// Registers for push notifications and maintains CloudKit subscriptions
/// so the device receives alerts when jobs complete or need input.
@Observable
final class PushService: NSObject {
    private let database: CKDatabase

    init(container: CKContainer) {
        self.database = container.privateCloudDatabase
    }

    func setup() async {
        await requestPermission()
        UIApplication.shared.registerForRemoteNotifications()
        await saveSubscriptionsIfNeeded()
    }

    // MARK: - Private

    private func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func saveSubscriptionsIfNeeded() async {
        let ids = ["ask-job-completed", "ask-job-waiting", "ask-claude-event"]
        let existing = (try? await database.subscriptions(for: ids.map { CKSubscription.ID($0) })) ?? [:]
        let missing = ids.filter { existing[$0] == nil }
        guard !missing.isEmpty else { return }

        var toSave: [CKSubscription] = []

        if missing.contains("ask-job-completed") {
            toSave.append(makeJobSubscription(
                id: "ask-job-completed",
                statuses: ["completed", "failed"],
                title: "Job finished",
                body: "A job has completed on your Mac."
            ))
        }

        if missing.contains("ask-job-waiting") {
            toSave.append(makeJobSubscription(
                id: "ask-job-waiting",
                statuses: ["waiting"],
                title: "Waiting for input",
                body: "Claude is waiting for your input."
            ))
        }

        if missing.contains("ask-claude-event") {
            toSave.append(makeEventSubscription())
        }

        _ = try? await database.modifySubscriptions(saving: toSave, deleting: [])
    }

    private func makeJobSubscription(id: String, statuses: [String], title: String, body: String) -> CKQuerySubscription {
        let predicate = NSPredicate(format: "status IN %@", statuses)
        let sub = CKQuerySubscription(
            recordType: "Job",
            predicate: predicate,
            subscriptionID: id,
            options: [.firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.alertBody = body
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        sub.notificationInfo = info
        return sub
    }

    private func makeEventSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: "AskEvent",
            predicate: NSPredicate(value: true),
            subscriptionID: "ask-claude-event",
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Claude Code activity on your Mac"
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        sub.notificationInfo = info
        return sub
    }

    /// Called by the app delegate when a remote notification arrives (including silent pushes).
    /// Posts a refresh notification so open views update immediately without waiting for the poll interval.
    func handleRemoteNotification() {
        NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
    }
}
