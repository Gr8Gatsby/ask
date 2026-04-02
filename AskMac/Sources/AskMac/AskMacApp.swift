import SwiftUI

@main
struct AskMacApp: App {
    @State private var updater = AppUpdater()

    private let settings = AppSettings()
    private let cloudKit = CloudKitService()

    @State private var heartbeat: HeartbeatService
    @State private var messageWatcher: MessageWatcherService
    @State private var actionHistory: ActionHistoryService
    @State private var scriptManager: ScriptManager
    @State private var responsePoller: ResponsePoller
    @State private var scriptUpdater = ScriptUpdateService()

    init() {
        let s = settings
        let ck = cloudKit
        let hb = HeartbeatService(cloudKit: ck, settings: s)
        let mw = MessageWatcherService(cloudKit: ck, machineID: s.machineID)
        let ah = ActionHistoryService()
        let sm = ScriptManager(cloudKit: ck, machineID: s.machineID, settings: s, actionHistory: ah)
        let rp = ResponsePoller(cloudKit: ck, machineID: s.machineID, actionHistory: ah)

        _heartbeat = State(initialValue: hb)
        _messageWatcher = State(initialValue: mw)
        _actionHistory = State(initialValue: ah)
        _scriptManager = State(initialValue: sm)
        _responsePoller = State(initialValue: rp)

        Task {
            await ck.checkAccountStatus()
            hb.start()
            mw.start(scriptManager: sm)
            sm.start()
            rp.start(scriptManager: sm)
            // Purge old records in the background after services are running.
            await ck.purgeOldRecords(machineID: s.machineID)
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
                .environment(scriptUpdater)
                .onAppear { scriptUpdater.checkForUpdates() }
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

        Window("Ask", id: "scripts") {
            MacScriptsView()
                .environment(settings)
                .environment(scriptManager)
                .environment(actionHistory)
                .environment(heartbeat)
                .environment(cloudKit)
                .environment(messageWatcher)
        }
        .defaultSize(width: 720, height: 520)
        .defaultPosition(.center)

        Window("Action History", id: "history") {
            HistoryView()
                .environment(actionHistory)
        }
        .defaultSize(width: 720, height: 520)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
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
