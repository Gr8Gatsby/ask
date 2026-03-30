import SwiftUI
import UIKit
import CloudKit
import UserNotifications

// MARK: - Script group model

/// A view-model grouping all blocks emitted by a single script.
struct ScriptGroup: Identifiable {
    let scriptID: String
    let blocks: [RKBlock]

    var id: String { scriptID }

    var name: String {
        blocks.first?.scriptName ?? scriptID
            .split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
    var icon: String?     { blocks.first?.scriptIcon }
    var iconSVG: String?  { blocks.first?.scriptIconSVG }
    var iconData: String? { blocks.first?.scriptIconData }

    /// The tile block drives home-screen tile display. Scripts emit this explicitly.
    private var tileBlock: RKTilePayload? {
        blocks.first(where: { $0.blockType == .tile })?.tilePayload
    }

    /// Action required only when a script explicitly sets action_required: true in its tile block.
    var isActionRequired: Bool { tileBlock?.actionRequired == true }

    /// Short status label: tile block takes priority, then first status block.
    var tileLabel: String? { tileBlock?.label ?? blocks.first(where: { $0.blockType == .status })?.statusPayload?.label }

    /// Status color: tile block takes priority, then first status block.
    var tileStatusColor: String? { tileBlock?.statusColor ?? blocks.first(where: { $0.blockType == .status })?.statusPayload?.color }

    /// Optional longer body text shown below the status line on the tile.
    var tileBody: String? { tileBlock?.body }

    /// Countdown block payload, if the script emitted one.
    var countdownPayload: RKCountdownPayload? {
        blocks.first(where: { $0.blockType == .countdown })?.countdownPayload
    }

    /// Title for the toast banner when action is required.
    var actionTitle: String? {
        if let label = tileBlock?.label, isActionRequired { return label }
        return nil
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.scenePhase) private var scenePhase

    @State private var machines: [AskMachine] = []
    @State private var blocks: [RKBlock] = []

    @State private var hasLoaded = false
    @State private var activeMachineID: String?
    @State private var showSettings = false
    @State private var showMachinePicker = false
    @State private var selectedScriptID: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var lastHeartbeatAt: Date = .distantPast
    @State private var notifiedBlockIDs: Set<String> = []
    @State private var dismissedToastScriptIDs: Set<String> = []
    @State private var burstPollingUntil: Date = .distantPast
    @State private var responseErrorMessage: String?
    @State private var deviceEnabled: Bool = true

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    private var scriptGroups: [ScriptGroup] {
        let grouped = Dictionary(grouping: blocks, by: { $0.scriptID })
        let sorted = grouped.keys.sorted { a, b in
            if a == "claudecode-controller" { return true }
            if b == "claudecode-controller" { return false }
            return a < b
        }
        return sorted.map { ScriptGroup(scriptID: $0, blocks: grouped[$0] ?? []) }
    }

    private var actionGroups: [ScriptGroup] {
        scriptGroups.filter { $0.isActionRequired }
    }

    private var visibleToastGroups: [ScriptGroup] {
        actionGroups.filter { !dismissedToastScriptIDs.contains($0.scriptID) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cloudKit.accountStatus == .noAccount || cloudKit.accountStatus == .restricted {
                    iCloudSignInState
                } else if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if machines.isEmpty {
                    emptyState
                } else if !deviceEnabled {
                    disabledState
                } else {
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .confirmationDialog("Switch Machine", isPresented: $showMachinePicker, titleVisibility: .visible) {
                ForEach(machines) { machine in
                    Button(machine.name) {
                        activeMachineID = machine.id
                        Task { await load() }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let errorMsg = responseErrorMessage {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Capsule())
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !visibleToastGroups.isEmpty {
                        ForEach(visibleToastGroups) { group in
                            ActionToastView(group: group, onTap: {
                                selectedScriptID = group.scriptID
                            }, onDismiss: {
                                let anim = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.8)
                                withAnimation(anim) {
                                    dismissedToastScriptIDs.insert(group.scriptID)
                                }
                            })
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: visibleToastGroups.map(\.scriptID))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: responseErrorMessage)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedScriptID != nil },
                set: { if !$0 { selectedScriptID = nil } }
            )
        ) {
            if let id = selectedScriptID {
                ScriptDetailView(
                    scriptID: id,
                    allBlocks: blocks,
                    isWaiting: Date() < burstPollingUntil,
                    onRespond: { block, value in await respondToBlock(block, value: value) },
                    toastGroups: visibleToastGroups,
                    errorMessage: responseErrorMessage,
                    onToastTap: { scriptID in
                        // Switch to the tapped script's detail inside the cover
                        selectedScriptID = scriptID
                    },
                    onToastDismiss: { scriptID in
                        let anim = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.8)
                        withAnimation(anim) { dismissedToastScriptIDs.insert(scriptID) }
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView()
                .environment(cloudKit)
        }
        .task {
            await cloudKit.checkAccountStatus()
            await load()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askRefreshRequired)) { _ in
            Task<Void, Never> { await load() }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Script tiles — single column, full width
                if scriptGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Active Scripts", systemImage: "terminal")
                    } description: {
                        Text("Scripts will appear here when they emit blocks.")
                    }
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(scriptGroups) { group in
                            ScriptTileView(group: group) {
                                selectedScriptID = group.scriptID
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
            .animation(.easeOut(duration: 0.25), value: scriptGroups.map(\.scriptID))
        }
        .refreshable { await load() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Ask")
                .font(.custom("PlaywriteNGModern-Regular", size: 22))
        }
        ToolbarItem(placement: .bottomBar) {
            machinePickerButton
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var machinePickerButton: some View {
        if let machine = activeMachine {
            Button {
                if machines.count > 1 { showMachinePicker = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.footnote)
                    Text(machine.name)
                        .font(.footnote)
                    if machines.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(machines.count <= 1)
        }
    }

    // MARK: - Empty / error states

    private var iCloudSignInState: some View {
        ContentUnavailableView {
            Label("Sign in to iCloud", systemImage: "icloud")
        } description: {
            Text("Sign into your Apple iCloud account to automatically discover devices.\n\nGo to Settings → [your name] → iCloud.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } description: {
            Text("Open Ask on your Mac to get started.\nBoth devices must be signed into the same iCloud account.")
        } actions: {
            Button("Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var disabledState: some View {
        ContentUnavailableView {
            Label("Access Disabled", systemImage: "iphone.slash")
        } description: {
            Text("This device has been disabled from your Mac.\nToggle it back on in the Ask menu bar app.")
        } actions: {
            Button("Check Again") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Data

    private func load() async {
        do {
            machines = try await cloudKit.fetchMachines()
        } catch {
            print("[HomeView] Failed to fetch machines: \(error)")
        }
        if let machine = activeMachine {
            deviceEnabled = await cloudKit.checkDeviceEnabled(machineID: machine.id)
            if deviceEnabled, let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                withAnimation(.easeOut(duration: 0.25)) {
                    blocks = fresh.filter { $0.blockType != .alert }
                }
            }
        }
        if !machines.isEmpty && Date().timeIntervalSince(lastHeartbeatAt) > 1800 {
            await cloudKit.saveDeviceHeartbeat(machineIDs: machines.map { $0.id })
            lastHeartbeatAt = Date()
        }
        hasLoaded = true
        notifyNewActionGroups()
    }

    private func notifyNewActionGroups() {
        let allCurrentBlockIDs = Set(blocks.map { $0.id })

        for group in actionGroups {
            // Find confirmation/prompt blocks that haven't triggered a notification yet
            let actionBlocks = group.blocks.filter {
                $0.blockType == .confirmation || $0.blockType == .prompt
            }
            let newBlocks = actionBlocks.filter { !notifiedBlockIDs.contains($0.id) }
            guard !newBlocks.isEmpty else { continue }

            // New action arrived for this script — clear any prior dismissal so toast reappears
            dismissedToastScriptIDs.remove(group.scriptID)
            for block in newBlocks { notifiedBlockIDs.insert(block.id) }

            let notifContent = UNMutableNotificationContent()
            notifContent.title = group.name
            notifContent.body = group.actionTitle ?? "Action required"
            notifContent.sound = .default
            let request = UNNotificationRequest(
                identifier: "ask-action-\(group.scriptID)-\(newBlocks[0].id)",
                content: notifContent,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Purge block IDs that are no longer in CloudKit
        notifiedBlockIDs = notifiedBlockIDs.intersection(allCurrentBlockIDs)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            // Require two consecutive empty results before clearing blocks.
            // Prevents a blank UI during the Mac restart window while scripts re-emit.
            var consecutiveEmpty = 0
            while !Task.isCancelled {
                let interval: Double = Date() < burstPollingUntil ? 1.0 : 3.0
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                if let fresh = try? await cloudKit.fetchMachines(), !fresh.isEmpty {
                    machines = fresh
                }
                if let machine = activeMachine {
                    let isEnabled = await cloudKit.checkDeviceEnabled(machineID: machine.id)
                    if deviceEnabled != isEnabled { deviceEnabled = isEnabled }
                    if isEnabled, let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                        let filtered = fresh.filter { $0.blockType != .alert }
                        if filtered.isEmpty {
                            consecutiveEmpty += 1
                            if consecutiveEmpty >= 2 {
                                withAnimation(.easeOut(duration: 0.25)) { blocks = filtered }
                            }
                        } else {
                            consecutiveEmpty = 0
                            withAnimation(.easeOut(duration: 0.25)) { blocks = filtered }
                        }
                    }
                }
            }
        }
    }

    private func respondToBlock(_ block: RKBlock, value: String) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let shouldRemove: Bool
        switch block.blockType {
        case .confirmation, .prompt, .picker, .detail: shouldRemove = true
        default: shouldRemove = false
        }

        if shouldRemove {
            withAnimation(.easeOut(duration: 0.22)) {
                blocks.removeAll { $0.id == block.id }
            }
        }

        burstPollingUntil = Date().addingTimeInterval(10)

        do {
            try await cloudKit.postResponse(
                blockID: block.id,
                machineID: block.machineID,
                scriptID: block.scriptID,
                value: value
            )
        } catch {
            if shouldRemove {
                withAnimation(.easeOut(duration: 0.22)) {
                    blocks.append(block)
                    blocks.sort {
                        if $0.requiresResponse != $1.requiresResponse { return $0.requiresResponse }
                        return $0.createdAt > $1.createdAt
                    }
                }
            }
            burstPollingUntil = .distantPast
            withAnimation { responseErrorMessage = "Couldn't send — check your connection" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { responseErrorMessage = nil }
            }
        }
    }
}

// MARK: - Script tile

private struct ScriptTileView: View {
    let group: ScriptGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ScriptIconView(
                    svgString: group.iconSVG,
                    iconData: group.iconData,
                    sfSymbol: group.icon ?? "terminal.fill"
                )
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

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

                    if let body = group.tileBody, !body.isEmpty {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }

                    if let countdown = group.countdownPayload {
                        CountdownTileLine(payload: countdown)
                    }
                }

                Spacer()

                if group.isActionRequired {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        group.isActionRequired
                            ? Color.orange.opacity(0.5)
                            : Color(.separator).opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Countdown tile line

private struct CountdownTileLine: View {
    let payload: RKCountdownPayload
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear { text = formatted() }
        .task {
            while !Task.isCancelled {
                text = formatted()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func formatted() -> String {
        guard let target = ISO8601DateFormatter().date(from: payload.time) else {
            return payload.label
        }
        let seconds = target.timeIntervalSinceNow
        guard seconds > 0 else { return "\(payload.label) overdue" }
        let hours = Int(seconds / 3600)
        let mins  = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 {
            return "\(payload.label) in \(hours)h\(mins > 0 ? " \(mins)m" : "")"
        } else {
            return "\(payload.label) in \(mins)m"
        }
    }
}

// MARK: - Action toast banner

private struct ActionToastView: View {
    let group: ScriptGroup
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ScriptIconView(
                        svgString: group.iconSVG,
                        iconData: group.iconData,
                        sfSymbol: group.icon ?? "terminal.fill"
                    )
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        if let title = group.actionTitle {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}

// MARK: - Script detail (full screen)

private struct ScriptDetailView: View {
    let scriptID: String
    let allBlocks: [RKBlock]
    var isWaiting: Bool = false
    let onRespond: (RKBlock, String) async -> Void
    var toastGroups: [ScriptGroup] = []
    var errorMessage: String? = nil
    var onToastTap: ((String) -> Void)? = nil
    var onToastDismiss: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // Detail-push navigation state
    @State private var isShowingDetail = false
    @State private var pushedDetail: RKBlock? = nil
    @State private var detailSentResponse = false

    private var group: ScriptGroup {
        ScriptGroup(scriptID: scriptID, blocks: allBlocks.filter { $0.scriptID == scriptID && $0.blockType != .tile })
    }

    /// Blocks shown in the main list — detail blocks are handled as navigation pushes.
    private var mainBlocks: [RKBlock] { group.blocks.filter { $0.blockType != .detail } }

    /// The active detail block, if any.
    private var currentDetailBlock: RKBlock? { group.blocks.first { $0.blockType == .detail } }

    var body: some View {
        NavigationStack {
            Group {
                if mainBlocks.isEmpty && isWaiting && currentDetailBlock == nil {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for response…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(mainBlocks) { block in
                            Section {
                                BlockView(block: block, isWaiting: isWaiting) { value in
                                    await onRespond(block, value)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ScriptIconView(
                            svgString: group.iconSVG,
                            iconData: group.iconData,
                            sfSymbol: group.icon ?? "terminal.fill"
                        )
                        .frame(width: 22, height: 22)
                        Text(group.name)
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $isShowingDetail) {
                if let block = pushedDetail, let payload = block.detailPayload {
                    DetailFullView(
                        payload: payload,
                        onClose: {
                            detailSentResponse = true
                            Task { await onRespond(block, "dismissed") }
                            isShowingDetail = false
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                if !isShowingDetail { pushedDetail = nil }
                            }
                        },
                        onAction: { value in
                            await onRespond(block, value)
                        }
                    )
                }
            }
            .overlay(alignment: .bottom) {
                toastOverlay
            }
        }
        .onChange(of: currentDetailBlock?.id) { _, newID in
            if let id = newID, pushedDetail?.id != id {
                pushedDetail = currentDetailBlock
                detailSentResponse = false
                isShowingDetail = true
            } else if newID == nil && isShowingDetail {
                // Block cleared externally — pop without sending a duplicate response
                detailSentResponse = true
                isShowingDetail = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    pushedDetail = nil
                    detailSentResponse = false
                }
            }
        }
        .onChange(of: isShowingDetail) { _, showing in
            if !showing && !detailSentResponse {
                // User swiped back via the system gesture
                if let block = pushedDetail {
                    Task { await onRespond(block, "dismissed") }
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !isShowingDetail { pushedDetail = nil }
                }
                detailSentResponse = false
            }
        }
    }

    private var toastOverlay: some View {
        VStack(spacing: 8) {
            if let errorMsg = errorMessage {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !toastGroups.isEmpty {
                ForEach(toastGroups) { group in
                    ActionToastView(group: group, onTap: {
                        onToastTap?(group.scriptID)
                    }, onDismiss: {
                        onToastDismiss?(group.scriptID)
                    })
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastGroups.map(\.scriptID))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: errorMessage)
    }
}

// MARK: - Detail full-screen view

private struct DetailFullView: View {
    let payload: RKDetailPayload
    let onClose: () -> Void
    var onAction: ((String) async -> Void)? = nil

    @State private var responding = false
    @State private var selectedAction: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                markdownBody

                if let actions = payload.actions, !actions.isEmpty, onAction != nil {
                    VStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            actionButton(action)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .navigationTitle(payload.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onClose)
                    .disabled(responding)
            }
        }
    }

    private var markdownBody: some View {
        // .inlineOnlyPreservingWhitespace: renders bold/italic/code/links inline
        // and preserves \n line breaks. .full causes paragraph spacing to collapse
        // in SwiftUI Text and renders --- as "——".
        Group {
            if let attributed = try? AttributedString(
                markdown: payload.body,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(payload.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func actionButton(_ action: String) -> some View {
        let isSelected = selectedAction == action
        return Button {
            guard !responding, let handler = onAction else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            selectedAction = action
            Task {
                responding = true
                await handler(action)
                responding = false
            }
        } label: {
            ZStack {
                if responding && isSelected {
                    ProgressView().tint(Color.accentColor)
                } else {
                    Text(action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(responding)
        .opacity(responding && !isSelected ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: responding)
    }
}

// MARK: - Helpers

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

// MARK: - Script icon

/// Renders the script's icon. Priority: PNG (from Mac SVG→PNG) → SF Symbol.
private struct ScriptIconView: View {
    let svgString: String?
    let iconData: String?
    let sfSymbol: String

    var body: some View {
        if let data = iconData,
                  let imageData = Data(base64Encoded: data),
                  let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: sfSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings sheet

struct SettingsSheetView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showBlockDebugInfo") private var showDebugInfo: Bool = false
    @State private var machines: [AskMachine] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Machines") {
                    ForEach(machines) { machine in
                        NavigationLink {
                            MachineDetailView(machine: machine)
                                .environment(cloudKit)
                        } label: {
                            MachineRow(machine: machine)
                        }
                    }
                }

                if let machine = machines.first {
                    Section {
                        NavigationLink {
                            MessagesView(machine: machine)
                                .environment(cloudKit)
                        } label: {
                            Label("Messages", systemImage: "message")
                        }
                    }
                }

                Section("Developer") {
                    Toggle("Show Debug Info on Cards", isOn: $showDebugInfo)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                machines = (try? await cloudKit.fetchMachines()) ?? []
            }
        }
    }
}
