import Foundation
import CloudKit
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
        UIApplication.shared.registerForRemoteNotifications()
        await saveSubscriptionsIfNeeded()
    }

    // MARK: - Private

    private func saveSubscriptionsIfNeeded() async {
        let subID = "ask-rkblock-changes-v2"
        let actionSubID = "ask-action-required-v1"
        let legacyID = "ask-rkblock-created"

        // Delete legacy subscriptions if present
        var toDelete: [CKSubscription.ID] = []
        for id in [legacyID, actionSubID] {
            if let existing = try? await database.subscriptions(for: [CKSubscription.ID(id)]),
               existing[id] != nil {
                toDelete.append(id)
            }
        }
        if !toDelete.isEmpty {
            _ = try? await database.modifySubscriptions(saving: [], deleting: toDelete)
        }

        // Silent push subscription — fires for all RKBlock changes.
        // No alert/sound: background refresh only. Visible notifications are disabled.
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

        _ = try? await database.modifySubscriptions(saving: [sub], deleting: [])
    }

    /// Called by the app delegate when a remote notification arrives.
    /// Posts a refresh notification so open views update immediately.
    func handleRemoteNotification() {
        NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
    }
}
