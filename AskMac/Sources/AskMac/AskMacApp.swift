import SwiftUI

@main
struct AskMacApp: App {
    private let settings = AppSettings()
    private let cloudKit = CloudKitService()

    @State private var heartbeat: HeartbeatService
    @State private var executor: JobExecutor
    @State private var watcher: JobWatcher

    init() {
        let s = settings
        let ck = cloudKit
        let hb = HeartbeatService(cloudKit: ck, settings: s)
        let ex = JobExecutor(cloudKit: ck, settings: s)
        let jw = JobWatcher(cloudKit: ck, executor: ex, heartbeat: hb, settings: s)

        _heartbeat = State(initialValue: hb)
        _executor = State(initialValue: ex)
        _watcher = State(initialValue: jw)

        // Start services immediately on launch.
        Task {
            await ck.checkAccountStatus()
            hb.start()
            jw.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(watcher)
                .environment(heartbeat)
        } label: {
            MenuBarLabel(isBusy: watcher.isExecuting)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    let isBusy: Bool

    var body: some View {
        Image(systemName: isBusy ? "bolt.fill" : "bolt")
            .symbolEffect(.pulse, isActive: isBusy)
    }
}
