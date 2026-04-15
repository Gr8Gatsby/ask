#if canImport(AskMacCore)
import AskMacCore
#endif
import CloudKit
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
    private let localHTTPServer = LocalHTTPServer(port: 4242)

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
            let lhs = localHTTPServer
            Task {
                await ck.checkAccountStatus()
                hb.start()
                mw.start(scriptManager: sm)
                sm.start()
                rp.start(scriptManager: sm)
                // Purge old records in the background after services are running.
                await ck.purgeOldRecords(machineID: s.machineID)
                // Start local HTTP server for MockAskMac dev UI
                await MainActor.run {
                    lhs.configure(scriptManager: sm, machineName: s.machineName, cloudKit: ck, machineID: s.machineID)
                    lhs.start()
                    sm.localHTTPServer = lhs
                }
                // Seed HTTP server with existing CloudKit blocks so sessions
                // that were active before this AskMac session are visible immediately.
                let ckRecords = await ck.fetchActiveBlocks(machineID: s.machineID)
                let ckDicts = ckRecords.compactMap { record -> [String: Any]? in
                    guard let blockID  = record[CKSchema.RKBlock.blockID]  as? String,
                          let scriptID = record[CKSchema.RKBlock.scriptID] as? String,
                          let payload  = record[CKSchema.RKBlock.payload]  as? String
                    else { return nil }
                    let createdAt = (record[CKSchema.RKBlock.createdAt] as? Date) ?? Date()
                    var dict: [String: Any] = [
                        "blockID":          blockID,
                        "machineID":        s.machineID,
                        "scriptID":         scriptID,
                        "scriptName":       record[CKSchema.RKBlock.scriptName]  as? String ?? scriptID,
                        "blockType":        record[CKSchema.RKBlock.blockType]   as? String ?? "tile",
                        "scriptType":       record[CKSchema.RKBlock.scriptType]  as? String ?? "tile",
                        "createdAt":        ISO8601DateFormatter().string(from: createdAt),
                        "requiresResponse": record[CKSchema.RKBlock.requiresResponse] as? Int ?? 0,
                        "showsInInbox":     record[CKSchema.RKBlock.showsInInbox]     as? Int ?? 0,
                        "payload":          payload,
                    ]
                    if let svg = record[CKSchema.RKBlock.scriptIconSVG] as? String { dict["scriptIconSVG"] = svg }
                    return dict
                }
                await MainActor.run { lhs.seedFromCloudKit(ckDicts) }
                // Seed historical tasks from CloudKit so the web feed shows full history.
                if let tasks = try? await ck.fetchTasks(machineID: s.machineID) {
                    await MainActor.run { lhs.seedTasksFromCloudKit(tasks) }
                }
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

    private var isDevBuild: Bool {
        let exe = CommandLine.arguments.first ?? ""
        return exe.contains("DerivedData") || exe.contains("/.build/")
    }

    var body: some View {
        Image(systemName: isDevBuild ? "icloud" : "icloud.fill")
            .symbolEffect(.pulse, isActive: hasActiveScripts)
    }
}
