import SwiftUI
import CloudKit
import UIKit

extension Notification.Name {
    static let askRefreshRequired = Notification.Name("AskRefreshRequired")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Called by iOS when a silent push arrives — including when the app is backgrounded.
    /// Posts askRefreshRequired so any open HomeView fetches immediately.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
        completionHandler(.newData)
    }
}

// MARK: - App

@main
struct askApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var cloudKit = iOSCloudKitService()
    @State private var push: PushService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = CKContainer(identifier: CKSchema.containerID)
        _push = State(initialValue: PushService(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(cloudKit)
                .task { await push.setup() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // App foregrounded — trigger a data refresh
                push.handleRemoteNotification()
            }
        }
    }
}
