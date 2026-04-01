import SwiftUI
import UIKit
import CloudKit
import UserNotifications
import SwiftData

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

    /// Brand colors for well-known scripts, keyed by scriptID.
    var brandBackground: Color? {
        switch scriptID {
        case "claudecode-controller": Color(red: 250/255, green: 249/255, blue: 245/255)
        case "github":               Color(red: 0x24/255, green: 0x29/255, blue: 0x2F/255)
        default: nil
        }
    }

    var brandHighlight: Color? {
        switch scriptID {
        case "claudecode-controller": Color(red: 202/255, green: 124/255, blue: 94/255)
        case "github":               Color(red: 0x09/255, green: 0x69/255, blue: 0xDA/255)
        default: nil
        }
    }

    /// Force a specific color scheme so text and system colors render correctly on brand backgrounds.
    var brandColorScheme: ColorScheme? {
        switch scriptID {
        case "github": .dark
        default: nil
        }
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
    @State private var selectedScriptID: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var lastHeartbeatAt: Date = .distantPast
    @State private var notifiedBlockIDs: Set<String> = []
    @State private var burstPollingUntil: Date = .distantPast
    /// Cached script icons — available immediately on launch for the loading scene.
    @State private var iconCache = ScriptIconCache()
    /// Controls the loading icon overlay — kept true briefly after hasLoaded
    /// so exit animations can complete before the overlay is removed.
    @State private var showLoadingOverlay = true
    @State private var responseErrorMessage: String?
    @State private var queuedMessage: String?
    @State private var deviceEnabled: Bool = true
    @State private var showQueueReview: Bool = false
    @State private var wasOffline: Bool = false
    @State private var selectedTab: HomeTab = .home

    private var offlineQueue: OfflineQueue { .shared }

    enum HomeTab: Hashable { case home, feed }

    private var macIsOffline: Bool {
        activeMachine?.connectionStatus == .offline
    }

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

    var body: some View {
        NavigationStack {
            Group {
                if cloudKit.accountStatus == .noAccount || cloudKit.accountStatus == .restricted {
                    iCloudSignInState
                } else if !hasLoaded {
                    // Empty view — the loading overlay is shown via .overlay below
                    Color.clear
                } else if machines.isEmpty {
                    emptyState
                } else if !deviceEnabled {
                    disabledState
                } else if selectedTab == .feed {
                    FeedView(machines: machines, activeMachineID: activeMachineID)
                } else {
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .overlay {
                // Loading icon overlay — visible until the first load completes
                // and exit animations finish. Shown whether or not we have
                // cached data (falls back to a plain spinner if cache is empty).
                if showLoadingOverlay {
                    if iconCache.entries.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground))
                    } else {
                        ScriptLoadingView(
                            entries: iconCache.entries,
                            loadedIDs: Set(scriptGroups.map(\.scriptID)),
                            hasLoaded: hasLoaded
                        )
                        .background(hasLoaded ? .clear : Color(.systemBackground))
                        .animation(.easeOut(duration: 0.3), value: hasLoaded)
                    }
                }
            }
            .onChange(of: hasLoaded) { _, loaded in
                guard loaded else { return }
                // Keep overlay alive long enough for icon exit animations (~0.7 s),
                // then remove it entirely so it doesn't intercept touches.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    showLoadingOverlay = false
                }
            }
            .sheet(isPresented: $showQueueReview) {
                QueueReviewSheet(isPresented: $showQueueReview)
                    .environment(cloudKit)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let msg = queuedMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.orange.opacity(0.9))
                            .clipShape(Capsule())
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: responseErrorMessage)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: queuedMessage)
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
                    errorMessage: responseErrorMessage,
                    machines: machines,
                    activeMachine: activeMachine,
                    onSelectMachine: { machineID in
                        activeMachineID = machineID
                        await load()
                    }
                )
                .task {
                    // Poll continuously while the detail view is open, so updates
                    // arrive even if HomeView's poll loop was paused by onDisappear.
                    await load()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { break }
                        await load()
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView()
                .environment(cloudKit)
        }
        .task {
            await cloudKit.checkAccountStatus()
            await load()
            // Consume scriptID persisted by AppDelegate for cold-start navigation:
            // the notification tap may fire before HomeView is in the hierarchy.
            if let id = UserDefaults.standard.string(forKey: "pendingNavigationScriptID") {
                UserDefaults.standard.removeObject(forKey: "pendingNavigationScriptID")
                selectedScriptID = id
            }
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await cloudKit.checkAccountStatus() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askRefreshRequired)) { _ in
            Task<Void, Never> { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askNavigateToScript)) { notif in
            if let scriptID = notif.userInfo?["scriptID"] as? String {
                selectedScriptID = scriptID
                Task { await load() }
            }
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

    // MARK: - Toolbar (nav bar title only)

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Ask")
                .font(.custom("PlaywriteNGModern-Regular", size: 22))
        }
    }

    // MARK: - Custom bottom bar (avoids UIKitToolbar subview warning on iOS 26)

    private var bottomBar: some View {
        HStack(spacing: 14) {
            machineMenuButton
            tabSwitcher
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach([HomeTab.home, HomeTab.feed], id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab == .home ? "Home" : "Feed")
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(selectedTab == tab ? Color.primary.opacity(0.1) : .clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var machineMenuButton: some View {
        Menu {
            ForEach(machines) { machine in
                Button {
                    activeMachineID = machine.id
                    Task { await load() }
                } label: {
                    Label(machine.name, systemImage: machine.systemImage)
                }
            }
        } label: {
            let offline = activeMachine?.connectionStatus == .offline
            Image(systemName: activeMachine?.systemImage ?? "desktopcomputer")
                .foregroundStyle(offline ? .secondary : .primary)
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
                    blocks = fresh.filter { !$0.isFeedBlock || $0.requiresResponse }
                        .filter { $0.blockType != .alert }
                }
            }
        }
        if !machines.isEmpty && Date().timeIntervalSince(lastHeartbeatAt) > 1800 {
            await cloudKit.saveDeviceHeartbeat(machineIDs: machines.map { $0.id })
            lastHeartbeatAt = Date()
        }
        hasLoaded = true
        // Update the icon cache so the next launch has fresh data
        iconCache.update(from: scriptGroups.map {
            (id: $0.scriptID, name: $0.name, sfSymbol: $0.icon, iconData: $0.iconData)
        })
        notifyNewActionGroups()
    }

    private func notifyNewActionGroups() {
        let allCurrentBlockIDs = Set(blocks.map { $0.id })

        for group in actionGroups {
            // Prefer explicit confirmation/prompt blocks; fall back to the tile block
            // itself when the script marks action_required on the tile (e.g. Claude Code).
            let triggerBlocks: [RKBlock]
            let explicit = group.blocks.filter {
                $0.blockType == .confirmation || $0.blockType == .prompt
            }
            if !explicit.isEmpty {
                triggerBlocks = explicit
            } else if let tile = group.blocks.first(where: { $0.blockType == .tile }) {
                triggerBlocks = [tile]
            } else {
                continue
            }

            let newBlocks = triggerBlocks.filter { !notifiedBlockIDs.contains($0.id) }
            guard !newBlocks.isEmpty else { continue }

            for block in newBlocks { notifiedBlockIDs.insert(block.id) }

            let notifContent = UNMutableNotificationContent()
            notifContent.title = group.name
            // Use the tile body (the actual question) when available, else the label
            notifContent.body = group.tileBody ?? group.actionTitle ?? "Action required"
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
                let interval: Double
                if Date() < burstPollingUntil {
                    interval = 1.0   // just responded — fast burst
                } else {
                    interval = 3.0   // default — keep UI fresh
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                if let fresh = try? await cloudKit.fetchMachines(), !fresh.isEmpty {
                    machines = fresh
                }

                // Detect Mac coming back online — show queue review if needed.
                let nowOffline = macIsOffline
                if wasOffline && !nowOffline && !offlineQueue.isEmpty {
                    showQueueReview = true
                }
                wasOffline = nowOffline

                if let machine = activeMachine {
                    let isEnabled = await cloudKit.checkDeviceEnabled(machineID: machine.id)
                    if deviceEnabled != isEnabled { deviceEnabled = isEnabled }
                    if isEnabled, let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                        let filtered = fresh.filter { !$0.isFeedBlock || $0.requiresResponse }
                            .filter { $0.blockType != .alert }
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

        // If Mac is offline, queue the response for later review.
        if macIsOffline {
            let name = block.scriptName ?? block.scriptID
            offlineQueue.enqueue(
                machineID: block.machineID,
                scriptID: block.scriptID,
                scriptName: name,
                blockID: block.id,
                value: value
            )
            withAnimation(.default) { queuedMessage = "Queued — Mac is offline" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.default) { queuedMessage = nil }
            }
            return
        }

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

        burstPollingUntil = Date().addingTimeInterval(20)

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
            withAnimation(.default) { responseErrorMessage = "Couldn't send — check your connection" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.default) { responseErrorMessage = nil }
            }
        }
    }
}

