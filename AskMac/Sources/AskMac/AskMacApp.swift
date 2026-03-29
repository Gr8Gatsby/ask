import SwiftUI

@main
struct AskMacApp: App {
    private let settings = AppSettings()
    private let cloudKit = CloudKitService()

    @State private var heartbeat: HeartbeatService
    @State private var executor: JobExecutor
    @State private var watcher: JobWatcher
    @State private var localEvents: LocalEventService
    @State private var responseWatcher: ResponseWatcherService
    @State private var messageWatcher: MessageWatcherService

    init() {
        let s = settings
        let ck = cloudKit
        let hb = HeartbeatService(cloudKit: ck, settings: s)
        let ex = JobExecutor(cloudKit: ck, settings: s)
        let jw = JobWatcher(cloudKit: ck, executor: ex, heartbeat: hb, settings: s)
        let le = LocalEventService(cloudKit: ck, machineID: s.machineID)
        let rw = ResponseWatcherService(cloudKit: ck, machineID: s.machineID)
        let mw = MessageWatcherService(cloudKit: ck, machineID: s.machineID)

        _heartbeat = State(initialValue: hb)
        _executor = State(initialValue: ex)
        _watcher = State(initialValue: jw)
        _localEvents = State(initialValue: le)
        _responseWatcher = State(initialValue: rw)
        _messageWatcher = State(initialValue: mw)

        // Start services immediately on launch.
        Task {
            await ck.checkAccountStatus()
            hb.start()
            jw.start()
            le.start()
            rw.start()
            mw.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(watcher)
                .environment(heartbeat)
                .environment(responseWatcher)
                .environment(messageWatcher)
        } label: {
            MenuBarLabel(isBusy: watcher.isExecuting)
        }
        .menuBarExtraStyle(.window)

        Window("Messages", id: "messages") {
            MacMessagesView()
                .environment(settings)
                .environment(cloudKit)
                .environment(messageWatcher)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 560)

        Window("Ask Settings", id: "settings") {
            SettingsView()
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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
