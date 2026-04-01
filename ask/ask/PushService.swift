import Foundation
import CloudKit
import UserNotifications
import UIKit

/// Registers for push notifications and maintains a CloudKit subscription
/// so the device receives a silent push when a new RKBlock is created.
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
        let subID = "ask-rkblock-changes-v2"
        let actionSubID = "ask-action-required-v1"
        let legacyID = "ask-rkblock-created"

        // Delete legacy creation-only subscription if present
        if let existing = try? await database.subscriptions(for: [CKSubscription.ID(legacyID)]),
           existing[legacyID] != nil {
            _ = try? await database.modifySubscriptions(saving: [], deleting: [legacyID])
        }

        // Always re-save subscriptions to ensure current settings are applied.
        // CloudKit replaces any existing subscription with the same ID.

        // Silent push subscription — fires for all RKBlock changes
        let sub = CKQuerySubscription(
            recordType: CKSchema.RecordType.rkBlock,
            predicate: NSPredicate(value: true),
            subscriptionID: subID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        sub.notificationInfo = info

        // Alert push subscription — fires when a block requires a response
        // Delivers a visible notification even when the app is terminated
        let actionSub = CKQuerySubscription(
            recordType: CKSchema.RecordType.rkBlock,
            predicate: NSPredicate(format: "requiresResponse == 1"),
            subscriptionID: actionSubID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let actionInfo = CKSubscription.NotificationInfo()
        actionInfo.shouldSendContentAvailable = true
        actionInfo.titleLocalizationKey = "%1$@"
        actionInfo.titleLocalizationArgs = ["scriptName"]
        actionInfo.alertBody = "Action required"
        actionInfo.soundName = "default"
        actionInfo.desiredKeys = ["scriptID", "scriptName"]
        actionSub.notificationInfo = actionInfo

        _ = try? await database.modifySubscriptions(saving: [sub, actionSub], deleting: [])
    }

    /// Called by the app delegate when a remote notification arrives.
    /// Posts a refresh notification so open views update immediately.
    func handleRemoteNotification() {
        NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
    }
}