// MARK: - Script tile

private struct ScriptTileView: View {
    let group: ScriptGroup
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true

    private var effectiveBackground: Color {
        useBrandColors ? (group.brandBackground ?? Color(.secondarySystemGroupedBackground))
                       : Color(.secondarySystemGroupedBackground)
    }

    private var effectiveHighlight: Color? {
        useBrandColors ? group.brandHighlight : nil
    }

    private var effectiveColorScheme: ColorScheme {
        useBrandColors ? (group.brandColorScheme ?? colorScheme) : colorScheme
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ScriptIconView(
                    svgString: group.iconSVG,
                    iconData: group.iconData,
                    sfSymbol: group.icon ?? "terminal.fill"
                )
                .frame(width: 30, height: 30)
                .colorInvert(useBrandColors && group.brandColorScheme == .dark)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let label = group.tileLabel {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(effectiveHighlight ?? blockStatusColor(group.tileStatusColor))
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
                            .lineLimit(1)
                            .padding(.top, 1)
                    }

                    if let countdown = group.countdownPayload {
                        CountdownTileLine(payload: countdown)
                    }
                }

                Spacer()

                if group.isActionRequired {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(effectiveHighlight ?? .orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
            .background(effectiveBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        group.isActionRequired
                            ? (effectiveHighlight ?? Color.orange).opacity(0.5)
                            : Color(.separator).opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, effectiveColorScheme)
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

// MARK: - Script detail (full screen)

struct ScriptDetailView: View {
    let scriptID: String
    let allBlocks: [RKBlock]
    var isWaiting: Bool = false
    let onRespond: (RKBlock, String) async -> Void
    var errorMessage: String? = nil
    var machines: [AskMachine] = []
    var activeMachine: AskMachine? = nil
    var onSelectMachine: ((String) async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true

    // Detail-push navigation state
    @State private var isShowingDetail = false
    @State private var pushedDetail: RKBlock? = nil
    @State private var detailSentResponse = false
    /// ID of a detail block the user just dismissed. We ignore re-appearances of this
    /// block (from burst polling before the script clears it) to prevent re-pushing.
    @State private var dismissedDetailBlockID: String? = nil
    @State private var showRepoPicker = false
    @State private var keyboardVisible = false

    private var group: ScriptGroup {
        ScriptGroup(scriptID: scriptID, blocks: allBlocks.filter { $0.scriptID == scriptID && $0.blockType != .tile })
    }

    /// ScriptGroup including tile block — used only for brand color lookup.
    private var brandGroup: ScriptGroup {
        ScriptGroup(scriptID: scriptID, blocks: allBlocks.filter { $0.scriptID == scriptID })
    }

    /// Script display name — resolved from all blocks including the tile, so we get
    /// the real name even when only a tile block exists (group.blocks excludes tiles).
    private var scriptDisplayName: String {
        allBlocks.first { $0.scriptID == scriptID }?.scriptName
            ?? scriptID.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    /// Icon fields resolved from all blocks including the tile, so the icon shows
    /// even when no non-tile blocks are present (e.g. "No active sessions" state).
    private var scriptIconSF: String {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIcon != nil })?.scriptIcon ?? "terminal.fill"
    }
    private var scriptIconSVG: String? {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIconSVG != nil })?.scriptIconSVG
    }
    private var scriptIconData: String? {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIconData != nil })?.scriptIconData
    }

    private var startSessionBlock: RKBlock? {
        group.blocks.first { $0.blockType == .startSession }
    }

    /// Blocks shown in the main list — detail blocks are pushed; claudeMessage is inlined when chatPrompt or agentSession blocks exist.
    private var mainBlocks: [RKBlock] {
        let all = group.blocks.filter { $0.blockType != .detail && $0.blockType != .startSession }
        let hasPrompt = all.contains(where: { $0.blockType == .chatPrompt })
        let hasSession = all.contains(where: { $0.blockType == .agentSession })
        guard hasPrompt || hasSession else { return all }
        // Exclude claudeMessage (inlined) and confirmations that are linked to a session (grouped inside session section)
        return all.filter {
            $0.blockType != .claudeMessage &&
            !($0.blockType == .confirmation && $0.confirmationPayload?.sessionId != nil)
        }
    }

    /// Text from a claudeMessage block, shown above the chatPrompt input.
    private var inlinedClaudeMessage: String? {
        group.blocks.first { $0.blockType == .claudeMessage }?.claudeMessagePayload?.text
    }

    /// Confirmation blocks linked to a specific session_id.
    private func sessionConfirmations(for sessionId: String) -> [RKBlock] {
        group.blocks.filter {
            $0.blockType == .confirmation && $0.confirmationPayload?.sessionId == sessionId
        }
    }

    /// The active detail block, if any.
    private var currentDetailBlock: RKBlock? { group.blocks.first { $0.blockType == .detail } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(mainBlocks) { block in
                    Section {
                        if block.blockType == .agentSession,
                           let p = block.agentSessionPayload {
                            let confirmations = sessionConfirmations(for: p.sessionId)
                            // Render any linked confirmations above the session reply box
                            ForEach(confirmations) { conf in
                                BlockView(block: conf, onRespond: { value in
                                    await onRespond(conf, value)
                                }, isWaiting: isWaiting)
                            }
                            BlockView(block: block, onRespond: { value in
                                await onRespond(block, value)
                            }, isWaiting: isWaiting)
                        } else if block.blockType == .startSession,
                                  let p = block.startSessionPayload {
                            StartSessionBlockView(payload: p, onRespond: { value in
                                await onRespond(block, value)
                            })
                        } else if block.blockType == .chatPrompt, let p = block.chatPromptPayload {
                            ChatPromptBlockView(
                                payload: p,
                                claudeMessage: inlinedClaudeMessage,
                                onRespond: { value in await onRespond(block, value) }
                            )
                        } else {
                            BlockView(block: block, onRespond: { value in
                                await onRespond(block, value)
                            }, isWaiting: isWaiting)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(useBrandColors ? (brandGroup.brandBackground ?? Color(.systemGroupedBackground)) : Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ScriptIconView(
                            svgString: scriptIconSVG,
                            iconData: scriptIconData,
                            sfSymbol: scriptIconSF
                        )
                        .frame(width: 22, height: 22)
                        Text(scriptDisplayName)
                            .font(.headline)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { detailBottomBar }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .sheet(isPresented: $showRepoPicker) {
                if let block = startSessionBlock, let payload = block.startSessionPayload {
                    RepoPickerSheet(repos: payload.repos) { repo in
                        showRepoPicker = false
                        Task { await onRespond(block, repo.path) }
                    }
                }
            }
            .navigationDestination(isPresented: $isShowingDetail) {
                if let block = pushedDetail, let payload = block.detailPayload {
                    DetailFullView(
                        payload: payload,
                        onClose: {
                            detailSentResponse = true
                            let closedID = block.id
                            dismissedDetailBlockID = closedID
                            Task { await onRespond(block, "dismissed") }
                            isShowingDetail = false
                            // Safety timer: clear the guard after the script has had time
                            // to remove the block from CloudKit (~3–5 s). Without this,
                            // re-tapping the same issue would be permanently blocked.
                            Task {
                                try? await Task.sleep(for: .seconds(6))
                                if dismissedDetailBlockID == closedID {
                                    dismissedDetailBlockID = nil
                                }
                            }
                        },
                        onAction: { value in
                            await onRespond(block, value)
                        }
                    )
                }
            }
        }
        .onChange(of: currentDetailBlock?.id) { _, newID in
            if let id = newID {
                // Ignore re-appearances of the block we just dismissed (burst polling
                // may fetch it again before the script clears it from CloudKit).
                guard id != dismissedDetailBlockID else { return }
                // Ignore if it's already the block we're showing.
                guard pushedDetail?.id != id else { return }
                pushedDetail = currentDetailBlock
                detailSentResponse = false
                dismissedDetailBlockID = nil
                isShowingDetail = true
            } else {
                // Block gone — could be optimistic removal (before CloudKit confirms)
                // or the script genuinely cleared it. Do NOT clear dismissedDetailBlockID
                // here: clearing it now would let burst polling re-push the dismissed block.
                // The close/swipe-back handlers each start a 6-second safety timer to
                // clear dismissedDetailBlockID once the script has had time to remove the
                // block from CloudKit.
                if isShowingDetail {
                    // Cleared externally (script refreshed, etc.) — pop silently.
                    detailSentResponse = true
                    isShowingDetail = false
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !isShowingDetail { pushedDetail = nil }
                }
            }
        }
        .onChange(of: isShowingDetail) { _, showing in
            if !showing && !detailSentResponse {
                // User swiped back via the system gesture.
                if let block = pushedDetail {
                    let swipedID = block.id
                    dismissedDetailBlockID = swipedID
                    Task { await onRespond(block, "dismissed") }
                    // Safety timer: clear guard after script has removed block from CloudKit.
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        if dismissedDetailBlockID == swipedID {
                            dismissedDetailBlockID = nil
                        }
                    }
                }
            }
            if !showing {
                detailSentResponse = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !isShowingDetail { pushedDetail = nil }
                }
            }
        }
        .environment(\.colorScheme, useBrandColors ? (brandGroup.brandColorScheme ?? colorScheme) : colorScheme)
    }

    private var detailBottomBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                // Keyboard dismiss — shown only when keyboard is visible
                if keyboardVisible {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }

                // Home (not selected)
                Button { dismiss() } label: {
                    Text("Home")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                // Script icon (selected state) — uses brand PNG, falls back to SF symbol
                Button { } label: {
                    ScriptIconView(
                        svgString: scriptIconSVG,
                        iconData: scriptIconData,
                        sfSymbol: scriptIconSF
                    )
                    .frame(width: 20, height: 20)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)

                // Plus button (start session)
                if startSessionBlock != nil {
                    Button { showRepoPicker = true } label: {
                        Image(systemName: "plus")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            Spacer()
        }
        .padding(.bottom, 16)
        .padding(.top, 4)
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

private extension View {
    @ViewBuilder
    func colorInvert(_ active: Bool) -> some View {
        if active { self.colorInvert() } else { self }
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
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true
    @State private var machines: [AskMachine] = []
    @State private var showQueueReview = false
    @State private var feedSchedules: [String: String] = [:]

    @Query(sort: \FeedHistoryEntry.createdAt, order: .reverse)
    private var feedHistory: [FeedHistoryEntry]

    private var feedScripts: [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(id: String, name: String)] = []
        for entry in feedHistory {
            if seen.insert(entry.scriptID).inserted {
                result.append((id: entry.scriptID, name: entry.scriptName ?? entry.scriptID))
            }
        }
        return result
    }

    private var queue: OfflineQueue { .shared }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

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

                if !queue.isEmpty {
                    Section {
                        Button {
                            showQueueReview = true
                        } label: {
                            HStack {
                                Label("Queued Actions", systemImage: "tray.and.arrow.up")
                                Spacer()
                                Text("\(queue.count)")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    } footer: {
                        Text("Actions taken while your Mac was offline. Review before sending.")
                    }
                }

                if !feedScripts.isEmpty {
                    Section("Feed Schedules") {
                        ForEach(feedScripts, id: \.id) { script in
                            FeedScheduleRow(
                                scriptName: script.name,
                                schedule: Binding(
                                    get: { feedSchedules[script.id] ?? "0 * * * *" },
                                    set: { newSchedule in
                                        feedSchedules[script.id] = newSchedule
                                        if let machine = machines.first {
                                            Task {
                                                try? await cloudKit.saveFeedSchedule(
                                                    machineID: machine.id,
                                                    scriptID: script.id,
                                                    schedule: newSchedule
                                                )
                                            }
                                        }
                                    }
                                )
                            )
                        }
                    }
                }

                Section("Appearance") {
                    Toggle("Script Brand Colors", isOn: $useBrandColors)
                }

                Section("Developer") {
                    Toggle("Show Debug Info on Cards", isOn: $showDebugInfo)
                    LabeledContent("App Version") {
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
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
                if let machine = machines.first,
                   let schedules = try? await cloudKit.fetchFeedSchedules(machineID: machine.id) {
                    var map: [String: String] = [:]
                    for (scriptID, schedule) in schedules { map[scriptID] = schedule }
                    feedSchedules = map
                }
            }
            .sheet(isPresented: $showQueueReview) {
                QueueReviewSheet(isPresented: $showQueueReview)
                    .environment(cloudKit)
            }
        }
    }
}

// MARK: - Feed schedule row

private struct FeedScheduleRow: View {
    let scriptName: String
    @Binding var schedule: String

    private let presets: [(label: String, cron: String)] = [
        ("Every Hour",   "0 * * * *"),
        ("Daily 9am",    "0 9 * * *"),
        ("Daily 6pm",    "0 18 * * *"),
        ("Weekly Mon",   "0 9 * * 1"),
    ]

    private var presetLabel: String {
        presets.first(where: { $0.cron == schedule })?.label ?? "Custom"
    }

    var body: some View {
        HStack {
            Text(scriptName)
                .lineLimit(1)
            Spacer()
            Menu {
                ForEach(presets, id: \.cron) { preset in
                    Button {
                        schedule = preset.cron
                    } label: {
                        if preset.cron == schedule {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(presetLabel)
                        .font(.subheadline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Queue Review Sheet

struct QueueReviewSheet: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Binding var isPresented: Bool

    private var queue: OfflineQueue { .shared }

    @State private var sendingIDs: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if queue.isEmpty {
                    ContentUnavailableView(
                        "No Queued Actions",
                        systemImage: "tray",
                        description: Text("Actions you take while your Mac is offline will appear here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(queue.entries) { entry in
                                QueueEntryRow(entry: entry, isSending: sendingIDs.contains(entry.id)) {
                                    await sendEntry(entry)
                                } onDiscard: {
                                    queue.remove(id: entry.id)
                                }
                            }
                        } footer: {
                            if let err = errorMessage {
                                Text(err).foregroundStyle(.red)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Queued Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard All", role: .destructive) {
                        queue.removeAll()
                        isPresented = false
                    }
                    .foregroundStyle(.red)
                    .disabled(queue.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send All") {
                        Task { await sendAll() }
                    }
                    .disabled(queue.isEmpty || !sendingIDs.isEmpty)
                }
            }
        }
    }

    private func sendEntry(_ entry: OfflineQueueEntry) async {
        sendingIDs.insert(entry.id)
        do {
            try await cloudKit.postResponse(
                blockID: entry.blockID,
                machineID: entry.machineID,
                scriptID: entry.scriptID,
                value: entry.responseValue
            )
            queue.remove(id: entry.id)
        } catch {
            errorMessage = "Failed to send — check your connection"
            Task {
                try? await Task.sleep(for: .seconds(3))
                errorMessage = nil
            }
        }
        sendingIDs.remove(entry.id)
        if queue.isEmpty { isPresented = false }
    }

    private func sendAll() async {
        let all = queue.entries
        await withTaskGroup(of: Void.self) { group in
            for entry in all {
                group.addTask { await sendEntry(entry) }
            }
        }
    }
}

private struct QueueEntryRow: View {
    let entry: OfflineQueueEntry
    let isSending: Bool
    let onSend: () async -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.scriptName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(entry.responseValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(entry.queuedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button {
                        onDiscard()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)

                    Button("Send") {
                        Task { await onSend() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
