import SwiftUI
import CloudKit
import UIKit
import UserNotifications
import SwiftData

private let feedHistoryContainer: ModelContainer = {
    let config = ModelConfiguration(cloudKitDatabase: .none)
    return try! ModelContainer(
        for: FeedHistoryEntry.self, ChatSession.self, ChatEntry.self,
            TaskRecord.self, TaskMessage.self, ArtifactRecord.self,
        configurations: config
    )
}()

extension Notification.Name {
    static let askRefreshRequired    = Notification.Name("AskRefreshRequired")
    static let askNavigateToScript   = Notification.Name("AskNavigateToScript")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Push] Device token: \(token)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] Failed to register: \(error)")
    }

    /// Silent push from CloudKit — trigger a data refresh.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
        completionHandler(.newData)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification banners even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle tap on a notification — navigate to the relevant script.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let id = response.notification.request.identifier

        var scriptID: String?

        // CloudKit alert push — extract scriptID from record fields
        if let ckNote = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
           let sid = ckNote.recordFields?["scriptID"] as? String {
            scriptID = sid
        }
        // Local notification — identifier format: "ask-action-{scriptID}-{blockID}"
        else if id.hasPrefix("ask-action-") {
            let parts = id.dropFirst("ask-action-".count).split(separator: "-", maxSplits: 1)
            scriptID = parts.first.map(String.init)
        }

        if let scriptID {
            // Persist for cold-start: HomeView may not be in the hierarchy yet when this fires.
            UserDefaults.standard.set(scriptID, forKey: "pendingNavigationScriptID")
            NotificationCenter.default.post(
                name: .askNavigateToScript,
                object: nil,
                userInfo: ["scriptID": scriptID]
            )
        }
        completionHandler()
    }
}

// MARK: - App

@main
struct askApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var cloudKit = iOSCloudKitService()
    @State private var push: PushService
    @State private var actionInbox = ActionInboxStore()
    @State private var taskHistory: TaskHistoryStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = CKContainer(identifier: CKSchema.containerID)
        _push = State(initialValue: PushService(container: container))

        let ck = iOSCloudKitService()
        let ctx = feedHistoryContainer.mainContext
        _cloudKit = State(initialValue: ck)
        _taskHistory = State(initialValue: TaskHistoryStore(cloudKit: ck, modelContext: ctx))

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        appearance.shadowColor = UIColor.separator.withAlphaComponent(0.5)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(cloudKit)
                .environment(actionInbox)
                .environment(taskHistory)
                .task { await push.setup() }
        }
        .modelContainer(feedHistoryContainer)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                push.handleRemoteNotification()
            }
        }
    }
}
