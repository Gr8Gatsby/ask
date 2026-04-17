#if canImport(AskMacCore)
import AskMacCore
#endif
import CloudKit
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Copy Button

private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy path")
    }
}

// MARK: - SVG dark-mode helper

/// Rewrites dark/black fill and stroke values to white so an SVG icon
/// renders legibly on dark brand card backgrounds.
private func svgToWhite(_ svg: String) -> NSImage? {
    var s = svg
    s = s.replacingOccurrences(of: "currentColor", with: "white", options: .caseInsensitive)
    let darkColors = ["#000000", "#000", "black", "#111111", "#111",
                      "#1a1a1a", "#222222", "#222", "#333333", "#333"]
    for color in darkColors {
        for attr in ["fill", "stroke"] {
            s = s.replacingOccurrences(of: "\(attr)=\"\(color)\"", with: "\(attr)=\"white\"", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr)='\(color)'",  with: "\(attr)='white'",  options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr):\(color)",    with: "\(attr):white",    options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr): \(color)",   with: "\(attr): white",   options: .caseInsensitive)
        }
    }
    guard let data = s.data(using: .utf8) else { return nil }
    return NSImage(data: data)
}

// MARK: - Color hex helpers

private extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
            Int((c.redComponent   * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent  * 255).rounded()))
    }
}

private func blockStatusColor(_ colorString: String?) -> Color {
    switch colorString {
    case "green":  .green
    case "blue":   .blue
    case "orange": .orange
    case "red":    .red
    case "yellow": .yellow
    default:       .secondary
    }
}

// MARK: - Top-level tab

private enum MacTab: String, CaseIterable {
    case scripts, app, feed, blocks, machine

    var icon: String {
        switch self {
        case .scripts:  "terminal"
        case .app:      "square.grid.2x2"
        case .feed:     "scroll"
        case .blocks:   "rectangle.stack"
        case .machine:  "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .scripts:  "Scripts"
        case .app:      "App"
        case .feed:     "Feed"
        case .blocks:   "Blocks"
        case .machine:  "Machine"
        }
    }
}

// MARK: - Mac main window

