#if canImport(AskMacCore)
import AskMacCore
#endif
import AppKit
import CloudKit
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Top-level tab

private enum MacTab: String, CaseIterable {
    case scripts, feed, machine

    var icon: String {
        switch self {
        case .scripts:  "terminal"
        case .feed:     "scroll"
        case .machine:  "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .scripts:  "Scripts"
        case .feed:     "Feed"
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

    var body: some View {
        Group {
            switch activeTab {
            case .scripts:
                ScriptsTabView()
                    .environment(scriptManager)
            case .feed:
                MacFeedView()
                    .environment(actionHistory)
            case .machine:
                MachineDetailView()
                    .environment(settings)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $activeTab) {
                    ForEach(MacTab.allCases, id: \.self) { tab in
                        Label(tab.label, systemImage: tab.icon).tag(tab)
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
                if id != nil { showVault = false; showCatalog = false }
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
                            if showVault {
                                showVault = false
                            } else {
                                showVault = true
                                showCatalog = false
                                selectedScriptID = nil
                            }
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
                            if showCatalog {
                                showCatalog = false
                            } else {
                                showCatalog = true
                                showVault = false
                                selectedScriptID = nil
                            }
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
                    Label("Uninstall", systemImage: "trash")
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
        case .pendingConsent:       .orange
        case .permissionDenied:     .orange
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




// MARK: - Setup output sheet

struct SetupOutputSheet: View {
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

struct ScriptInstallSheet: View {
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

