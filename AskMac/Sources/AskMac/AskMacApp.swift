import SwiftUI

@main
struct AskMacApp: App {
    private let settings = AppSettings()
    private let cloudKit = CloudKitService()

    @State private var heartbeat: HeartbeatService
    @State private var messageWatcher: MessageWatcherService
    @State private var actionHistory: ActionHistoryService
    @State private var scriptManager: ScriptManager
    @State private var responsePoller: ResponsePoller

    init() {
        let s = settings
        let ck = cloudKit
        let hb = HeartbeatService(cloudKit: ck, settings: s)
        let mw = MessageWatcherService(cloudKit: ck, machineID: s.machineID)
        let ah = ActionHistoryService()
        let sm = ScriptManager(cloudKit: ck, machineID: s.machineID)
        let rp = ResponsePoller(cloudKit: ck, machineID: s.machineID)

        _heartbeat = State(initialValue: hb)
        _messageWatcher = State(initialValue: mw)
        _actionHistory = State(initialValue: ah)
        _scriptManager = State(initialValue: sm)
        _responsePoller = State(initialValue: rp)

        Task {
            await ck.checkAccountStatus()
            await ck.purgeOldRecords(machineID: s.machineID)
            hb.start()
            mw.start()
            sm.start()
            rp.start(scriptManager: sm)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(heartbeat)
                .environment(messageWatcher)
                .environment(scriptManager)
                .environment(actionHistory)
        } label: {
            MenuBarLabel(hasActiveScripts: scriptManager.scripts.contains { $0.status == .running })
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

        Window("Action History", id: "history") {
            HistoryView()
                .environment(actionHistory)
        }
        .defaultSize(width: 720, height: 520)
        .defaultPosition(.center)
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    let hasActiveScripts: Bool

    var body: some View {
        Image(systemName: "icloud.fill")
            .symbolEffect(.pulse, isActive: hasActiveScripts)
            .foregroundStyle(Color.accentColor)
    }
}
