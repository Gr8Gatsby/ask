import SwiftUI
import CloudKit

@main
struct askApp: App {
    @State private var cloudKit = iOSCloudKitService()
    @State private var push: PushService

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
    }
}
