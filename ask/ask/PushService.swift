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
        await UIApplication.shared.registerForRemoteNotifications()
        await saveSubscriptionsIfNeeded()
    }

    // MARK: - Private

    private func requestPermission() async {
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func saveSubscriptionsIfNeeded() async {
        let ids = ["ask-job-completed", "ask-job-waiting"]
        let existing = (try? await database.subscriptions(for: ids.map { CKSubscription.ID($0) })) ?? [:]
        let missing = ids.filter { existing[$0] == nil }
        guard !missing.isEmpty else { return }

        var toSave: [CKSubscription] = []

        if missing.contains("ask-job-completed") {
            toSave.append(makeSubscription(
                id: "ask-job-completed",
                statuses: ["completed", "failed"],
                title: "Job finished",
                body: "Your job has completed on $(machineID)."
            ))
        }

        if missing.contains("ask-job-waiting") {
            toSave.append(makeSubscription(
                id: "ask-job-waiting",
                statuses: ["waiting"],
                title: "Waiting for input",
                body: "$(prompt)"
            ))
        }

        try? await database.modifySubscriptions(saving: toSave, deleting: [])
    }

    private func makeSubscription(id: String, statuses: [String], title: String, body: String) -> CKQuerySubscription {
        let predicate = NSPredicate(format: "status IN %@", statuses)
        let sub = CKQuerySubscription(
            recordType: "Job",
            predicate: predicate,
            subscriptionID: id,
            options: [.firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = title
        info.alertBody = body
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        sub.notificationInfo = info
        return sub
    }
}
