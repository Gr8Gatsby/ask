import SwiftUI

@main
struct askApp: App {
    @State private var cloudKit = iOSCloudKitService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(cloudKit)
        }
    }
}