struct MacScriptsView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(ActionHistoryService.self) private var actionHistory
    @Environment(AppSettings.self) private var settings
    @Environment(CloudKitService.self) private var cloudKit

    @State private var activeTab: MacTab = .scripts
    @State private var builderBlocks: [BuilderBlock] = []
    @State private var builderShowJSON = true

    var body: some View {
        Group {
            switch activeTab {
            case .scripts:
                ScriptsTabView()
                    .environment(scriptManager)
            case .app:
                MacAppMockView()
                    .environment(scriptManager)
                    .environment(actionHistory)
            case .feed:
                MacFeedView()
                    .environment(actionHistory)
            case .blocks:
                BlocksBuilderView(blocks: $builderBlocks, showJSON: $builderShowJSON)
            case .machine:
                MachineDetailView()
                    .environment(settings)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $activeTab) {
                    ForEach(MacTab.allCases, id: \.self) { tab in
                        Image(systemName: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(activeTab.label)
            }
            if activeTab == .scripts {
                ToolbarItem(placement: .automatic) {
                    Button { scriptManager.reload() } label: {
                        Label("Reload Scripts", systemImage: "arrow.clockwise")
                    }
                    .help("Scan for new scripts and start any that aren't running yet")
                }
            }
        }
        .onAppear {
            // When opened from the MenuBarExtra the window is not automatically
            // made key, so List selection highlights and Picker segments render
            // without accent color until the user clicks. Force activation so
            // the window becomes key immediately on first open.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct LocalTilePayload {
    let label: String?
    let body: String?
    let statusColor: String?
    let actionRequired: Bool
}

private struct LocalAgentSessionSummary {
    let blockID: String
    let lastMessage: String?
    let currentPreview: String?
    let isWorking: Bool
    let pendingConfirmationTitle: String?
    let hasPendingConfirmation: Bool
}

private struct LocalAppScriptGroup: Identifiable {
    let script: ManagedScript
    let blocks: [LiveBlock]

    var id: String { script.id }

    private var tileBlock: LiveBlock? {
        blocks.first(where: { $0.blockType == "tile" })
    }

    private var tilePayload: LocalTilePayload? {
        tileBlock.flatMap { block in
            guard let dict = block.payloadDict else { return nil }
            return LocalTilePayload(
                label: dict["label"] as? String,
                body: dict["body"] as? String,
                statusColor: dict["status_color"] as? String,
                actionRequired: dict["action_required"] as? Bool ?? false
            )
        }
    }

    private var agentSessions: [LocalAgentSessionSummary] {
        blocks.compactMap { block in
            guard block.blockType == "agent_session", let dict = block.payloadDict else { return nil }
            let pending = dict["pending_confirmation"] as? [String: Any]
            return LocalAgentSessionSummary(
                blockID: block.id,
                lastMessage: dict["last_message"] as? String,
                currentPreview: dict["current_preview"] as? String,
                isWorking: dict["is_working"] as? Bool ?? false,
                pendingConfirmationTitle: pending?["title"] as? String,
                hasPendingConfirmation: pending != nil
            )
        }
    }

    var isActionRequired: Bool { tilePayload?.actionRequired == true }

    private var pendingSessionBlockIDs: Set<String> {
        Set(agentSessions.filter(\.hasPendingConfirmation).map(\.blockID))
    }

    var needsResponse: Bool {
        blocks.contains(where: \.showsInInbox) || isActionRequired || !pendingSessionBlockIDs.isEmpty
    }

    var inboxBlocks: [LiveBlock] {
        blocks.filter { $0.showsInInbox || pendingSessionBlockIDs.contains($0.id) }
    }

    var recentBlocks: [LiveBlock] {
        blocks.filter { !$0.showsInInbox && !pendingSessionBlockIDs.contains($0.id) && $0.blockType != "tile" }
    }

    var tileLabel: String? {
        if let label = tilePayload?.label { return label }
        let working = agentSessions.filter(\.isWorking).count
        guard !agentSessions.isEmpty else { return nil }
        let noun = agentSessions.count == 1 ? "session" : "sessions"
        if working > 0 {
            return working == agentSessions.count ? "\(agentSessions.count) \(noun) working" : "\(agentSessions.count) \(noun), \(working) working"
        }
        return "\(agentSessions.count) \(noun)"
    }

    var tileStatusColor: String? {
        if let color = tilePayload?.statusColor { return color }
        if agentSessions.contains(where: \.hasPendingConfirmation) { return "orange" }
        return agentSessions.contains(where: \.isWorking) ? "blue" : "gray"
    }

    var tileBody: String? {
        if let body = tilePayload?.body, !body.isEmpty { return body }
        if let pending = agentSessions.first(where: \.hasPendingConfirmation)?.pendingConfirmationTitle {
            return pending
        }
        let active = agentSessions.first(where: \.isWorking) ?? agentSessions.first
        let text = active?.lastMessage ?? active?.currentPreview
        guard let text, !text.isEmpty else { return nil }
        return text.components(separatedBy: "\n").first(where: { !$0.isEmpty })
    }
}

private extension LiveBlock {
    var payloadDict: [String: Any]? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

private enum AppMockScreen: Hashable {
    case home
    case feed
}

private struct MacAppMockView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @State private var screen: AppMockScreen = .home
    @State private var selectedScriptID: String?

    private var alertGroups: [LocalAppScriptGroup] {
        scriptManager.scripts
            .filter { !$0.isSystem }
            .compactMap { script -> LocalAppScriptGroup? in
                let blocks = Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
                    .sorted { $0.createdAt > $1.createdAt }
                let group = LocalAppScriptGroup(script: script, blocks: blocks)
                return group.needsResponse ? group : nil
            }
            .sorted { $0.script.name < $1.script.name }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content — always padded to leave room for tab bar
            Group {
                if let selectedScriptID,
                   let script = scriptManager.scripts.first(where: { $0.id == selectedScriptID }) {
                    let blocks = Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
                        .sorted { $0.createdAt > $1.createdAt }
                    MacAppScriptScreen(
                        script: script,
                        liveBlocks: blocks,
                        onBack: { self.selectedScriptID = nil },
                        onRespond: { blockID, value in
                            scriptManager.respondToBlock(scriptID: script.id, blockID: blockID, value: value)
                        }
                    )
                } else {
                    switch screen {
                    case .home:
                        MacAppHomeScreen(
                            scriptManager: scriptManager,
                            onOpenScript: { selectedScriptID = $0 }
                        )
                    case .feed:
                        MacAppFeedScreen()
                    }
                }
            }
            .padding(20)
            .padding(.bottom, alertGroups.isEmpty ? 60 : 88)

            // Floating tab bar — always visible
            VStack(spacing: 8) {
                // Alert chips: scripts that need a response
                if !alertGroups.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(alertGroups) { group in
                            Button {
                                selectedScriptID = group.script.id
                                screen = .home
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(blockStatusColor(group.tileStatusColor))
                                        .frame(width: 6, height: 6)
                                    Text(group.script.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(
                                    Capsule().stroke(blockStatusColor(group.tileStatusColor).opacity(0.35), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(group.script.name) needs attention")
                        }
                    }
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                }

                // Tab pills
                HStack(spacing: 2) {
                    ForEach([AppMockScreen.home, AppMockScreen.feed], id: \.self) { tab in
                        Button {
                            selectedScriptID = nil
                            screen = tab
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab == .home ? "house.fill" : "list.bullet")
                                    .font(.system(size: 13, weight: .medium))
                                Text(tab == .home ? "Home" : "Feed")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(activeTab == tab ? .white : .secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                activeTab == tab ? Color.accentColor : Color.clear,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
            .padding(.bottom, 16)
        }
        .navigationTitle("App")
    }

    /// The tab that should appear selected. Home is highlighted when drilling into a script.
    private var activeTab: AppMockScreen {
        selectedScriptID != nil ? .home : screen
    }
}

private struct MacAppHomeScreen: View {
    let scriptManager: ScriptManager
    let onOpenScript: (String) -> Void

    private var groups: [LocalAppScriptGroup] {
        scriptManager.scripts
            .filter { !$0.isSystem && ($0.isEnabled || !(scriptManager.activeBlocks[$0.id] ?? [:]).isEmpty) }
            .map { script in
                LocalAppScriptGroup(
                    script: script,
                    blocks: Array((scriptManager.activeBlocks[script.id] ?? [:]).values).sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted { a, b in
                if a.needsResponse != b.needsResponse { return a.needsResponse && !b.needsResponse }
                return a.script.name < b.script.name
            }
    }

    private var needsResponseGroups: [LocalAppScriptGroup] {
        groups.filter(\.needsResponse)
    }

    private var recentGroups: [LocalAppScriptGroup] {
        groups.filter { !$0.needsResponse }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Local app harness built from the same live blocks and responses the app uses.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Active App Content",
                        systemImage: "square.grid.2x2",
                        description: Text("No enabled scripts are emitting blocks right now.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else {
                    if !needsResponseGroups.isEmpty {
                        appSectionHeader("Needs Response", count: needsResponseGroups.count)
                        ForEach(needsResponseGroups) { group in
                            MacAppActionCard(group: group) { blockID, value in
                                scriptManager.respondToBlock(scriptID: group.script.id, blockID: blockID, value: value)
                            } onOpen: {
                                onOpenScript(group.script.id)
                            }
                        }
                    }

                    if !recentGroups.isEmpty {
                        appSectionHeader("Recent", count: nil)
                        ForEach(recentGroups) { group in
                            MacAppTileCard(group: group) {
                                onOpenScript(group.script.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func appSectionHeader(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

// MARK: - Task thread display models

struct TaskMessageDisplay: Identifiable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date
    let sequenceNumber: Int

    init?(from record: CKRecord) {
        guard
            let messageID = record[CKSchema.AskTaskMessage.messageID] as? String,
            let role      = record[CKSchema.AskTaskMessage.role]      as? String,
            let partsJSON = record[CKSchema.AskTaskMessage.partsJSON] as? String,
            let timestamp = record[CKSchema.AskTaskMessage.timestamp] as? Date
        else { return nil }
        self.id              = messageID
        self.role            = role
        self.timestamp       = timestamp
        self.sequenceNumber  = record[CKSchema.AskTaskMessage.sequenceNumber] as? Int ?? 0
        // Extract text from parts JSON: [{type:"text",text:"..."},...]
        if let data = partsJSON.data(using: .utf8),
           let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            self.text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            self.text = partsJSON
        }
    }
}

struct TaskArtifactDisplay: Identifiable {
    let id: String
    let filename: String
    let mimeType: String
    let description: String?
    let sizeBytes: Int
    let localURL: URL?   // CKAsset temp file URL — available immediately after fetch
    let updatedAt: Date

    init?(from record: CKRecord) {
        guard
            let artifactID = record[CKSchema.AskArtifact.artifactID] as? String,
            let filename   = record[CKSchema.AskArtifact.filename]   as? String,
            let mimeType   = record[CKSchema.AskArtifact.mimeType]   as? String,
            let updatedAt  = record[CKSchema.AskArtifact.updatedAt]  as? Date
        else { return nil }
        self.id          = artifactID
        self.filename    = filename
        self.mimeType    = mimeType
        self.description = record[CKSchema.AskArtifact.description] as? String
        self.sizeBytes   = record[CKSchema.AskArtifact.sizeBytes]   as? Int ?? 0
        self.updatedAt   = updatedAt
        self.localURL    = (record[CKSchema.AskArtifact.content] as? CKAsset)?.fileURL
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

// MARK: - Task feed store

@Observable
private final class TaskFeedStore {
    var tasks: [AskTaskRecord] = []
    var isLoading = false
    var errorMessage: String?

    var activeTasks: [AskTaskRecord] {
        tasks
            .filter { $0.status == "working" || $0.status == "input-required" }
            .sorted {
                if $0.status != $1.status { return $0.status == "input-required" }
                return $0.lastActivityAt > $1.lastActivityAt
            }
    }

    var recentTasks: [AskTaskRecord] {
        tasks
            .filter { $0.status == "completed" || $0.status == "failed" || $0.status == "cancelled" }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    @MainActor
    func refresh(cloudKit: CloudKitService, machineID: String) async {
        isLoading = true
        errorMessage = nil
        do {
            tasks = try await cloudKit.fetchTasks(machineID: machineID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Feed screen

private struct MacAppFeedScreen: View {
    @Environment(CloudKitService.self) private var cloudKit
    @Environment(AppSettings.self) private var settings
    @State private var store = TaskFeedStore()
    @State private var selectedTask: AskTaskRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.isLoading && store.tasks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let err = store.errorMessage {
                    ContentUnavailableView(
                        "Could not load feed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else if store.activeTasks.isEmpty && store.recentTasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks Yet",
                        systemImage: "checklist",
                        description: Text("Tasks from running scripts will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else {
                    if !store.activeTasks.isEmpty {
                        feedSection("Active", tasks: store.activeTasks)
                    }
                    if !store.recentTasks.isEmpty {
                        feedSection("Recent", tasks: store.recentTasks)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .refreshable { await store.refresh(cloudKit: cloudKit, machineID: settings.machineID) }
        .task { await store.refresh(cloudKit: cloudKit, machineID: settings.machineID) }
        .sheet(item: $selectedTask) { task in
            TaskThreadSheet(task: task)
                .environment(cloudKit)
                .environment(settings)
        }
    }

    @ViewBuilder
    private func feedSection(_ title: String, tasks: [AskTaskRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(tasks, id: \.recordName) { task in
                    Button { selectedTask = task } label: {
                        TaskFeedRow(task: task)
                    }
                    .buttonStyle(.plain)
                    if task.recordName != tasks.last?.recordName {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
        }
    }
}

private struct TaskFeedRow: View {
    let task: AskTaskRecord

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(task.scriptName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(task.lastActivityAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if task.artifactCount > 0 {
                    Label("\(task.artifactCount)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case "working":
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        case "input-required":
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.orange)
                .font(.title3)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        case "cancelled":
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.title3)
        }
    }
}

// MARK: - Task thread sheet

@Observable
private final class TaskThreadStore {
    var messages: [TaskMessageDisplay] = []
    var artifacts: [TaskArtifactDisplay] = []
    var isLoading = false
    var errorMessage: String?

    @MainActor
    func load(task: AskTaskRecord, cloudKit: CloudKitService) async {
        isLoading = true
        errorMessage = nil
        do {
            async let msgs = cloudKit.fetchTaskMessages(taskID: task.taskID, machineID: task.machineID)
            async let arts = cloudKit.fetchTaskArtifacts(taskID: task.taskID, machineID: task.machineID)
            let (rawMsgs, rawArts) = try await (msgs, arts)
            // Sort oldest-first by timestamp only.
            // sequenceNumber restarts at 1 on each daemon run, so using it as a
            // primary key interleaves messages from different sessions. Timestamp
            // is a real wall-clock value and never collides across runs.
            messages  = rawMsgs.sorted { $0.timestamp < $1.timestamp }
            artifacts = rawArts.sorted  { $0.updatedAt < $1.updatedAt }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct TaskThreadSheet: View {
    let task: AskTaskRecord
    @Environment(CloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss
    @State private var store = TaskThreadStore()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.headline)
                    Text(task.scriptName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            Divider()

            if store.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = store.errorMessage {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Messages — grouped so permission pairs appear as one unit
                        ForEach(groupMessages(store.messages)) { group in
                            switch group {
                            case .single(let msg):
                                MessageRow(message: msg)
                            case .permissionPair(let needed, let resolved):
                                PermissionGroupRow(needed: needed, resolved: resolved)
                            }
                        }
                        // Artifacts
                        if !store.artifacts.isEmpty {
                            if !store.messages.isEmpty {
                                Divider().padding(.vertical, 8)
                            }
                            Text("Attachments")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 6)
                            ForEach(store.artifacts) { artifact in
                                ArtifactRow(artifact: artifact)
                            }
                        }
                        if store.messages.isEmpty && store.artifacts.isEmpty {
                            ContentUnavailableView("No content", systemImage: "bubble.left",
                                                   description: Text("This task has no messages yet."))
                                .padding(.top, 20)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await store.load(task: task, cloudKit: cloudKit) }
    }
}

// MARK: - Relative time (single most-significant unit)

private func simpleRelativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(-date.timeIntervalSinceNow))
    if seconds < 60  { return "< 1 min" }
    let minutes = seconds / 60
    if minutes < 60  { return "\(minutes) min" }
    let hours = minutes / 60
    if hours   < 24  { return "\(hours) hr" }
    let days   = hours / 24
    if days    < 30  { return "\(days) day\(days == 1 ? "" : "s")" }
    let months = days / 30
    if months  < 12  { return "\(months) mo" }
    return "\(months / 12) yr"
}

// MARK: - Simple Markdown renderer

private enum MDBlock {
    case heading(level: Int, text: String)
    case code(String)
    case paragraph(String)
}

private func parseMarkdownBlocks(_ raw: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines  = raw.components(separatedBy: "\n")
    var i      = 0
    while i < lines.count {
        let line = lines[i]
        // Heading: 1–6 # characters followed by a space
        let hashes = line.prefix(while: { $0 == "#" })
        let level  = hashes.count
        if level >= 1 && level <= 6 && line.count > level,
           line[line.index(line.startIndex, offsetBy: level)] == " " {
            blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
            i += 1
            continue
        }
        // Fenced code block
        if line.hasPrefix("```") {
            var code = ""
            i += 1
            while i < lines.count && !lines[i].hasPrefix("```") {
                if !code.isEmpty { code += "\n" }
                code += lines[i]
                i += 1
            }
            i += 1 // skip closing ```
            if !code.isEmpty { blocks.append(.code(code)) }
            continue
        }
        // Blank line
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            continue
        }
        // Paragraph — collect until blank / heading / code fence
        var para: [String] = []
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if l.hasPrefix("#") { break }
            if l.hasPrefix("```") { break }
            para.append(l)
            i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
    }
    return blocks
}

private struct MarkdownBlock: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 2 ? .callout.weight(.bold) : .callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .paragraph(let text):
            // AttributedString renders inline Markdown: **bold**, *italic*, `code`, [links](url)
            let attr = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)
            Text(attr)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SimpleMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlock(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permission pair grouping

private enum MessageGroup: Identifiable {
    case single(TaskMessageDisplay)
    case permissionPair(needed: TaskMessageDisplay, resolved: TaskMessageDisplay)

    var id: String {
        switch self {
        case .single(let m):            return m.id
        case .permissionPair(let n, _): return n.id
        }
    }
}

/// Collapse consecutive "Permission needed" + "Permission resolved" pairs into one group.
private func groupMessages(_ messages: [TaskMessageDisplay]) -> [MessageGroup] {
    var groups: [MessageGroup] = []
    var i = 0
    while i < messages.count {
        let msg = messages[i]
        if msg.text.hasPrefix("### Permission needed"),
           i + 1 < messages.count,
           messages[i + 1].text.hasPrefix("### Permission resolved") {
            groups.append(.permissionPair(needed: msg, resolved: messages[i + 1]))
            i += 2
        } else {
            groups.append(.single(msg))
            i += 1
        }
    }
    return groups
}

/// Extract the first non-heading, non-empty line from a structured message.
private func messageBody(_ text: String) -> String {
    text.components(separatedBy: "\n")
        .first { !$0.isEmpty && !$0.hasPrefix("#") }
        ?? text
}

private struct PermissionGroupRow: View {
    let needed:   TaskMessageDisplay
    let resolved: TaskMessageDisplay

    private var decision: String { messageBody(resolved.text) }
    private var isPositive: Bool {
        let d = decision.lowercased()
        return d.contains("allow") || d == "yes"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Permission request bubble
                SimpleMarkdownView(text: needed.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Resolution pill — attached directly below, no timestamp gap
                HStack(spacing: 5) {
                    Image(systemName: isPositive ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(decision)
                        .fontWeight(.medium)
                }
                .font(.caption)
                .foregroundStyle(isPositive ? Color.green : Color.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((isPositive ? Color.green : Color.red).opacity(0.1))
                .clipShape(Capsule())

                // Single timestamp after resolution
                Text(simpleRelativeTime(resolved.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Message bubble

private struct MessageRow: View {
    let message: TaskMessageDisplay
    private var isUser: Bool { message.role == "user" }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(message.text.isEmpty ? "(empty)" : message.text)
                .font(.callout)
        } else {
            SimpleMarkdownView(text: message.text.isEmpty ? "(empty)" : message.text)
        }
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                bubbleContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.accentColor : Color.secondary.opacity(0.15))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(simpleRelativeTime(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct ArtifactRow: View {
    let artifact: TaskArtifactDisplay
    @State private var showPreview = false

    private var isMarkdown: Bool {
        artifact.mimeType == "text/markdown" || artifact.filename.hasSuffix(".md")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.filename)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(artifact.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let desc = artifact.description, !desc.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if let url = artifact.localURL {
                HStack(spacing: 6) {
                    if isMarkdown {
                        Button {
                            showPreview = true
                        } label: {
                            Image(systemName: "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Preview")
                    }
                    Button {
                        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                            .appendingPathComponent(artifact.filename)
                        try? FileManager.default.copyItem(at: url, to: dest)
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    } label: {
                        Label("Save", systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .sheet(isPresented: $showPreview) {
                    ArtifactPreviewSheet(artifact: artifact, url: url)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        if artifact.mimeType.hasPrefix("image/") { return "photo" }
        if artifact.mimeType.hasPrefix("text/") { return "doc.text" }
        if artifact.mimeType.contains("pdf") { return "doc.richtext" }
        if artifact.mimeType.contains("zip") || artifact.mimeType.contains("gzip") { return "archivebox" }
        return "doc"
    }
}

private struct ArtifactPreviewSheet: View {
    let artifact: TaskArtifactDisplay
    let url: URL
    @Environment(\.dismiss) private var dismiss

    private var content: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.filename)
                        .font(.headline)
                    Text(artifact.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            Divider()
            ScrollView {
                SimpleMarkdownView(text: content)
                    .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}

private struct MacAppActionCard: View {
    let group: LocalAppScriptGroup
    let onRespond: (String, String) -> Void
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    scriptIcon
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.script.name)
                            .font(.headline)
                        if let label = group.tileLabel {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(blockStatusColor(group.tileStatusColor))
                                    .frame(width: 7, height: 7)
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Text("\(group.inboxBlocks.count) pending")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let body = group.tileBody {
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.inboxBlocks) { block in
                    BlockPreviewView(block: block) { value in
                        onRespond(block.id, value)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.orange.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = effectiveIconImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else if let sf = group.script.icon {
            Image(systemName: sf)
                .font(.title3)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "app")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var effectiveIconImage: NSImage? {
        guard let img = group.script.iconImage else { return nil }
        guard let svg = group.script.svgString else { return img }
        return colorScheme == .dark ? (svgToWhite(svg) ?? img) : img
    }
}

private struct MacAppTileCard: View {
    let group: LocalAppScriptGroup
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                scriptIcon
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.script.name)
                        .font(.headline)
                    if let label = group.tileLabel {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(blockStatusColor(group.tileStatusColor))
                                .frame(width: 7, height: 7)
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let body = group.tileBody {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = effectiveIconImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else if let sf = group.script.icon {
            Image(systemName: sf)
                .font(.title3)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "app")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var effectiveIconImage: NSImage? {
        guard let img = group.script.iconImage else { return nil }
        guard let svg = group.script.svgString else { return img }
        return colorScheme == .dark ? (svgToWhite(svg) ?? img) : img
    }
}

private struct MacAppScriptScreen: View {
    let script: ManagedScript
    let liveBlocks: [LiveBlock]
    let onBack: () -> Void
    let onRespond: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                Text(script.name)
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            if liveBlocks.isEmpty {
                ContentUnavailableView(
                    "No Active Blocks",
                    systemImage: "rectangle.stack",
                    description: Text("This script has no active local blocks right now.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(liveBlocks) { block in
                            BlockPreviewView(block: block) { value in
                                onRespond(block.id, value)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Scripts tab (sidebar + detail)

private struct ScriptsTabView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptCatalogService.self) private var catalog
    @State private var selectedScriptID: String?
    @State private var showVault = false
    @State private var showCatalog = false
    @State private var installer = ScriptInstaller()
    @State private var isDropTargeted = false
    @State private var showSuccessBanner = false
    @State private var successMessage = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedScriptID) {
                if scriptManager.scripts.isEmpty {
                    Text("No scripts found in vault directory.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 4)
                } else {
                    let sorted = scriptManager.scripts.sorted { a, b in
                        if a.isSystem != b.isSystem { return !a.isSystem }
                        return a.name < b.name
                    }
                    ForEach(sorted) { script in
                        ScriptSidebarRow(script: script, scriptManager: scriptManager) {
                            selectedScriptID = nil
                        }
                        .tag(script.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .overlay {
                if isDropTargeted {
                    DropHighlightOverlay()
                        .padding(6)
                        .allowsHitTesting(false)
                }
                if installer.phase == .parsing {
                    Color.black.opacity(0.08)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading zip…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard installer.phase == .idle else { return false }
                providers.first?.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension.lowercased() == "zip"
                    else { return }
                    DispatchQueue.main.async {
                        installer.load(zipURL: url, existingScripts: scriptManager.scripts)
                    }
                }
                return true
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showSuccessBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(successMessage).font(.caption).foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear {
                if selectedScriptID == nil {
                    selectedScriptID = scriptManager.scripts.first(where: { !$0.isSystem })?.id
                        ?? scriptManager.scripts.first?.id
                }
            }
            .onChange(of: scriptManager.scripts.count) { _, count in
                // Auto-select first non-system script once scripts finish loading
                if selectedScriptID == nil && count > 0 {
                    selectedScriptID = scriptManager.scripts.first(where: { !$0.isSystem })?.id
                        ?? scriptManager.scripts.first?.id
                }
            }
            .onChange(of: selectedScriptID) { _, id in
                if id != nil { showVault = false }
            }
            .onChange(of: installer.phase) { _, phase in
                if phase == .done {
                    let count = installer.pending.count - installer.skipped.filter { $0.folderName != "" }.count
                    successMessage = installer.pending.count == 1
                        ? "Installed \(installer.pending.first?.name ?? "script")"
                        : "Installed \(installer.pending.count) scripts"
                    withAnimation { showSuccessBanner = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { showSuccessBanner = false }
                    }
                    _ = count // suppress unused warning
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let label = installer.installProgressLabel {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                        Divider()
                    }
                    Divider()
                    HStack(spacing: 0) {
                        // Vault button
                        Button {
                            showVault = true
                            showCatalog = false
                            selectedScriptID = nil
                        } label: {
                            Image(systemName: "lock")
                                .font(.body)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(showVault ? Color.accentColor.opacity(0.12) : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(showVault ? Color.accentColor : Color.secondary)
                        .quickTooltip("Local Script Vault")

                        Divider().frame(height: 20)

                        // Catalog button
                        Button {
                            showCatalog = true
                            showVault = false
                            selectedScriptID = nil
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "books.vertical")
                                    .font(.body)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(showCatalog ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .contentShape(Rectangle())
                                if !catalog.availableUpdates.isEmpty {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 7, height: 7)
                                        .offset(x: -6, y: 4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(showCatalog ? Color.accentColor : Color.secondary)
                        .quickTooltip("Catalog")

                        Divider().frame(height: 20)

                        // Upload button
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.zip]
                            panel.allowsMultipleSelection = false
                            panel.message = "Choose a script .zip to install"
                            if panel.runModal() == .OK, let url = panel.url {
                                installer.load(zipURL: url, existingScripts: scriptManager.scripts)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .quickTooltip("Add local script (.zip)")
                        .disabled(installer.phase != .idle)
                    }
                }
                .background(.bar)
            }
            .sheet(isPresented: $installer.showSheet) {
                ScriptInstallSheet(installer: installer, scriptManager: scriptManager,
                                   vaultURL: settings.vaultPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ask/scripts"))
            }
        } detail: {
            if showCatalog {
                ScriptCatalogView(installer: installer)
                    .environment(scriptManager)
            } else if showVault {
                ScriptsVaultView(installer: installer, scriptManager: scriptManager)
            } else if let id = selectedScriptID,
                      let script = scriptManager.scripts.first(where: { $0.id == id }) {
                ScriptDetailView(script: script, scriptManager: scriptManager,
                                 installer: installer) {
                    selectedScriptID = nil
                }
            } else {
                ContentUnavailableView(
                    "Select a Script",
                    systemImage: "terminal",
                    description: Text("Choose a script from the sidebar to view its active blocks.")
                )
            }
        }
        .onAppear {
            catalog.fetch(installedScripts: scriptManager.scripts)
        }
        .onChange(of: scriptManager.scripts.map(\.id)) { _, _ in
            catalog.recomputeUpdates(installedScripts: scriptManager.scripts)
        }
    }
}

private struct ScriptsVaultView: View {
    @Bindable var installer: ScriptInstaller
    let scriptManager: ScriptManager

    @Environment(AppSettings.self) private var settings
    @State private var vaultPathText: String = ""
    @State private var showVaultPicker = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    GroupBox {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.body)
                                .padding(.top, 1)
                            Text("We have provided sample scripts so you can see how this system works. Scripts are yours to make and control — we recommend vibe coding them, testing, and iterating until they do exactly what you need to be most productive.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(2)
                    }
                }

                Section {
                    Toggle("Include App Bundle Scripts", isOn: Binding(
                        get: { settings.usesBundledScripts },
                        set: { settings.usesBundledScripts = $0 }
                    ))

                    if settings.usesBundledScripts,
                       let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("Scripts").abbreviatingWithTildeInPath {
                        Text(bundlePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        TextField("Vault Path", text: $vaultPathText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyVaultPathText() }
                        Button { showVaultPicker = true } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Choose folder")
                    }
                } header: {
                    Text("Scripts Vault")
                } footer: {
                    Text("Vault scripts override bundle scripts with the same ID.")
                }
            }
            .formStyle(.grouped)

            // Upload drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                    )

                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                    Text("Drop a script .zip here to install")
                        .font(.callout)
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                    Button("Choose File…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.zip]
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose a script .zip to install"
                        if panel.runModal() == .OK, let url = panel.url {
                            installer.load(zipURL: url, existingScripts: scriptManager.scripts)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(installer.phase != .idle)
                }
                .padding(24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard installer.phase == .idle else { return false }
                providers.first?.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension.lowercased() == "zip"
                    else { return }
                    DispatchQueue.main.async {
                        installer.load(zipURL: url, existingScripts: scriptManager.scripts)
                    }
                }
                return true
            }
        }
        .navigationTitle("Scripts Vault")
        .onAppear {
            vaultPathText = settings.vaultPath?.abbreviatingWithTildeInPath ?? "~/.ask/scripts"
        }
        .fileImporter(isPresented: $showVaultPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                settings.vaultPath = url
                vaultPathText = url.abbreviatingWithTildeInPath
            }
        }
    }

    private func applyVaultPathText() {
        let expanded = vaultPathText.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + vaultPathText.dropFirst()
            : vaultPathText
        settings.vaultPath = URL(fileURLWithPath: expanded)
    }
}

// MARK: - Sidebar row

private struct ScriptSidebarRow: View {
    let script: ManagedScript
    let scriptManager: ScriptManager
    var onUninstall: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptCatalogService.self) private var catalog
    @State private var showUninstallConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            scriptIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(script.name)
                        .font(.body)
                        .foregroundStyle(script.isEnabled ? .primary : .secondary)
                    if !script.isSystem && settings.isPinned(script.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(catalog.availableUpdates[script.id] != nil ? Color.accentColor : statusColor)
                        .frame(width: 6, height: 6)
                    Text(catalog.availableUpdates[script.id] != nil ? "Update available" : statusLabel)
                        .font(.caption2)
                        .foregroundStyle(catalog.availableUpdates[script.id] != nil ? Color.accentColor : .secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { enabled in
                    if enabled { scriptManager.enableScript(id: script.id) }
                    else { scriptManager.disableScript(id: script.id) }
                }
            ))
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !script.isSystem {
                if settings.isPinned(script.id) {
                    Button {
                        settings.unpinScript(script.id)
                    } label: {
                        Label("Remove from Menu Bar", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        settings.pinScript(script.id)
                    } label: {
                        Label("Pin to Menu Bar", systemImage: "pin")
                    }
                    .disabled(settings.pinnedScripts.count >= AppSettings.maxPins)
                }

                if settings.pinnedScripts.count >= AppSettings.maxPins && !settings.isPinned(script.id) {
                    Text("Menu bar is full (\(AppSettings.maxPins) max)")
                        .foregroundStyle(.secondary)
                }
            }

            if !script.isBundled && !script.isSystem {
                Divider()
                Button(role: .destructive) {
                    showUninstallConfirm = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
        .alert("Remove \(script.name)?", isPresented: $showUninstallConfirm) {
            Button("Remove", role: .destructive) {
                onUninstall()
                scriptManager.uninstallScript(id: script.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop the script, clear its blocks from your iPhone, and move its files to the Trash.")
        }
    }

    private var statusLabel: String {
        script.status == .stopped && script.scriptType == "feed" ? "Scheduled" : script.status.label
    }

    private var statusColor: Color {
        switch script.status {
        case .running:              .green
        case .crashed:              .red
        case .missingDependencies:  .orange
        case .needsSetup:           .orange
        case .starting:             .yellow
        case .stopped:              Color(.tertiaryLabelColor)
        }
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = effectiveIcon {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.title3)
                .foregroundStyle(script.isEnabled ? .primary : .tertiary)
        }
    }

    private var effectiveIcon: NSImage? {
        guard colorScheme == .dark, let svg = script.svgString else { return script.iconImage }
        return svgToWhite(svg) ?? script.iconImage
    }
}

// MARK: - Card preview axes

private enum CardColorSchemePreview: String, CaseIterable {
    case light = "Light"
    case dark  = "Dark"
}

// MARK: - Script detail view

private struct ScriptDetailView: View {
    let script: ManagedScript
    let scriptManager: ScriptManager
    var installer: ScriptInstaller = ScriptInstaller()
    var onUninstall: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(ScriptCatalogService.self) private var catalog

    // Update state
    @State private var isDownloadingUpdate = false
    @State private var updateError: String?
    @State private var showUpdatePopover = false

    @State private var showUninstallConfirm = false
    @State private var cardFlipped = false
    @State private var previewBranded = true
    @State private var previewScheme: CardColorSchemePreview = .light
    @State private var showTools = false
    @State private var checkDrafts: [String: String] = [:]
    @State private var checkResults: [String: Bool?] = [:]
    @State private var checkOutput: [String: String] = [:]
    @State private var checkRunning: Set<String> = []
    @State private var savedDeps: Set<String> = []
    // Add-dependency form state
    @State private var addingDep = false
    @State private var newDepName = ""
    @State private var newDepCheck = ""
    // Brand override state
    @State private var brandColorPickerColor: Color = .white
    @State private var brandHex: String = ""
    @State private var brandColorSaved = false
    @State private var svgDropTargeted = false
    // Schedule editor state (feed scripts)
    @State private var scheduleHourDisplay: Int = 9   // 1–12
    @State private var scheduleIsPM: Bool = false
    @State private var scheduleMinute: Int = 0         // 0, 15, 30, 45
    @State private var scheduleDays: Set<Int> = []     // 0=Sun…6=Sat; empty = every day
    @State private var scheduleSaved = false
    // Setup state
    @State private var configValues: [String: String] = [:]    // key → value being edited
    @State private var configSaved: Set<String> = []           // keys that were just saved
    @State private var showSetupSheet = false
    @State private var setupOutputLines: [String] = []
    @State private var setupRunning = false
    @State private var setupNeedsTerminal = false

    private var liveBlocks: [LiveBlock] {
        Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scriptCard

                // Toggle bar — only for non-system scripts that declare tools
                if !script.tools.isEmpty && !script.isSystem {
                    Picker("", selection: $showTools) {
                        Text("Live Preview").tag(false)
                        Text("Methods").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if script.isSystem || showTools {
                    // System scripts always show their tools (no Live Preview).
                    // Non-system scripts show tools when the Methods tab is selected.
                    scriptToolsPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if script.status == .crashed, let error = script.lastError {
                        crashBanner(error)
                    }

                    // Two-column: live blocks on the left, script log on the right
                    HStack(alignment: .top, spacing: 16) {
                        // Left — live block preview
                        VStack(alignment: .leading, spacing: 8) {
                            if liveBlocks.isEmpty {
                                ContentUnavailableView(
                                    "No Active Blocks",
                                    systemImage: "rectangle.stack",
                                    description: Text("This script hasn't emitted any blocks yet.")
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                            } else {
                                ForEach(liveBlocks) { block in
                                    BlockPreviewView(block: block) { value in
                                        scriptManager.respondToBlock(
                                            scriptID: script.id,
                                            blockID: block.id,
                                            value: value
                                        )
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // Right — script log
                        stderrLogSection
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .navigationTitle(script.name)
    }

    // MARK: Script tools panel

    @ViewBuilder
    private var scriptToolsPanel: some View {
        if !script.tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tools")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            if let desc = tool.description {
                                Text(desc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }

                            if let params = tool.params, !params.isEmpty {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(params, id: \.name) { param in
                                        HStack(spacing: 4) {
                                            Text(param.name)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            if let type = param.type {
                                                Text(type)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            if param.required != true {
                                                Text("opt")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .italic()
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: Script card

    private var scriptCard: some View {
        Group {
            if cardFlipped {
                scriptCardBack
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
            } else {
                scriptCardFront
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .animation(.easeInOut(duration: 0.2), value: cardFlipped)
    }

    private var scriptCardFront: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + name/info
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .center, spacing: 6) {
                    scriptIcon
                        .frame(width: 48, height: 48)

                    if let update = catalog.availableUpdates[script.id] {
                        Button {
                            showUpdatePopover = true
                        } label: {
                            Text("Update")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
                            updatePopoverView(entry: update)
                        }
                    } else if script.needsSetup {
                        Button {
                            runSetup()
                        } label: {
                            Text("Setup")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(script.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(brandForegroundPrimary)

                        if let version = script.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(brandForegroundSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(brandForegroundSecondary.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        typeBadge
                    }

                    if let desc = script.description {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(brandForegroundSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(script.id)
                            .font(.caption)
                            .foregroundStyle(brandForegroundTertiary)
                            .fontDesign(.monospaced)

                        if let schedule = script.schedule {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(schedule)
                                    .font(.caption2)
                                    .fontDesign(.monospaced)
                            }
                            .foregroundStyle(brandForegroundTertiary)
                        }

                        Spacer()

                        statusBadge
                    }
                }
            }
            .padding(16)

            // Dependencies section
            if !script.requires.isEmpty {
                Divider()
                    .opacity(0.3)
                dependenciesSection
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 44) // leave room for bottom overlay controls
            }

            if script.hasSetup {
                Divider()
                    .opacity(0.3)
                setupInCard
                    .padding(.bottom, 54)  // leave room for the bottom overlay controls (Light/Dark/toggle)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(brandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .ifLet(brandColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                Button {
                    if let dir = script.manifestPath?.deletingLastPathComponent() {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.body)
                        .foregroundStyle(brandForegroundPrimary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if hasBrand {
                    Button {
                        withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                    } label: {
                        Image(systemName: "paintpalette")
                            .font(.body)
                            .foregroundStyle(brandForegroundPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Edit brand colors")
                }

                if script.scriptType == "feed" && script.schedule != nil {
                    Button {
                        withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                    } label: {
                        Image(systemName: "clock")
                            .font(.body)
                            .foregroundStyle(brandForegroundPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Edit schedule")
                }

                Button {
                    withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                } label: {
                    Image(systemName: "checklist")
                        .font(.body)
                        .foregroundStyle(brandForegroundPrimary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Edit dependency checks")
            }
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                // Theme buttons — explicit colours so they're always visible on any card background
                HStack(spacing: 3) {
                    ForEach(CardColorSchemePreview.allCases, id: \.self) { s in
                        Button {
                            previewScheme = s
                            if cardFlipped { cardFlipped = false }
                        } label: {
                            Text(s.rawValue)
                                .font(.caption)
                                .fontWeight(previewScheme == s ? .semibold : .regular)
                                .foregroundStyle(previewScheme == s ? Color.white : Color(white: 0.2))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(previewScheme == s ? Color.accentColor : Color(white: 0.88))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hasBrand {
                    Button {
                        previewBranded.toggle()
                        if cardFlipped { cardFlipped = false }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: previewBranded ? "checkmark.square.fill" : "square")
                            Text("Show brand")
                        }
                        .font(.caption)
                        .fontWeight(previewBranded ? .semibold : .regular)
                        .foregroundStyle(previewBranded ? Color.white : Color(white: 0.2))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(previewBranded ? Color.accentColor : Color(white: 0.88))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { enabled in
                    if enabled { scriptManager.enableScript(id: script.id) }
                    else { scriptManager.disableScript(id: script.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .padding(14)
        }
        .alert("Remove \(script.name)?", isPresented: $showUninstallConfirm) {
            Button("Remove", role: .destructive) {
                onUninstall()
                scriptManager.uninstallScript(id: script.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop the script, clear its blocks from your iPhone, and move its files to the Trash.")
        }
    }

    private var scriptCardBack: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Script Settings")
                    .font(.headline)
                    .foregroundStyle(brandForegroundPrimary)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.5)) { cardFlipped = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(brandForegroundSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Brand override editor
                    if hasBrand {
                        brandOverrideSection
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                    }

                    // Schedule editor (feed scripts only)
                    if script.scriptType == "feed" && script.schedule != nil {
                        scheduleEditorSection
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                    }

                    // Dependency checks header + add button
                    HStack {
                        Text("Dependency Checks")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(brandForegroundPrimary)
                        Spacer()
                        Button {
                            addingDep = true
                            newDepName = ""
                            newDepCheck = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Add dependency check")
                    }

                    // Inline add form
                    if addingDep {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name (e.g. node)", text: $newDepName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            TextField("Check command (exit 0 = installed)", text: $newDepCheck)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption2, design: .monospaced))

                            HStack {
                                Spacer()
                                Button("Cancel") { addingDep = false }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Add") { addDepCheck() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(newDepName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                              newDepCheck.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(8)
                        .background(brandForegroundSecondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if script.requires.isEmpty && !addingDep {
                        Text("No dependency checks defined.")
                            .font(.caption)
                            .foregroundStyle(brandForegroundTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                    // Run Setup — always visible here; tinted orange when setup is needed
                    if script.setupScript != nil {
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                        Button {
                            runSetup()
                        } label: {
                            Label("Run Setup", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(script.needsSetup ? .orange : .accentColor)
                        .sheet(isPresented: $showSetupSheet) {
                            SetupOutputSheet(
                                scriptName: script.name,
                                lines: $setupOutputLines,
                                running: $setupRunning
                            )
                        }
                    }

                    ForEach(script.requires, id: \.id) { dep in
                        VStack(alignment: .leading, spacing: 6) {
                            // Row: status icon + name + Run + Save
                            HStack(spacing: 6) {
                                Group {
                                    if checkRunning.contains(dep.id) {
                                        ProgressView().controlSize(.mini)
                                    } else if let result = checkResults[dep.id] {
                                        Image(systemName: result == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(result == true ? Color.green : Color.red)
                                    } else {
                                        Image(systemName: "circle.dotted")
                                            .foregroundStyle(brandForegroundTertiary)
                                    }
                                }
                                .font(.caption)
                                .frame(width: 14)

                                Text(dep.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(brandForegroundPrimary)

                                Toggle("", isOn: Binding(
                                    get: { !settings.isDepCheckSkipped(scriptID: script.id, depID: dep.id) },
                                    set: { settings.setDepCheckSkipped(scriptID: script.id, depID: dep.id, skipped: !$0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Enable dependency check")

                                Spacer()

                                Button {
                                    Task { await runDepCheck(dep) }
                                } label: {
                                    if checkRunning.contains(dep.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Text("Run")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(checkRunning.contains(dep.id))

                                Button {
                                    saveDepCheck(dep)
                                } label: {
                                    Text(savedDeps.contains(dep.id) ? "Saved ✓" : "Save")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled((checkDrafts[dep.id] ?? dep.check) == dep.check || savedDeps.contains(dep.id))

                                Button {
                                    removeDepCheck(dep)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.borderless)
                                .help("Remove dependency check")
                            }

                            // Editable check command
                            TextEditor(text: Binding(
                                get: { checkDrafts[dep.id] ?? dep.check },
                                set: { checkDrafts[dep.id] = $0 }
                            ))
                            .font(.system(.caption2, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(brandForegroundSecondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(minHeight: 44, maxHeight: 80)

                            // Output from last run
                            if let output = checkOutput[dep.id], !output.isEmpty {
                                let passed = checkResults[dep.id] == true
                                Text(output)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(passed ? Color.green : Color.red)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(brandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Initialise brand color state
            initBrandColor()

            // Initialise schedule state from manifest cron expression
            if let cron = script.schedule {
                let parts = cron.split(separator: " ")
                if parts.count == 5,
                   let min = Int(parts[0]),
                   let hr  = Int(parts[1]) {
                    scheduleMinute = [0, 15, 30, 45].contains(min) ? min : 0
                    scheduleIsPM = hr >= 12
                    scheduleHourDisplay = { let h = hr % 12; return h == 0 ? 12 : h }()
                    let dayStr = String(parts[4])
                    if dayStr == "*" {
                        scheduleDays = []
                    } else {
                        var days = Set<Int>()
                        for part in dayStr.split(separator: ",") {
                            let s = String(part)
                            if s.contains("-"), let dash = s.firstIndex(of: "-") {
                                let after = s.index(after: dash)
                                if let start = Int(s[s.startIndex..<dash]),
                                   let end   = Int(s[after...]) {
                                    for d in start...end { days.insert(d) }
                                }
                            } else if let d = Int(s) {
                                days.insert(d)
                            }
                        }
                        scheduleDays = days
                    }
                }
            }
            // Initialise drafts and run checks when back is shown
            for dep in script.requires {
                if checkDrafts[dep.id] == nil { checkDrafts[dep.id] = dep.check }
            }
            Task {
                for dep in script.requires { await runDepCheck(dep) }
            }
        }
        .ifLet(brandColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    private func runDepCheck(_ dep: ScriptDependency) async {
        let command = checkDrafts[dep.id] ?? dep.check

        // Strip output suppression so we can capture and display what the check found
        let displayCommand = command
            .replacingOccurrences(of: " >/dev/null 2>&1", with: "")
            .replacingOccurrences(of: " 2>/dev/null", with: "")
            .replacingOccurrences(of: " >/dev/null", with: "")

        checkRunning.insert(dep.id)
        checkResults[dep.id] = nil
        checkOutput[dep.id] = ""

        let (passed, output) = await Task.detached(priority: .userInitiated) {
            // Run original command for authoritative exit code
            let checkProc = Process()
            checkProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            checkProc.arguments = ["-l", "-c", command]
            checkProc.standardOutput = Pipe()
            checkProc.standardError = Pipe()
            try? checkProc.run()
            checkProc.waitUntilExit()
            let passed = checkProc.terminationStatus == 0

            // Run display version to capture output
            let outPipe = Pipe()
            let errPipe = Pipe()
            let displayProc = Process()
            displayProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            displayProc.arguments = ["-l", "-c", displayCommand]
            displayProc.standardOutput = outPipe
            displayProc.standardError = errPipe
            try? displayProc.run()
            displayProc.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
            return (passed, combined)
        }.value

        checkRunning.remove(dep.id)
        checkResults[dep.id] = passed
        checkOutput[dep.id] = output
    }

    private func saveDepCheck(_ dep: ScriptDependency) {
        guard let manifestPath = script.manifestPath,
              let draft = checkDrafts[dep.id],
              draft != dep.check,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var requires = json["requires"] as? [[String: Any]] else { return }

        guard let idx = requires.firstIndex(where: { $0["id"] as? String == dep.id }) else { return }
        requires[idx]["check"] = draft
        json["requires"] = requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        savedDeps.insert(dep.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            savedDeps.remove(dep.id)
        }
    }

    private func addDepCheck() {
        let name = newDepName.trimmingCharacters(in: .whitespaces)
        let check = newDepCheck.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !check.isEmpty,
              let manifestPath = script.manifestPath,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let newEntry: [String: Any] = ["id": id, "name": name, "check": check]
        var requires = (json["requires"] as? [[String: Any]]) ?? []
        requires.append(newEntry)
        json["requires"] = requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        addingDep = false
        newDepName = ""
        newDepCheck = ""
    }

    private func removeDepCheck(_ dep: ScriptDependency) {
        guard let manifestPath = script.manifestPath,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var requires = json["requires"] as? [[String: Any]] else { return }

        requires.removeAll { $0["id"] as? String == dep.id }
        json["requires"] = requires.isEmpty ? nil : requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        checkDrafts.removeValue(forKey: dep.id)
        checkResults.removeValue(forKey: dep.id)
        checkOutput.removeValue(forKey: dep.id)
    }

    private func saveSchedule() {
        guard let manifestURL = script.manifestPath else { return }
        let hr24: Int = {
            if scheduleIsPM { return scheduleHourDisplay == 12 ? 12 : scheduleHourDisplay + 12 }
            else             { return scheduleHourDisplay == 12 ? 0  : scheduleHourDisplay }
        }()
        let dayStr = scheduleDays.isEmpty ? "*" : scheduleDays.sorted().map(String.init).joined(separator: ",")
        let cron = "\(scheduleMinute) \(hr24) * * \(dayStr)"

        guard let data = try? Data(contentsOf: manifestURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["schedule"] = cron
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestURL)
        }
        scheduleSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { scheduleSaved = false }
    }

    // MARK: Schedule editor (feed scripts)

    private var scheduleEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundPrimary)

            // Time of day
            HStack(spacing: 8) {
                Text("Time")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)
                    .frame(width: 36, alignment: .leading)

                Picker("", selection: $scheduleHourDisplay) {
                    ForEach(1...12, id: \.self) { h in Text("\(h)").tag(h) }
                }
                .labelsHidden()
                .frame(width: 56)
                .onChange(of: scheduleHourDisplay) { _, _ in scheduleSaved = false }

                Text(":")
                    .foregroundStyle(brandForegroundSecondary)

                Picker("", selection: $scheduleMinute) {
                    Text("00").tag(0)
                    Text("15").tag(15)
                    Text("30").tag(30)
                    Text("45").tag(45)
                }
                .labelsHidden()
                .frame(width: 56)
                .onChange(of: scheduleMinute) { _, _ in scheduleSaved = false }

                Picker("", selection: $scheduleIsPM) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 80)
                .onChange(of: scheduleIsPM) { _, _ in scheduleSaved = false }
            }

            // Days of week
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Days")
                        .font(.caption)
                        .foregroundStyle(brandForegroundSecondary)
                        .frame(width: 36, alignment: .leading)

                    HStack(spacing: 4) {
                        let dayLabels = ["S","M","T","W","T","F","S"]
                        ForEach(0..<7, id: \.self) { day in
                            let selected = scheduleDays.contains(day)
                            Button {
                                if selected { scheduleDays.remove(day) }
                                else        { scheduleDays.insert(day) }
                                scheduleSaved = false
                            } label: {
                                Text(dayLabels[day])
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(width: 26, height: 26)
                                    .background(selected ? Color.accentColor : brandForegroundSecondary.opacity(0.12))
                                    .foregroundStyle(selected ? Color.white : brandForegroundPrimary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Spacer().frame(width: 40)
                    Text(scheduleSummary)
                        .font(.caption2)
                        .foregroundStyle(brandForegroundTertiary)
                }
            }

            // Save
            HStack {
                if !scheduleDays.isEmpty {
                    Button("Every day") {
                        scheduleDays = []
                        scheduleSaved = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button { saveSchedule() } label: {
                    Text(scheduleSaved ? "Saved ✓" : "Save Schedule")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(scheduleSaved)
            }
        }
    }

    private var scheduleSummary: String {
        let ampm = scheduleIsPM ? "PM" : "AM"
        let timeStr = String(format: "%d:%02d %@", scheduleHourDisplay, scheduleMinute, ampm)
        if scheduleDays.isEmpty { return "Every day at \(timeStr)" }
        let names = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        let sorted = scheduleDays.sorted()
        if sorted == [1,2,3,4,5] { return "Weekdays at \(timeStr)" }
        if sorted == [0,6]       { return "Weekends at \(timeStr)" }
        return sorted.map { names[$0] }.joined(separator: ", ") + " at \(timeStr)"
    }

    // MARK: Brand override editor

    private func initBrandColor() {
        if let hex = settings.brandColorOverride(for: script.id), let c = Color(hex: hex) {
            brandColorPickerColor = c
            brandHex = hex
        }
        // no override → leave blank (hex = "", picker = .white defaults)
    }

    private var brandHexIsValid: Bool {
        let h = brandHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return h.count == 6 && UInt64(h, radix: 16) != nil
    }

    private func saveBrandColor() {
        guard brandHexIsValid else { return }
        let hex = brandHex.hasPrefix("#") ? brandHex : "#\(brandHex)"
        settings.setBrandColorOverride(scriptID: script.id, hex: hex)
        brandColorSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { brandColorSaved = false }
    }

    @discardableResult
    private func handleIconDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "svg",
                  let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.settings.setSVGOverride(scriptID: self.script.id, svg: svg) }
        }
        return true
    }

    private func handleIconPaste() {
        guard let str = NSPasteboard.general.string(forType: .string),
              str.contains("<svg") else { return }
        settings.setSVGOverride(scriptID: script.id, svg: str)
    }

    @ViewBuilder
    private var brandOverrideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brand")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundPrimary)

            // Background color
            VStack(alignment: .leading, spacing: 6) {
                Text("Background Color")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)

                HStack(spacing: 8) {
                    ColorPicker("", selection: $brandColorPickerColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: brandColorPickerColor) { _, newColor in
                            // Picker → hex (one direction only to avoid circular updates)
                            brandHex = newColor.hexString
                            brandColorSaved = false
                        }

                    TextField("#RRGGBB", text: $brandHex)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .onChange(of: brandHex) { _, _ in
                            brandColorSaved = false
                        }
                        .onSubmit {
                            // Hex → picker only on submit to avoid circular onChange loop
                            if let c = Color(hex: brandHex) { brandColorPickerColor = c }
                        }

                    Spacer()

                    Button { saveBrandColor() } label: {
                        Text(brandColorSaved ? "Saved ✓" : "Save")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(brandColorSaved || !brandHexIsValid)
                }
            }

            // SVG icon override
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon (SVG)")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)

                HStack(spacing: 10) {
                    // Drop zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                svgDropTargeted ? Color.accentColor : brandForegroundSecondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5])
                            )
                            .frame(width: 48, height: 48)

                        if let svgStr = settings.svgOverride(for: script.id),
                           let data = svgStr.data(using: .utf8),
                           let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title3)
                                .foregroundStyle(brandForegroundTertiary)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $svgDropTargeted) { providers in
                        handleIconDrop(providers)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Button("Paste SVG") { handleIconPaste() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                        if settings.svgOverride(for: script.id) != nil {
                            Button("Remove") { settings.setSVGOverride(scriptID: script.id, svg: nil) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Drop .svg file here")
                                .font(.caption2)
                                .foregroundStyle(brandForegroundTertiary)
                        }
                    }
                }
            }

            // Reset all brand overrides
            let hasAnyOverride = settings.brandColorOverride(for: script.id) != nil
                              || settings.svgOverride(for: script.id) != nil
            if hasAnyOverride {
                HStack {
                    Spacer()
                    Button("Reset Brand") {
                        settings.setBrandColorOverride(scriptID: script.id, hex: nil)
                        settings.setSVGOverride(scriptID: script.id, svg: nil)
                        initBrandColor()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func manifestRow(_ key: String, value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(brandForegroundTertiary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontDesign(monospaced ? .monospaced : .default)
                .foregroundStyle(brandForegroundSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            if copyable {
                CopyButton(value: value)
            }
        }
    }

    // MARK: Badges

    @ViewBuilder
    private var typeBadge: some View {
        let label = script.scriptType == "feed" ? "Feed"
                  : script.scriptType == "system" ? "System"
                  : "Tile"
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(brandAccent ?? brandForegroundSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((brandAccent ?? brandForegroundSecondary).opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(cardStatusLabel)
                .font(.caption)
                .foregroundStyle(brandForegroundSecondary)
        }
    }

    private var cardStatusLabel: String {
        script.status == .stopped && script.scriptType == "feed" ? "Scheduled" : script.status.label
    }

    private var statusColor: Color {
        switch script.status {
        case .running:              .green
        case .crashed:              .red
        case .missingDependencies:  .orange
        case .needsSetup:           .orange
        case .starting:             .yellow
        case .stopped:              .secondary
        }
    }

    // MARK: - Setup

    private var setupInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if script.setupCheckRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        scriptManager.runSetupCheck(id: script.id)
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Config form
            if !script.configItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(script.configItems) { item in
                        configRow(item)
                    }
                }
            }

            // Check results
            if !script.setupChecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.setupChecks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(check.ok ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.label)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                if let msg = check.message {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if script.setupCheckRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        scriptManager.runSetupCheck(id: script.id)
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Config form — required secret/string fields
            if !script.configItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(script.configItems) { item in
                        configRow(item)
                    }
                }
            }

            // Check results
            if !script.setupChecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.setupChecks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(check.ok ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.label)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                if let msg = check.message {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            // Run Setup button
            if script.setupScript != nil {
                let failedChecks = script.setupChecks.filter { !$0.ok }
                let needsTerminal = failedChecks.contains { $0.needsTerminal == true }

                Button {
                    if needsTerminal {
                        scriptManager.setupInstallInTerminal(id: script.id)
                    } else {
                        setupOutputLines = []
                        showSetupSheet = true
                        Task {
                            setupRunning = true
                            for await line in scriptManager.setupInstallStream(id: script.id) {
                                setupOutputLines.append(line)
                            }
                            setupRunning = false
                            scriptManager.runSetupCheck(id: script.id)
                        }
                    }
                } label: {
                    Label(needsTerminal ? "Open Terminal to Setup" : "Run Setup",
                          systemImage: needsTerminal ? "terminal" : "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(script.needsSetup ? .orange : .accentColor)
                .sheet(isPresented: $showSetupSheet) {
                    SetupOutputSheet(
                        scriptName: script.name,
                        lines: $setupOutputLines,
                        running: $setupRunning
                    )
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(script.needsSetup ? Color.orange.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func configRow(_ item: ScriptConfigItem) -> some View {
        let binding = Binding<String>(
            get: { configValues[item.key] ?? KeychainService.shared.get(scriptID: script.id, key: item.key) ?? "" },
            set: { configValues[item.key] = $0 }
        )
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.label)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(brandForegroundPrimary)
                    if item.required == true {
                        Text("required")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let desc = item.description {
                    Text(desc).font(.caption2).foregroundStyle(brandForegroundTertiary)
                }
            }
            Spacer()
            if item.type == "secret" {
                SecureField("••••••••", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            } else {
                TextField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if let helpURL = item.helpURL, let url = URL(string: helpURL) {
                Link(destination: url) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                let val = configValues[item.key] ?? ""
                guard !val.isEmpty else { return }
                try? KeychainService.shared.set(scriptID: script.id, key: item.key, value: val)
                configSaved.insert(item.key)
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    configSaved.remove(item.key)
                }
                scriptManager.runSetupCheck(id: script.id)
            } label: {
                Image(systemName: configSaved.contains(item.key) ? "checkmark" : "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(configSaved.contains(item.key) ? .green : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled((configValues[item.key] ?? "").isEmpty)
        }
    }

    // MARK: Dependencies

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dependencies")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(script.requires, id: \.id) { dep in
                    let isMissing = script.missingDeps.contains { $0.id == dep.id }
                    HStack(spacing: 6) {
                        Image(systemName: isMissing ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isMissing ? .red : .green)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(dep.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(brandForegroundPrimary)
                                .lineLimit(1)
                            if isMissing, let install = dep.install {
                                Text(install)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(brandForegroundTertiary)
                                    .lineLimit(1)
                            } else {
                                Text(isMissing ? "Missing" : "Installed")
                                    .font(.caption2)
                                    .foregroundStyle(brandForegroundTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Retry button — shown once if any are missing
            if script.missingDeps.contains(where: { _ in true }) {
                Button("Retry") {
                    scriptManager.retryDependencies(id: script.id)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    // MARK: Brand colors — raw (script's actual brand)

    @Environment(\.colorScheme) private var colorScheme

    /// The color scheme the card will render in, accounting for preview selection.
    private var effectiveColorScheme: ColorScheme {
        previewScheme == .dark ? .dark : .light
    }

    private var scriptBrandColorScheme: ColorScheme? {
        switch script.id {
        case "github": .dark
        default: nil
        }
    }

    private var hasBrand: Bool { true }

    // MARK: Brand colors — effective (respects preview toggles)

    /// Background actually applied to the card.
    private var brandBackground: Color {
        if !previewBranded {
            return effectiveColorScheme == .dark ? Color(white: 0.15) : Color(white: 0.96)
        }
        // User override
        if let hex = settings.brandColorOverride(for: script.id), let c = Color(hex: hex) {
            return c
        }
        // Built-in script brands
        switch script.id {
        case "claudecode-controller":
            return effectiveColorScheme == .dark
                ? Color(red: 0.15, green: 0.13, blue: 0.11)
                : Color(red: 250/255, green: 249/255, blue: 245/255)
        case "github":
            return effectiveColorScheme == .light
                ? Color(red: 250/255, green: 250/255, blue: 250/255)
                : Color(red: 0x24/255, green: 0x29/255, blue: 0x2F/255)
        default:
            return effectiveColorScheme == .dark ? Color(white: 0.15) : Color(white: 0.96)
        }
    }

    /// Color scheme environment applied to the card.
    private var brandColorScheme: ColorScheme? {
        previewScheme == .dark ? .dark : .light
    }

    /// Whether the card is rendering on a dark background (drives icon SVG recolouring).
    private var cardIsOnDark: Bool {
        previewScheme == .dark
    }

    private var brandAccent: Color? {
        guard previewBranded else { return nil }
        switch script.id {
        case "claudecode-controller": return Color(red: 202/255, green: 124/255, blue: 94/255)
        case "github":               return Color(red: 0x09/255, green: 0x69/255, blue: 0xDA/255)
        default:                     return nil
        }
    }

    private var brandForegroundPrimary: Color {
        cardIsOnDark ? .white : Color(white: 0.0)
    }

    private var brandForegroundSecondary: Color {
        cardIsOnDark ? Color(white: 1.0, opacity: 0.65) : Color(white: 0.0, opacity: 0.55)
    }

    private var brandForegroundTertiary: Color {
        cardIsOnDark ? Color(white: 1.0, opacity: 0.4) : Color(white: 0.0, opacity: 0.35)
    }

    // MARK: Icon

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = cardIcon {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.largeTitle)
                .foregroundStyle(script.isEnabled ? brandForegroundPrimary : brandForegroundTertiary)
        }
    }

    /// Icon image adapted for the card's effective color scheme.
    /// Dark background cards get SVG strokes recoloured to white.
    private var cardIcon: NSImage? {
        // SVG override takes priority
        let svgSource = settings.svgOverride(for: script.id) ?? script.svgString
        if let svg = svgSource {
            if cardIsOnDark { return svgToWhite(svg) ?? script.iconImage }
            return NSImage(data: svg.data(using: .utf8) ?? Data()) ?? script.iconImage
        }
        return script.iconImage
    }

    // MARK: Crash banner

    @ViewBuilder
    private var stderrLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Script Log", systemImage: "terminal")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(script.stderrLog.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(script.stderrLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(nil)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 200)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Update popover

    @ViewBuilder
    private func updatePopoverView(entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Update Available")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(script.version ?? "?") → \(entry.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let log = entry.changelog, !log.isEmpty {
                Text(log)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = updateError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showUpdatePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button {
                    showUpdatePopover = false
                    installUpdate(entry: entry)
                } label: {
                    if isDownloadingUpdate {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Downloading…")
                        }
                    } else {
                        Text("Install Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isDownloadingUpdate || installer.phase != .idle)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Setup helper

    private func runSetup() {
        let failedChecks = script.setupChecks.filter { !$0.ok }
        let needsTerminal = failedChecks.contains { $0.needsTerminal == true }
        if needsTerminal {
            scriptManager.setupInstallInTerminal(id: script.id)
        } else {
            setupOutputLines = []
            showSetupSheet = true
            Task {
                setupRunning = true
                for await line in scriptManager.setupInstallStream(id: script.id) {
                    setupOutputLines.append(line)
                }
                setupRunning = false
                scriptManager.runSetupCheck(id: script.id)
            }
        }
    }

    private func installUpdate(entry: CatalogEntry) {
        isDownloadingUpdate = true
        updateError = nil
        Task {
            do {
                let zipURL = try await catalog.downloadZip(for: entry)
                await MainActor.run {
                    isDownloadingUpdate = false
                    installer.load(zipURL: zipURL, existingScripts: scriptManager.scripts)
                }
            } catch {
                await MainActor.run {
                    isDownloadingUpdate = false
                    updateError = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func crashBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Script crashed")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Script catalog browser

private struct ScriptCatalogView: View {
    @Bindable var installer: ScriptInstaller
    @Environment(ScriptCatalogService.self) private var catalog
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(AppSettings.self) private var settings

    @State private var searchText = ""
    @State private var downloadingID: String?
    @State private var downloadErrors: [String: String] = [:]
    @State private var showInstalled = false

    private var filteredEntries: [CatalogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog.allEntries }
        return catalog.allEntries.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.body)
                TextField("Search scripts…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if catalog.isFetching && catalog.allEntries.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading catalog…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.allEntries.isEmpty {
                ContentUnavailableView(
                    "Catalog Unavailable",
                    systemImage: "wifi.slash",
                    description: Text("Could not load the script catalog.\nCheck your internet connection and try again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        // Available: scripts with updates or not yet installed
                        let available = filteredEntries.filter { entry in
                            catalog.availableUpdates[entry.id] != nil ||
                            !scriptManager.scripts.contains(where: { $0.id == entry.id })
                        }
                        let installed = filteredEntries.filter { entry in
                            catalog.availableUpdates[entry.id] == nil &&
                            scriptManager.scripts.contains(where: { $0.id == entry.id })
                        }

                        ForEach(available) { entry in
                            let installedScript = scriptManager.scripts.first(where: { $0.id == entry.id })
                            CatalogEntryRow(
                                entry: entry,
                                installer: installer,
                                isInstalled: installedScript != nil,
                                hasUpdate: catalog.availableUpdates[entry.id] != nil,
                                isDownloading: downloadingID == entry.id,
                                downloadError: downloadErrors[entry.id],
                                installedScript: installedScript
                            ) {
                                startInstall(entry: entry)
                            }
                            Divider().padding(.leading, 52)
                        }

                        // Local scripts: in vault but not in the catalog at all
                        let localScripts = scriptManager.scripts.filter { s in
                            !catalog.allEntries.contains(where: { $0.id == s.id })
                        }

                        let totalInstalled = installed.count + localScripts.count
                        if totalInstalled > 0 {
                            DisclosureGroup(isExpanded: $showInstalled) {
                                ForEach(installed) { entry in
                                    let installedScript = scriptManager.scripts.first(where: { $0.id == entry.id })
                                    CatalogEntryRow(
                                        entry: entry,
                                        installer: installer,
                                        isInstalled: true,
                                        hasUpdate: false,
                                        isDownloading: false,
                                        downloadError: nil,
                                        installedScript: installedScript,
                                        isLocal: false
                                    ) {
                                        startInstall(entry: entry)
                                    }
                                    Divider().padding(.leading, 52)
                                }
                                ForEach(localScripts) { script in
                                    LocalScriptRow(script: script)
                                    Divider().padding(.leading, 52)
                                }
                            } label: {
                                HStack {
                                    Text("Installed")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    Text("(\(totalInstalled))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Browse Scripts")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    catalog.fetch(installedScripts: scriptManager.scripts, force: true)
                } label: {
                    if catalog.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(catalog.isFetching)
                .help("Refresh catalog")
            }
        }
        .sheet(isPresented: $installer.showSheet) {
            ScriptInstallSheet(
                installer: installer,
                scriptManager: scriptManager,
                vaultURL: settings.vaultPath ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".ask/scripts")
            )
        }
    }

    private func startInstall(entry: CatalogEntry) {
        downloadingID = entry.id
        downloadErrors.removeValue(forKey: entry.id)
        Task {
            do {
                let zipURL = try await catalog.downloadZip(for: entry)
                await MainActor.run {
                    downloadingID = nil
                    installer.load(zipURL: zipURL, existingScripts: scriptManager.scripts)
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    downloadErrors[entry.id] = error.localizedDescription
                }
            }
        }
    }
}

private struct LocalScriptRow: View {
    let script: ManagedScript

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = script.iconImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .grayscale(0.6)
                        .opacity(0.5)
                } else {
                    Image(systemName: script.icon ?? "shippingbox")
                        .font(.title2)
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(script.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .opacity(0.4)
                if let desc = script.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .opacity(0.4)
                }
            }

            Spacer()

            Text("Local")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct CatalogEntryRow: View {
    let entry: CatalogEntry
    let installer: ScriptInstaller
    let isInstalled: Bool
    let hasUpdate: Bool
    let isDownloading: Bool
    let downloadError: String?
    let installedScript: ManagedScript?
    var isLocal: Bool = false
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Group {
                if let img = installedScript?.iconImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .grayscale(isInstalled && !hasUpdate ? 0.6 : 0)
                        .opacity(isInstalled && !hasUpdate ? 0.5 : 1)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(isInstalled && !hasUpdate ? Color.secondary.opacity(0.4) : .secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.secondary.opacity(isInstalled && !hasUpdate ? 0.06 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .opacity(isInstalled && !hasUpdate ? 0.4 : 1)
                    typeBadge
                }
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .opacity(isInstalled && !hasUpdate ? 0.4 : 1)
                if let err = downloadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action button
            Group {
                if isDownloading {
                    ProgressView().controlSize(.small)
                        .frame(width: 64)
                } else if hasUpdate {
                    Button("Update", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if isInstalled {
                    Text("Installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Button("Install", action: onInstall)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(installer.phase != .idle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var typeBadge: some View {
        let (label, color): (String, Color) = {
            switch entry.type {
            case "feed":   return ("Feed",   .purple)
            case "system": return ("System", .gray)
            default:       return ("Tile",   .blue)
            }
        }()
        return Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Feed filter

private enum FeedFilter: Hashable {
    case all
    case kind(HistoryEventKind)
    case source(String)
}

// MARK: - Feed view

private struct MacFeedView: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var feedFilter: FeedFilter? = .all
    @State private var selectedEvent: HistoryEvent?
    @State private var showVerbose = true

    // Cached derived state — recomputed only when events change, not every render
    @State private var filteredEvents: [HistoryEvent] = []
    @State private var kindCounts: [HistoryEventKind: Int] = [:]
    @State private var sourceStats: [SourceStat] = []

    private struct SourceStat: Identifiable {
        let name: String; let count: Int; let latest: Date?
        let eventsPerMinute: Double?
        var id: String { name }
    }

    private func recompute(events: [HistoryEvent], filter: FeedFilter?) {
        // Single pass: kind counts + per-source count, earliest, latest
        var kc: [HistoryEventKind: Int] = [:]
        var sc: [String: (count: Int, earliest: Date, latest: Date)] = [:]
        for event in events {
            kc[event.kind, default: 0] += 1
            if let prev = sc[event.source] {
                sc[event.source] = (prev.count + 1, min(prev.earliest, event.timestamp), max(prev.latest, event.timestamp))
            } else {
                sc[event.source] = (1, event.timestamp, event.timestamp)
            }
        }
        kindCounts = kc
        sourceStats = sc.map { name, val in
            let spanMinutes = val.latest.timeIntervalSince(val.earliest) / 60.0
            let rate: Double? = spanMinutes >= 0.5 ? Double(val.count) / spanMinutes : nil
            return SourceStat(name: name, count: val.count, latest: val.latest, eventsPerMinute: rate)
        }.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }

        // Filtered events
        filteredEvents = switch filter {
        case .all, nil:      events
        case .kind(let k):   events.filter { $0.kind == k }
        case .source(let s): events.filter { $0.source == s }
        }
    }

    var body: some View {
        NavigationSplitView {
            feedSidebar
        } detail: {
            feedDetail
        }
        .navigationTitle("Feed")
        .sheet(item: $selectedEvent) { event in
            FeedEventDetailSheet(event: event)
        }
        .task { recompute(events: history.events, filter: feedFilter) }
        .onChange(of: history.events.count) { recompute(events: history.events, filter: feedFilter) }
        .onChange(of: feedFilter) { recompute(events: history.events, filter: feedFilter) }
    }

    // MARK: Sidebar

    private var feedSidebar: some View {
        List(selection: $feedFilter) {
            Section {
                HStack {
                    Label("All Activity", systemImage: "scroll")
                    Spacer()
                    Text("\(history.events.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(FeedFilter.all)
            }

            Section("By Type") {
                kindRow(kind: .scriptCrashed,      label: "Crashes",      icon: "exclamationmark.triangle.fill")
                kindRow(kind: .blockResponse,      label: "Responses",    icon: "hand.point.up.left")
                kindRow(kind: .scriptStarted,      label: "Starts",       icon: "arrow.clockwise.circle.fill")
                kindRow(kind: .scriptEnabled,      label: "Enabled",      icon: "play.circle.fill")
                kindRow(kind: .scriptDisabled,     label: "Disabled",     icon: "stop.circle.fill")
                kindRow(kind: .dependencyMissing,  label: "Dep Missing",  icon: "wrench.and.screwdriver.fill")
                kindRow(kind: .blockEmitted,       label: "Emitted",      icon: "icloud.and.arrow.up")
            }

            if !sourceStats.isEmpty {
                Section("By Script") {
                    ForEach(sourceStats) { stat in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.name).font(.subheadline)
                                if let rate = stat.eventsPerMinute {
                                    Text(String(format: "%.1f/min", rate))
                                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                } else if let date = stat.latest {
                                    Text(date, style: .relative)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text("\(stat.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(FeedFilter.source(stat.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    @ViewBuilder
    private func kindRow(kind: HistoryEventKind, label: String, icon: String) -> some View {
        let n = kindCounts[kind, default: 0]
        if n > 0 {
            HStack {
                Label(label, systemImage: icon).foregroundStyle(kind.color)
                Spacer()
                Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .tag(FeedFilter.kind(kind))
        }
    }

    // MARK: Event list

    @State private var sortOrder = [KeyPathComparator(\HistoryEvent.timestamp, order: .reverse)]
    @State private var tableSelection: Set<HistoryEvent.ID> = []

    private var feedDetail: some View {
        Group {
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "scroll",
                    description: Text("Script interactions and lifecycle events will appear here.")
                )
            } else if showVerbose {
                logTable
            } else {
                compactList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button { showVerbose.toggle() } label: {
                        Label(
                            showVerbose ? "Compact" : "Table",
                            systemImage: showVerbose ? "list.bullet" : "tablecells"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showVerbose ? Color.accentColor : Color.secondary)
                    .help(showVerbose ? "Switch to compact view" : "Switch to table view")
                    Button {
                        history.purge()
                    } label: {
                        Label("Purge Log", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.secondary)
                    .help("Delete all log entries")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    // Compact list (friendly rows)
    private var compactList: some View {
        List {
            ForEach(filteredEvents) { event in
                FeedEventRow(event: event)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEvent = event }
                    .listRowBackground(
                        event.kind == .scriptCrashed ? Color.red.opacity(0.04) : Color.clear
                    )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // Verbose table
    private var logTable: some View {
        Table(filteredEvents, selection: $tableSelection, sortOrder: $sortOrder) {
            // Timestamp
            TableColumn("Time", value: \.timestamp) { event in
                Text(event.timestamp.formatted(.dateTime.month(.twoDigits).day().hour().minute().second()))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)

            // Kind badge
            TableColumn("Type") { event in
                Text(event.kind.shortLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(event.kind.color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(event.kind.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(min: 80, ideal: 90)

            // Script name + version
            TableColumn("Script", value: \.source) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.source).font(.caption).fontWeight(.medium)
                    if let v = event.scriptVersion {
                        Text("v\(v)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 90, ideal: 110)

            // Summary
            TableColumn("Summary", value: \.summary) { event in
                Text(event.summary).font(.caption).lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            // Exit / signal
            TableColumn("Exit") { event in
                ExitCodeCell(exitCode: event.exitCode, exitedBySignal: event.exitedBySignal)
            }
            .width(min: 44, ideal: 52)

            // Detail: stderr first line, block type, or dep names
            TableColumn("Detail") { event in
                FeedDetailCell(event: event)
            }
            .width(min: 160)
        }
        .onChange(of: tableSelection) { _, ids in
            if let id = ids.first,
               let event = filteredEvents.first(where: { $0.id == id }) {
                selectedEvent = event
                tableSelection = []
            }
        }
        .contextMenu(forSelectionType: HistoryEvent.ID.self) { ids in
            if let id = ids.first,
               let event = filteredEvents.first(where: { $0.id == id }) {
                Button("View Full Detail") { selectedEvent = event }
            }
        }
    }
}

private struct ExitCodeCell: View {
    let exitCode: Int32?
    let exitedBySignal: Bool?
    var body: some View {
        if let code = exitCode {
            let bySignal = exitedBySignal == true
            let label = bySignal ? "SIG \(code)" : "\(code)"
            let color: Color = code == 0 ? .secondary : .red
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
        } else {
            Text("—").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

private struct FeedDetailCell: View {
    let event: HistoryEvent
    var body: some View {
        let text: String = {
            if let tail = event.stderrTail,
               let line = tail.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                return line
            }
            if let bt = event.blockType { return bt }
            if let d = event.detail,
               let line = d.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                return line
            }
            return "—"
        }()
        let isMono = event.stderrTail != nil
        Group {
            if isMono {
                Text(text).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct FeedEventRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.color)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.source).font(.subheadline).fontWeight(.medium)
                Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let title = event.blockTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let tail = event.stderrTail,
                   let line = tail.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Feed event detail sheet

private struct FeedEventDetailSheet: View {
    let event: HistoryEvent
    @Environment(\.dismiss) private var dismiss

    private var hasStderr: Bool { !(event.stderrTail ?? "").isEmpty }
    private var hasPayload: Bool { !(event.blockPayload ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: event.kind.systemImage)
                    .font(.title2).foregroundStyle(event.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.source).font(.title3).fontWeight(.semibold)
                    Text(event.kind.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Core metadata
                    Group {
                        infoRow("Time",    event.timestamp.formatted(date: .abbreviated, time: .complete))
                        infoRow("Summary", event.summary)
                        if let version = event.scriptVersion { infoRow("Version", version) }
                        if let bt = event.blockType          { infoRow("Block Type", bt) }
                        if let bid = event.blockID           { infoRow("Block ID", bid) }
                        if let title = event.blockTitle, !title.isEmpty { infoRow("Prompt", title) }
                        if let opts = event.blockOptions, !opts.isEmpty { infoRow("Options", opts) }
                    }
                    .padding(.horizontal, 16)

                    // Crash diagnostics
                    if let code = event.exitCode {
                        Divider().padding(.vertical, 8)

                        let label = (event.exitedBySignal == true)
                            ? "Killed by signal \(code)"
                            : (code == 0 ? "Unexpected clean exit (0)" : "Exit code \(code)")

                        HStack(spacing: 8) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text(label)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Stderr block
                    if let tail = event.stderrTail, !tail.isEmpty {
                        let lineCount = tail.components(separatedBy: "\n").count
                        VStack(alignment: .leading, spacing: 6) {
                            Text("STDERR — \(lineCount) line\(lineCount == 1 ? "" : "s")")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)

                            ScrollView {
                                Text(tail)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                            .padding(10)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    } else if let detail = event.detail, !detail.isEmpty {
                        // Non-crash detail (dependency list, etc.)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DETAIL")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)
                            Text(detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // Block payload (emitted blocks)
                    if let payload = event.blockPayload, !payload.isEmpty {
                        Divider().padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BLOCK PAYLOAD")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)
                            ScrollView {
                                Text(payload)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 300)
                            .padding(10)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 500, height: hasStderr || hasPayload ? 540 : 280)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        Divider()
    }
}

// MARK: - Setup output sheet

private struct SetupOutputSheet: View {
    let scriptName: String
    @Binding var lines: [String]
    @Binding var running: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up \(scriptName)").font(.title3).fontWeight(.semibold)
                    Text(running ? "Running…" : "Complete")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !running {
                    Button("Done") { dismiss() }
                }
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: lines.count) { _, _ in
                    proxy.scrollTo("bottom")
                }
            }
            .background(Color(.textBackgroundColor))

            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running setup…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(width: 520, height: 360)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("✗") || line.lowercased().contains("error") { return .red }
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("→") { return .primary }
        return .secondary
    }
}

// MARK: - Machine detail view

private enum MachineSection: String, CaseIterable, Identifiable {
    case cloud    = "Cloud"
    case devices  = "Devices"
    case machine  = "Machine"
    case sessions = "Sessions"
    case about    = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloud:    "icloud"
        case .devices:  "iphone"
        case .machine:  "desktopcomputer"
        case .sessions: "cpu"
        case .about:    "info.circle"
        }
    }
}

/// Reads the `com.apple.developer.icloud-container-environment` entitlement
/// from the running process's code signature. Returns "Production" or "Development".
private func cloudKitEnvironmentFromEntitlements() -> String {
    var error: Unmanaged<CFError>?
    guard let task = SecTaskCreateFromSelf(nil) else { return "Development" }
    let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, &error)
    return (value as? String) ?? "Development"
}

private struct MachineDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HeartbeatService.self) private var heartbeat
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(AppUpdater.self) private var updater
    @State private var selectedSection: MachineSection? = .cloud
    @State private var agentSessions: [AgentSession] = []
    @State private var liveProcesses: [LiveProcess] = []

    var body: some View {
        NavigationSplitView {
            List(MachineSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selectedSection ?? .cloud {
            case .cloud:    machineCloudSection
            case .devices:  machineDevicesSection
            case .machine:  machineMachineSection
            case .sessions: machineSessionsSection
            case .about:    machineAboutSection
            }
        }
        .navigationTitle("Machine")
        .onAppear { refreshSessions() }
    }

    // MARK: Section: Cloud

    private var machineCloudSection: some View {
        Form {
            Section("iCloud Sync") {
                LabeledContent("Status") {
                    if let lastBeat = heartbeat.lastHeartbeat {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(lastBeat, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    } else if let syncError = heartbeat.error {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label("Sync error", systemImage: "exclamationmark.icloud")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(syncError.localizedDescription)
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Heartbeat Interval") {
                    Text("\(Int(HeartbeatService.interval))s")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Machine ID") {
                    Text(settings.machineID)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Container") {
                    Text("iCloud.simple.ask")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("Database") {
                    Text("Private")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("Environment") {
                    let env = cloudKitEnvironmentFromEntitlements()
                    Text(env)
                        .foregroundStyle(env == "Production" ? .green : .orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cloud")
    }

    // MARK: Section: Devices

    private var machineDevicesSection: some View {
        Form {
            Section {
                if heartbeat.connectedDevices.isEmpty {
                    Text("No iPhones seen in the last hour.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(heartbeat.connectedDevices, id: \.deviceID) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.deviceName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                HStack(spacing: 8) {
                                    Label(device.lastSeen.formatted(.relative(presentation: .named)),
                                          systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption2)
                                    Text(device.deviceID.prefix(8) + "…")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fontDesign(.monospaced)
                                        .textSelection(.enabled)
                                }
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { device.enabled },
                                set: { heartbeat.setDeviceEnabled(device, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Connected iPhones")
                    Spacer()
                    if !heartbeat.connectedDevices.isEmpty {
                        Text("\(heartbeat.connectedDevices.count) device\(heartbeat.connectedDevices.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
    }

    // MARK: Section: Machine

    private var machineMachineSection: some View {
        @Bindable var settings = settings
        return Form {
            Section("Machine") {
                LabeledContent("Name") {
                    HStack(spacing: 6) {
                        TextField(AppSettings.defaultMachineName, text: $settings.machineName)
                            .multilineTextAlignment(.trailing)
                            .onAppear {
                                if settings.machineName.isEmpty {
                                    settings.machineName = AppSettings.defaultMachineName
                                }
                            }
                        if settings.machineName != AppSettings.defaultMachineName {
                            Button {
                                settings.machineName = AppSettings.defaultMachineName
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reset to Mac computer name")
                        }
                    }
                }
                LabeledContent("Machine ID") {
                    Text(settings.machineID)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("MCP Tools") {
                let builtIns: [(String, String, String)] = [
                    ("emit_block",            "Display a UI block on the iOS device",         "blockId, blockType, payload, ttl?"),
                    ("clear_block",           "Remove a UI block from the iOS device",         "blockId"),
                    ("get_schema",            "Get payload schemas for all block types",        "—"),
                    ("list_terminal_sessions","List interactive terminal sessions on this Mac", "filter?"),
                ]
                let systemScriptTools: [(String, String, String)] = scriptManager.scripts
                    .filter { $0.scriptType == "system" }
                    .flatMap { script -> [(String, String, String)] in
                        script.tools.map { tool in
                            let params = tool.params?.map(\.name).joined(separator: ", ") ?? "—"
                            return (tool.name, tool.description ?? "", params)
                        }
                    }
                ForEach(builtIns + systemScriptTools, id: \.0) { name, desc, params in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(.body, design: .monospaced))
                        if !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(params.isEmpty ? "—" : params)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Machine")
    }

    // MARK: Section: Sessions

    private var machineSessionsSection: some View {
        Form {
            Section {
                if agentSessions.isEmpty {
                    Text("No tracked sessions yet.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(agentSessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(s.controller).font(.caption).fontWeight(.medium)
                                Text(s.project).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(s.tty.isEmpty ? "no TTY" : s.tty)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(s.tty.isEmpty ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                            Text(s.cwd)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                HStack {
                    Text("Agent Sessions")
                    Spacer()
                    Button("Refresh") { refreshSessions() }
                        .font(.caption)
                }
            }

            Section("Live Processes") {
                if liveProcesses.isEmpty {
                    Text("No Claude or Codex processes found.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(liveProcesses) { p in
                        HStack {
                            Text(p.name).font(.caption).fontWeight(.medium)
                            Spacer()
                            Text("PID \(p.pid)  TTY \(p.tty)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sessions")
    }

    // MARK: Section: About

    private var machineAboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Form {
            Section("About") {
                LabeledContent("AskMac Version") {
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Updates") {
                LabeledContent("Software Update") {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    // MARK: Data loading

    private func refreshSessions() {
        let statusFiles: [(controller: String, path: String)] = [
            ("Claude Code", NSHomeDirectory() + "/.ask/status/claudecode-controller.json"),
            ("Codex",       NSHomeDirectory() + "/.ask/status/codex-controller.json"),
        ]
        var sessions: [AgentSession] = []
        var procs: [LiveProcess] = []
        for (controller, path) in statusFiles {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let list = json["sessions"] as? [[String: Any]] {
                for s in list {
                    sessions.append(AgentSession(
                        controller: controller,
                        sessionID: s["session_id"] as? String ?? "",
                        project:   s["project"]    as? String ?? "",
                        cwd:       s["cwd"]        as? String ?? "",
                        tty:       s["tty"]        as? String ?? ""
                    ))
                }
            }
            if let list = json["live_processes"] as? [[String: Any]] {
                for p in list {
                    let comm = p["comm"] as? String ?? ""
                    let name = p["name"] as? String ?? URL(fileURLWithPath: comm).lastPathComponent
                    procs.append(LiveProcess(
                        controller: controller,
                        pid:  p["pid"]  as? String ?? "",
                        tty:  p["tty"]  as? String ?? "",
                        comm: comm,
                        name: name
                    ))
                }
            }
        }
        agentSessions = sessions
        liveProcesses = procs
    }
}

// MARK: - Helpers

private struct AgentSession: Identifiable {
    let id = UUID()
    let controller: String
    let sessionID: String
    let project: String
    let cwd: String
    let tty: String
}

private struct LiveProcess: Identifiable {
    let id = UUID()
    let controller: String
    let pid: String
    let tty: String
    let comm: String
    let name: String
}

private extension String {
    func abbreviatingWithTildeInPath() -> String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        path.abbreviatingWithTildeInPath()
    }
}

// MARK: - Drop highlight overlay

private struct DropHighlightOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Drop to Install")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Script Install Sheet

private struct ScriptInstallSheet: View {
    @Bindable var installer: ScriptInstaller
    let scriptManager: ScriptManager
    let vaultURL: URL

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installer.errorMessage != nil ? "Cannot Install" : installTitle)
                        .font(.headline)
                    if installer.errorMessage == nil {
                        Text("\(installer.pending.count) script\(installer.pending.count == 1 ? "" : "s") ready to install")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    installer.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if let error = installer.errorMessage {
                // Error state
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding()
                }
            } else {
                // Script list
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(installer.pending) { script in
                            scriptRow(script)
                        }

                        if !installer.skipped.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(installer.skipped) { skipped in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(skipped.folderName)
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Text(skipped.reason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                Text("\(installer.skipped.count) script\(installer.skipped.count == 1 ? "" : "s") will be skipped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }

                Divider()

                // Actions
                HStack {
                    Button("Cancel") {
                        installer.cancel()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(installButtonLabel) {
                        installer.install(to: vaultURL, scriptManager: scriptManager)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.phase != .ready)
                }
                .padding()
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private var installTitle: String {
        let kinds = installer.pending.map(\.installKind)
        let allUpdates = kinds.allSatisfy { $0 == .update || $0 == .reinstall }
        let allNew = kinds.allSatisfy { $0 == .fresh }
        if installer.pending.count == 1 {
            switch installer.pending[0].installKind {
            case .fresh:     return "Install Script"
            case .update:    return "Update Script"
            case .downgrade: return "Downgrade Script"
            case .reinstall: return "Reinstall Script"
            }
        }
        return allUpdates ? "Update Scripts" : allNew ? "Install Scripts" : "Install & Update Scripts"
    }

    private var installButtonLabel: String {
        let hasDowngrade = installer.pending.contains { $0.installKind == .downgrade }
        let allUpdates = installer.pending.allSatisfy { $0.installKind == .update || $0.installKind == .reinstall }
        if hasDowngrade { return "Downgrade" }
        return allUpdates ? "Update" : "Install"
    }

    @Environment(\.colorScheme) private var colorScheme

    private func pendingScriptIcon(_ script: ScriptInstaller.PendingScript) -> NSImage? {
        guard let img = script.iconImage else { return nil }
        guard colorScheme == .dark, let svg = script.svgString else { return img }
        return svgToWhite(svg) ?? img
    }

    private func scriptRow(_ script: ScriptInstaller.PendingScript) -> some View {
        let hasWarnings = !script.warnings.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Icon
                Group {
                    if let img = pendingScriptIcon(script) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: script.icon ?? "square.grid.2x2")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(script.name)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        kindBadge(for: script)
                    }
                    if !script.description.isEmpty {
                        Text(script.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(script.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            // Warnings
            if hasWarnings {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(script.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .padding(.top, 1)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(6)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func kindBadge(for script: ScriptInstaller.PendingScript) -> some View {
        switch script.installKind {
        case .fresh:
            badge("New", color: .green)
        case .update:
            HStack(spacing: 3) {
                if let old = script.existingVersion {
                    Text(old).foregroundStyle(.tertiary)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Text("Update")
            }
            .font(.caption2)
            .foregroundStyle(.blue)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.blue.opacity(0.1))
            .clipShape(Capsule())
        case .downgrade:
            HStack(spacing: 3) {
                if let old = script.existingVersion {
                    Text(old).foregroundStyle(.tertiary)
                    Image(systemName: "arrow.down").font(.system(size: 8)).foregroundStyle(.orange)
                }
                Text("Downgrade")
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())
        case .reinstall:
            badge("Already Installed", color: .secondary)
        }
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }
}

// MARK: - View helpers

private extension View {
    /// Applies a transform only when the optional value is non-nil.
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
