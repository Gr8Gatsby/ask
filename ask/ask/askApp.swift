import SwiftUI
import CloudKit

extension Notification.Name {
    static let askRefreshRequired = Notification.Name("AskRefreshRequired")
}

@main
struct askApp: App {
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
                // Push notification tap or app-switch — trigger a data refresh
                push.handleRemoteNotification()
            }
        }
    }
}
