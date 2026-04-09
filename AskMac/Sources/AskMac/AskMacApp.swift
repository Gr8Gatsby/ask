#if canImport(AskMacCore)
import AskMacCore
#endif
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
    @State private var scriptCatalog = ScriptCatalogService()

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

        if MacUITestingSupport.isUITesting {
            sm.loadMockScenario(MacUITestingSupport.scenario)
        } else {
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
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(heartbeat)
                .environment(scriptManager)
                .environment(actionHistory)
                .environment(scriptUpdater)
                .environment(scriptCatalog)
                .environment(updater)
                .onAppear {
                    scriptUpdater.checkForUpdates()
                    scriptCatalog.fetch(installedScripts: scriptManager.scripts)
                }
        } label: {
            MenuBarLabel(hasActiveScripts: scriptManager.scripts.contains { $0.status == .running })
        }
        .menuBarExtraStyle(.window)

        Window("Ask", id: "scripts") {
            MacScriptsView()
                .environment(settings)
                .environment(scriptManager)
                .environment(actionHistory)
                .environment(heartbeat)
                .environment(cloudKit)
                .environment(updater)
                .environment(scriptCatalog)
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
    @Environment(\.openWindow) private var openWindow

    private var isDevBuild: Bool {
        let exe = CommandLine.arguments.first ?? ""
        return exe.contains("DerivedData") || exe.contains("/.build/")
    }

    var body: some View {
        Image(systemName: isDevBuild ? "icloud" : "icloud.fill")
            .symbolEffect(.pulse, isActive: hasActiveScripts)
            .onAppear {
                // In UI testing mode the menu bar icon is the first SwiftUI view rendered,
                // so we trigger the Scripts window open here — tests can then access it
                // directly via app.windows["Ask"] without clicking the menu bar icon.
                if MacUITestingSupport.isUITesting {
                    openWindow(id: "scripts")
                }
            }
    }
}
