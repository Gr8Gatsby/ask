import SwiftUI
import UIKit
import CloudKit
import SwiftData

// MARK: - Machine tombstone store

/// Persists deletion timestamps for machines removed from the iOS app.
/// A machine is suppressed until it produces a heartbeat newer than its tombstone.
enum MachineTombstoneStore {
    private static let key = "deletedMachineTimestamps"
    private static let formatter = ISO8601DateFormatter()

    static func record(machineID: String) {
        var store = load()
        store[machineID] = formatter.string(from: Date())
        UserDefaults.standard.set(store, forKey: key)
    }

    static func clear(machineID: String) {
        var store = load()
        store.removeValue(forKey: machineID)
        UserDefaults.standard.set(store, forKey: key)
    }

    /// Filters machines through tombstone logic. Machines whose heartbeat is newer than their
    /// tombstone are surfaced and their tombstone is cleared. Others remain suppressed.
    static func apply(to machines: [AskMachine]) -> [AskMachine] {
        let store = load()
        return machines.filter { machine in
            guard let dateStr = store[machine.id],
                  let tombstoneDate = formatter.date(from: dateStr)
            else { return true }
            if machine.lastHeartbeat > tombstoneDate {
                clear(machineID: machine.id)
                return true
            }
            return false
        }
    }

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

// MARK: - Navigation value for session chat

/// Carries enough context to render SessionChatView even after the live block disappears.
struct AgentSessionNavValue: Hashable {
    let blockID: String
    let sessionID: String
    let project: String
    let machineID: String
}

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

    /// All agent session payloads for this script.
    private var agentSessions: [RKAgentSessionPayload] {
        blocks.compactMap { $0.blockType == .agentSession ? $0.agentSessionPayload : nil }
    }

    /// Action required only when a script explicitly sets action_required: true in its tile block.
    var isActionRequired: Bool { tileBlock?.actionRequired == true }

    /// Short status label: tile > status block > agent session count.
    var tileLabel: String? {
        if let label = tileBlock?.label { return label }
        if let label = blocks.first(where: { $0.blockType == .status })?.statusPayload?.label { return label }
        let sessions = agentSessions
        guard !sessions.isEmpty else { return nil }
        let working = sessions.filter { $0.isWorking == true }.count
        let count = sessions.count
        let noun = count == 1 ? "session" : "sessions"
        if working > 0 {
            return working == count ? "\(count) \(noun) working" : "\(count) \(noun), \(working) working"
        }
        return "\(count) \(noun)"
    }

    /// Status color: tile > status block > blue when working, gray otherwise.
    var tileStatusColor: String? {
        if let c = tileBlock?.statusColor { return c }
        if let c = blocks.first(where: { $0.blockType == .status })?.statusPayload?.color { return c }
        let sessions = agentSessions
        guard !sessions.isEmpty else { return nil }
        return sessions.contains(where: { $0.isWorking == true }) ? "blue" : "gray"
    }

    /// Body text: tile block > most recent agent session last message (first line).
    var tileBody: String? {
        if let body = tileBlock?.body { return body }
        let sessions = agentSessions
        let active = sessions.first(where: { $0.isWorking == true }) ?? sessions.first
        if let msg = active?.lastMessage, !msg.isEmpty {
            let firstLine = msg.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? msg
            return String(firstLine.prefix(120))
        }
        return nil
    }

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

    /// Number of distinct machines contributing blocks to this group.
    var machineCount: Int {
        Set(blocks.map { $0.machineID }).count
    }

    /// The highest urgency among inbox blocks in this group (with defaults applied).
    /// Uses showsInInbox rather than requiresResponse so idle agentSession blocks are excluded.
    var dominantUrgency: RKUrgency? {
        blocks
            .filter { $0.showsInInbox }
            .compactMap { $0.effectiveUrgency }
            .min(by: { $0.sortRank < $1.sortRank })
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(ActionInboxStore.self) private var actionInbox
    @Environment(TaskHistoryStore.self) private var taskHistory
    @Environment(\.scenePhase) private var scenePhase

    @State private var machines: [AskMachine] = []
    @State private var blocks: [RKBlock] = []

    @State private var hasLoaded = false
    @State private var fetchFailed = false
    /// nil = show all machines; a machineID = filter to that machine only.
    @State private var machineFilter: String?
    @State private var showSettings = false
    /// Comma-separated machineIDs to exclude from the home screen (persisted).
    @AppStorage("hiddenMachineIDs") private var hiddenMachineIDsRaw: String = ""
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
    @State private var showQueueReview: Bool = false
    @State private var wasOffline: Bool = false
    @State private var selectedTab: HomeTab = .home

    @Environment(\.modelContext) private var modelContext
    /// Machine picker state — shown when a multi-machine quick_reply group has > 5 machines.
    @State private var machinePickerTargets: [RKBlock]? = nil
    @State private var machinePickerValue: String? = nil

    private var offlineQueue: OfflineQueue { .shared }

    enum HomeTab: Hashable { case home, feed }

    private var hiddenMachineIDs: Set<String> {
        Set(hiddenMachineIDsRaw.split(separator: ",").map(String.init))
    }

    /// Machines currently shown (not hidden).
    private var visibleMachines: [AskMachine] {
        machines.filter { !hiddenMachineIDs.contains($0.id) }
    }

    /// True if every visible machine is offline (used to decide whether to queue responses).
    private func machineIsOffline(_ machineID: String) -> Bool {
        machines.first { $0.id == machineID }?.connectionStatus == .offline
    }

    /// Updates machine lastHeartbeat using block createdAt timestamps.
    /// Scripts can run without AskMac.app running (e.g. via launchd), so recent blocks
    /// prove the machine is active even if the Machine record's heartbeat is stale.
    private func refreshMachineHeartbeats(from blocks: [RKBlock]) {
        var latestByMachine: [String: Date] = [:]
        for block in blocks {
            let current = latestByMachine[block.machineID]
            if current == nil || block.createdAt > current! {
                latestByMachine[block.machineID] = block.createdAt
            }
        }
        for i in 0..<machines.count {
            let id = machines[i].id
            if let latestBlock = latestByMachine[id],
               latestBlock > machines[i].lastHeartbeat {
                machines[i].lastHeartbeat = latestBlock
            }
        }
    }

    private var scriptGroups: [ScriptGroup] {
        let grouped = Dictionary(grouping: blocks, by: { $0.scriptID })
        return grouped.keys.sorted { a, b in
            if a == "claudecode-controller" { return true }
            if b == "claudecode-controller" { return false }
            return a < b
        }.map { ScriptGroup(scriptID: $0, blocks: grouped[$0] ?? []) }
    }

    /// Groups that need user action: either an explicit inbox block (confirmation, prompt, quick_reply, etc.)
    /// or a tile that set action_required: true. Uses showsInInbox rather than requiresResponse so that
    /// idle agentSession blocks — which are requiresResponse but never showsInInbox — don't flood the queue.
    private var needsResponseGroups: [ScriptGroup] {
        scriptGroups
            .filter { $0.blocks.contains(where: { $0.showsInInbox }) || $0.isActionRequired }
            .sorted { a, b in
                let aRank = a.dominantUrgency?.sortRank ?? 3
                let bRank = b.dominantUrgency?.sortRank ?? 3
                if aRank != bRank { return aRank < bRank }
                let aDate = a.blocks.filter(\.showsInInbox).map(\.createdAt).min() ?? .distantFuture
                let bDate = b.blocks.filter(\.showsInInbox).map(\.createdAt).min() ?? .distantFuture
                return aDate < bDate
            }
    }

    /// Groups with no inbox blocks and no tile action_required — informational/status only.
    private var recentGroups: [ScriptGroup] {
        scriptGroups
            .filter { !$0.blocks.contains(where: { $0.showsInInbox }) && !$0.isActionRequired }
            .sorted {
                ($0.blocks.map(\.createdAt).max() ?? .distantPast) >
                ($1.blocks.map(\.createdAt).max() ?? .distantPast)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cloudKit.accountStatus == .noAccount || cloudKit.accountStatus == .restricted {
                    iCloudSignInState
                } else if !hasLoaded {
                    // Empty view — the loading overlay is shown via .overlay below
                    Color.clear
                } else if machines.isEmpty && fetchFailed {
                    fetchFailedState
                } else if machines.isEmpty {
                    emptyState
                } else if selectedTab == .feed {
                    TaskFeedView(machines: visibleMachines)
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
                    machines: machines
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
                .environment(taskHistory)
        }
        .sheet(
            isPresented: Binding(
                get: { machinePickerTargets != nil },
                set: { if !$0 { machinePickerTargets = nil; machinePickerValue = nil } }
            )
        ) {
            if let targets = machinePickerTargets, let value = machinePickerValue {
                MachinePickerSheet(targets: targets, machines: machines, value: value) { selected in
                    let capturedValue = value
                    machinePickerTargets = nil
                    machinePickerValue = nil
                    for block in selected {
                        Task { await respondToBlock(block, value: capturedValue) }
                    }
                }
            }
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
                if needsResponseGroups.isEmpty && recentGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Active Scripts", systemImage: "terminal")
                    } description: {
                        Text("Scripts will appear here when they emit blocks.")
                    }
                    .padding(.top, 40)
                } else {
                    // Needs Response section
                    if !needsResponseGroups.isEmpty {
                        queueSectionHeader("Needs Response", count: needsResponseGroups.count)
                        LazyVStack(spacing: 8) {
                            ForEach(needsResponseGroups) { group in
                                ActionQueueCardView(
                                    group: group,
                                    onTap: { selectedScriptID = group.scriptID },
                                    onRespond: { value in await respondToGroup(group, value: value) }
                                )
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("script-group-\(group.scriptID)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }

                    // Recent section
                    if !recentGroups.isEmpty {
                        queueSectionHeader("Recent", count: nil)
                        VStack(spacing: 8) {
                            ForEach(recentGroups) { group in
                                ScriptTileView(group: group) { selectedScriptID = group.scriptID }
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("script-group-\(group.scriptID)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .animation(.easeOut(duration: 0.25), value: needsResponseGroups.map(\.scriptID))
            .animation(.easeOut(duration: 0.25), value: recentGroups.map(\.scriptID))
        }
        .refreshable { await load() }
    }

    private func queueSectionHeader(_ title: String, count: Int?) -> some View {
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
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
            NotificationBellButton()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(.systemBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
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
            Button {
                machineFilter = nil
                Task { await load() }
            } label: {
                if machineFilter == nil {
                    Label("All Machines", systemImage: "checkmark")
                } else {
                    Text("All Machines")
                }
            }
            Divider()
            ForEach(visibleMachines) { machine in
                Button {
                    machineFilter = machine.id
                    Task { await load() }
                } label: {
                    if machineFilter == machine.id {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Label(machine.name, systemImage: machine.systemImage)
                    }
                }
            }
        } label: {
            if let id = machineFilter, let machine = machines.first(where: { $0.id == id }) {
                Image(systemName: machine.systemImage)
                    .foregroundStyle(machine.connectionStatus == .offline ? .secondary : .primary)
            } else {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.primary)
            }
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

    private var fetchFailedState: some View {
        ContentUnavailableView {
            Label("iCloud Unavailable", systemImage: "icloud.slash")
        } description: {
            Text("Could not reach iCloud. This is usually temporary — please try again in a moment.")
        } actions: {
            Button("Try Again") { Task { await load() } }
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
            let fresh = try await cloudKit.fetchMachines()
            machines = MachineTombstoneStore.apply(to: fresh)
            fetchFailed = false
        } catch {
            print("[HomeView] Failed to fetch machines: \(error)")
            fetchFailed = machines.isEmpty
        }

        // Fetch blocks from all visible machines in parallel.
        var allFetched: [RKBlock] = []
        var anySucceeded = false
        await withTaskGroup(of: (String, [RKBlock]).self) { group in
            for machine in visibleMachines {
                group.addTask {
                    let enabled = await self.cloudKit.checkDeviceEnabled(machineID: machine.id)
                    guard enabled else { return (machine.id, []) }
                    let fetched = (try? await self.cloudKit.fetchBlocks(machineID: machine.id)) ?? []
                    return (machine.id, fetched)
                }
            }
            for await (machineID, machineBlocks) in group {
                if !machineBlocks.isEmpty { anySucceeded = true }
                allFetched.append(contentsOf: machineBlocks)
                actionInbox.replace(machineID: machineID, blocks: machineBlocks)
            }
        }

        // Use block createdAt as a fallback heartbeat — scripts can run without the Mac app,
        // so recent blocks prove machine activity even when the Machine record is stale.
        refreshMachineHeartbeats(from: allFetched)

        let filtered = allFetched
            .filter { !$0.isFeedBlock || $0.requiresResponse }
            .filter { UITestingSupport.isUITesting || $0.blockType != .alert }
            .filter { $0.blockType != .activityFeed }
            .filter { $0.blockType != .sessionEvent }

        // Apply optional machine filter
        let display = machineFilter.map { id in filtered.filter { $0.machineID == id } } ?? filtered

        withAnimation(.easeOut(duration: 0.25)) { blocks = display }

        if !machines.isEmpty && Date().timeIntervalSince(lastHeartbeatAt) > 1800 {
            await cloudKit.saveDeviceHeartbeat(machineIDs: machines.map { $0.id })
            lastHeartbeatAt = Date()
        }
        hasLoaded = true

        let cacheGroups = scriptGroups.map {
            (id: $0.scriptID, name: $0.name, sfSymbol: $0.icon, iconData: $0.iconData)
        }
        if anySucceeded {
            iconCache.reconcile(to: cacheGroups)
        } else {
            iconCache.update(from: cacheGroups)
        }
        notifyNewActionGroups()
    }

    private func notifyNewActionGroups() {
        let allCurrentBlockIDs = Set(blocks.map { $0.id })

        for group in needsResponseGroups {
            // Prefer explicit confirmation/prompt/quickReply blocks; fall back to the tile block.
            let triggerBlocks: [RKBlock]
            let explicit = group.blocks.filter {
                $0.blockType == .confirmation || $0.blockType == .prompt || $0.blockType == .quickReply
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
                let interval: Double = Date() < burstPollingUntil ? 1.0 : 15.0
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                if let fresh = try? await cloudKit.fetchMachines(), !fresh.isEmpty {
                    machines = fresh
                    fetchFailed = false
                }

                // Detect any machine coming back online — show queue review if needed.
                let nowOffline = visibleMachines.allSatisfy { $0.connectionStatus == .offline }
                if wasOffline && !nowOffline && !offlineQueue.isEmpty {
                    showQueueReview = true
                }
                wasOffline = nowOffline

                // Fetch blocks from all visible machines in parallel.
                var allFetched: [RKBlock] = []
                await withTaskGroup(of: (String, [RKBlock]).self) { group in
                    for machine in visibleMachines {
                        group.addTask {
                            let enabled = await self.cloudKit.checkDeviceEnabled(machineID: machine.id)
                            guard enabled else { return (machine.id, []) }
                            let fetched = (try? await self.cloudKit.fetchBlocks(machineID: machine.id)) ?? []
                            return (machine.id, fetched)
                        }
                    }
                    for await (machineID, machineBlocks) in group {
                        allFetched.append(contentsOf: machineBlocks)
                        actionInbox.replace(machineID: machineID, blocks: machineBlocks)
                    }
                }

                refreshMachineHeartbeats(from: allFetched)

                let filtered = allFetched
                    .filter { !$0.isFeedBlock || $0.requiresResponse }
                    .filter { UITestingSupport.isUITesting || $0.blockType != .alert }
                    .filter { $0.blockType != .activityFeed }
                    .filter { $0.blockType != .sessionEvent }

                let display = machineFilter.map { id in filtered.filter { $0.machineID == id } } ?? filtered

                if display.isEmpty {
                    consecutiveEmpty += 1
                    if consecutiveEmpty >= 2 {
                        withAnimation(.easeOut(duration: 0.25)) { blocks = display }
                    }
                } else {
                    consecutiveEmpty = 0
                    withAnimation(.easeOut(duration: 0.25)) { blocks = display }
                }
            }
        }
    }

    private func respondToBlock(_ block: RKBlock, value: String) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // If the block's machine is offline, queue the response for later review.
        if machineIsOffline(block.machineID) {
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
        case .confirmation, .prompt, .picker, .detail, .quickReply: shouldRemove = true
        default: shouldRemove = false
        }

        if shouldRemove {
            saveRespondedBlockToHistory(block)
            withAnimation(.easeOut(duration: 0.22)) {
                blocks.removeAll { $0.id == block.id }
            }
        }

        if block.requiresResponse {
            burstPollingUntil = Date().addingTimeInterval(8)
        }

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
    /// Responds to a quick_reply block across all machines in a group.
    /// If there are > 5 target machines, shows a picker instead of responding to all.
    private func respondToGroup(_ group: ScriptGroup, value: String) async {
        // Deduplicate: one quick_reply block per machine (most recent).
        let byMachine = Dictionary(grouping: group.blocks.filter { $0.blockType == .quickReply },
                                   by: { $0.machineID })
        let targets = byMachine.values.compactMap { $0.max(by: { $0.createdAt < $1.createdAt }) }

        if targets.count > 5 {
            machinePickerTargets = targets
            machinePickerValue = value
            return
        }
        for block in targets {
            await respondToBlock(block, value: value)
        }
    }

    private func saveRespondedBlockToHistory(_ block: RKBlock) {
        let entry = FeedHistoryEntry(
            blockID:       block.id,
            scriptID:      block.scriptID,
            scriptName:    block.scriptName,
            scriptIcon:    block.scriptIcon,
            scriptIconData: block.scriptIconData,
            blockTypeRaw:  block.blockType.rawValue,
            headline:      block.feedHeadline,
            statusColor:   block.feedStatusColor,
            payloadJSON:   block.payloadJSON,
            createdAt:     block.createdAt
        )
        modelContext.insert(entry)
        try? modelContext.save()
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
        Group {
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

                if group.machineCount > 1 {
                    Text("\(group.machineCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }

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
        } // Group
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

// MARK: - Action queue card

/// Card for the "Needs Response" section. Shows urgency badge, machine count, and—for
/// quick_reply groups—inline response buttons. All other group types tap to navigate.
private struct ActionQueueCardView: View {
    let group: ScriptGroup
    let onTap: () -> Void
    let onRespond: (String) async -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true

    /// The quick_reply block to render inline, if any (highest urgency, then most recent).
    private var quickReplyBlock: RKBlock? {
        group.blocks
            .filter { $0.blockType == .quickReply }
            .max { a, b in
                let aRank = a.effectiveUrgency?.sortRank ?? 3
                let bRank = b.effectiveUrgency?.sortRank ?? 3
                if aRank != bRank { return aRank > bRank }   // lower rank = higher priority
                return a.createdAt < b.createdAt
            }
    }

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
        VStack(alignment: .leading, spacing: 0) {
            // Script header row — always tappable
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
                            .font(.subheadline.weight(.semibold))
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
                    }

                    Spacer()

                    // Urgency badge
                    if let urgency = group.dominantUrgency {
                        UrgencyBadgeView(urgency: urgency)
                    }

                    // Machine count badge
                    if group.machineCount > 1 {
                        Text("\(group.machineCount) machines")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }

                    // Chevron for non-quick_reply groups
                    if quickReplyBlock == nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Inline quick_reply content
            if let block = quickReplyBlock, let payload = block.quickReplyPayload {
                Divider()
                    .padding(.horizontal, 14)

                QuickReplyBlockView(payload: payload, onRespond: onRespond)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(effectiveBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    (effectiveHighlight ?? urgencyBorderColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .environment(\.colorScheme, effectiveColorScheme)
    }

    private var urgencyBorderColor: Color {
        switch group.dominantUrgency {
        case .urgent:  return .red
        case .warning: return .orange
        case .info:    return Color(.separator)
        case nil:      return .orange
        }
    }
}

// MARK: - Machine picker sheet

private struct MachinePickerSheet: View {
    let targets: [RKBlock]
    let machines: [AskMachine]
    let value: String
    let onConfirm: ([RKBlock]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMachineIDs: Set<String> = []

    private func machineName(for machineID: String) -> String {
        machines.first { $0.id == machineID }?.name ?? machineID
    }

    var body: some View {
        NavigationStack {
            List(targets, id: \.machineID) { block in
                Button {
                    if selectedMachineIDs.contains(block.machineID) {
                        selectedMachineIDs.remove(block.machineID)
                    } else {
                        selectedMachineIDs.insert(block.machineID)
                    }
                } label: {
                    HStack {
                        Image(systemName: selectedMachineIDs.contains(block.machineID)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedMachineIDs.contains(block.machineID)
                                             ? Color.accentColor : Color.secondary)
                        Text(machineName(for: block.machineID))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Select Machines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send to \(selectedMachineIDs.count)") {
                        let selected = targets.filter { selectedMachineIDs.contains($0.machineID) }
                        onConfirm(selected)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedMachineIDs.isEmpty)
                }
            }
            .onAppear {
                // Pre-select all machines for convenience
                selectedMachineIDs = Set(targets.map(\.machineID))
            }
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
    @Environment(\.modelContext) private var modelContext
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true

    // Detail-push navigation state (for list→detail block pattern)
    @State private var isShowingDetail = false
    @State private var pushedDetail: RKBlock? = nil
    @State private var detailSentResponse = false
    @State private var dismissedDetailBlockID: String? = nil
    @State private var showRepoPicker = false

    // Cached icon/name — survives block clearing during restarts
    @State private var cachedIconSF: String = "terminal.fill"
    @State private var cachedIconSVG: String? = nil
    @State private var cachedIconData: String? = nil
    @State private var cachedName: String = ""

    @State private var restartBobOffset: CGFloat = 0
    @State private var hadSessions: Bool = false
    /// Block IDs of confirmations the user has already responded to locally.
    /// Prevents re-rendering if the block briefly reappears before the Mac removes it.
    @State private var respondedConfirmationIDs: Set<String> = []

    private var group: ScriptGroup {
        ScriptGroup(scriptID: scriptID, blocks: allBlocks.filter { $0.scriptID == scriptID && $0.blockType != .tile })
    }

    private var brandGroup: ScriptGroup {
        ScriptGroup(scriptID: scriptID, blocks: allBlocks.filter { $0.scriptID == scriptID })
    }

    private var scriptDisplayName: String {
        allBlocks.first { $0.scriptID == scriptID }?.scriptName
            ?? scriptID.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private var scriptIconSF: String {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIcon != nil })?.scriptIcon ?? cachedIconSF
    }
    private var scriptIconSVG: String? {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIconSVG != nil })?.scriptIconSVG ?? cachedIconSVG
    }
    private var scriptIconData: String? {
        allBlocks.first(where: { $0.scriptID == scriptID && $0.scriptIconData != nil })?.scriptIconData ?? cachedIconData
    }

    private var startSessionBlock: RKBlock? {
        group.blocks.first { $0.blockType == .startSession }
    }

    /// agent_session blocks — each becomes a row in the session list.
    private var sessionBlocks: [RKBlock] {
        group.blocks.filter { $0.blockType == .agentSession }
    }

    /// Non-session, non-tile, non-feed blocks shown in the header strip above sessions.
    private var headerBlocks: [RKBlock] {
        let liveSessionIDs = Set(sessionBlocks.compactMap { $0.agentSessionPayload?.sessionId })
        return group.blocks.filter {
            $0.blockType != .agentSession &&
            $0.blockType != .tile &&
            $0.blockType != .startSession &&
            $0.blockType != .feedItem &&
            $0.blockType != .detail &&
            $0.blockType != .diagnostics &&  // lives on log page, not detail view
            // Confirmation blocks with a live sessionId are shown inline under their session.
            // Orphaned confirmations still belong in the header so they remain actionable.
            !($0.blockType == .confirmation &&
              ($0.confirmationPayload?.sessionId).map { liveSessionIDs.contains($0) } == true)
        }
    }

    private var isEmpty: Bool { headerBlocks.isEmpty && sessionBlocks.isEmpty }

    private var currentDetailBlock: RKBlock? { group.blocks.first { $0.blockType == .detail } }

    private func sessionConfirmations(for sessionId: String) -> [RKBlock] {
        group.blocks.filter {
            $0.blockType == .confirmation && $0.confirmationPayload?.sessionId == sessionId
        }
    }

    /// Persists an assistant message into ChatEntry so history is available even when
    /// SessionChatView was not open when the message arrived.
    private func seedAssistantMessageToChatEntry(msg: String, sessionId: String) {
        let descriptor = FetchDescriptor<ChatEntry>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.role == "assistant" && $0.text == msg }
        )
        guard (try? modelContext.fetch(descriptor))?.isEmpty ?? true else { return }
        modelContext.insert(ChatEntry(
            sessionId: sessionId,
            role: "assistant",
            entryKind: "message",
            text: msg
        ))
        try? modelContext.save()
    }

    /// Persists a session-linked confirmation block into ChatEntry so it's visible in Chat
    /// even after the block is cleared from CloudKit before the user navigates there.
    private func seedConfirmationToChatEntry(block: RKBlock, sessionId: String) {
        let blockID = block.id
        let descriptor = FetchDescriptor<ChatEntry>(
            predicate: #Predicate { $0.blockID == blockID }
        )
        guard (try? modelContext.fetch(descriptor))?.isEmpty ?? true else { return }
        let title = block.confirmationPayload?.title ?? "Request"
        modelContext.insert(ChatEntry(
            sessionId: sessionId,
            role: "system",
            entryKind: "inlineBlock",
            text: title,
            blockID: block.id,
            blockJSON: block.payloadJSON
        ))
        try? modelContext.save()
    }

    var body: some View {
        NavigationStack {
            List {
                // Header strip: non-session blocks (status, countdown, info cards, etc.)
                ForEach(headerBlocks) { block in
                    Section {
                        BlockView(block: block, onRespond: { value in
                            await onRespond(block, value)
                        }, isWaiting: isWaiting)
                        .accessibilityElement(children: .contain)
                    }
                }

                // Session list
                if !sessionBlocks.isEmpty {
                    Section("Sessions") {
                        ForEach(sessionBlocks) { block in
                            if let payload = block.agentSessionPayload {
                                let confs = sessionConfirmations(for: payload.sessionId)
                                    .filter { !respondedConfirmationIDs.contains($0.id) }
                                let confCount = confs.count
                                NavigationLink(value: AgentSessionNavValue(blockID: block.id, sessionID: payload.sessionId, project: payload.project, machineID: block.machineID)) {
                                    SessionRowView(
                                        payload: payload,
                                        confirmationCount: confCount
                                    )
                                }
                                .listRowBackground(
                                    confCount > 0
                                        ? Color.orange.opacity(0.07)
                                        : nil
                                )
                                ForEach(confs) { confBlock in
                                    BlockView(block: confBlock, onRespond: { value in
                                        respondedConfirmationIDs.insert(confBlock.id)
                                        await onRespond(confBlock, value)
                                    })
                                    .listRowBackground(Color.orange.opacity(0.05))
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 5, trailing: 16))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(useBrandColors ? (brandGroup.brandBackground ?? Color(.systemGroupedBackground)) : Color(.systemGroupedBackground))
            .overlay { if isEmpty && !hadSessions { restartingOverlay } }
            .onChange(of: sessionBlocks.isEmpty) { _, nowEmpty in
                if !nowEmpty { hadSessions = true }
                if nowEmpty && hadSessions {
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        dismiss()
                    }
                }
            }
            .onChange(of: allBlocks.map(\.id)) { _, _ in
                // Persist any session-linked confirmation blocks to ChatEntry as soon as
                // they appear in allBlocks, so Chat has a record even if the block is
                // cleared before the user navigates there.
                for block in group.blocks where block.blockType == .confirmation {
                    guard let sessionId = block.confirmationPayload?.sessionId else { continue }
                    seedConfirmationToChatEntry(block: block, sessionId: sessionId)
                }
            }
            .onChange(of: sessionBlocks.compactMap { $0.agentSessionPayload?.lastMessage }) { _, messages in
                // Persist assistant messages immediately when they arrive, even if SessionChatView
                // is not open. This prevents blank chat history when the user opens the view later.
                for block in sessionBlocks {
                    guard let payload = block.agentSessionPayload,
                          let msg = payload.lastMessage, !msg.isEmpty
                    else { continue }
                    seedAssistantMessageToChatEntry(msg: msg, sessionId: payload.sessionId)
                }
            }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: ScriptLogView(
                        scriptID: scriptID,
                        diagnosticsBlock: group.blocks.first { $0.blockType == .diagnostics },
                        onRespond: onRespond
                    )) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { detailBottomBar }
            .sheet(isPresented: $showRepoPicker) {
                if let block = startSessionBlock, let payload = block.startSessionPayload {
                    RepoPickerSheet(repos: payload.repos) { repo in
                        showRepoPicker = false
                        Task { await onRespond(block, repo.path) }
                    }
                }
            }
            // Session chat navigation
            .navigationDestination(for: AgentSessionNavValue.self) { nav in
                let livePayload = allBlocks.first(where: { $0.id == nav.blockID })?.agentSessionPayload
                if scriptID == "codex-3" {
                    SessionFeedView(
                        sessionBlockID: nav.blockID,
                        sessionID: nav.sessionID,
                        project: nav.project,
                        livePayload: livePayload,
                        allBlocks: allBlocks,
                        scriptID: scriptID,
                        machineID: nav.machineID,
                        onRespond: onRespond
                    )
                } else {
                    SessionChatView(
                        sessionBlockID: nav.blockID,
                        sessionID: nav.sessionID,
                        project: nav.project,
                        livePayload: livePayload,
                        allBlocks: allBlocks,
                        scriptID: scriptID,
                        machineID: nav.machineID,
                        onRespond: onRespond
                    )
                }
            }
            // Detail block push (list→detail pattern)
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
                guard id != dismissedDetailBlockID else { return }
                guard pushedDetail?.id != id else { return }
                pushedDetail = currentDetailBlock
                detailSentResponse = false
                dismissedDetailBlockID = nil
                isShowingDetail = true
            } else {
                if isShowingDetail {
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
                if let block = pushedDetail {
                    let swipedID = block.id
                    dismissedDetailBlockID = swipedID
                    Task { await onRespond(block, "dismissed") }
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
        .onAppear { seedIconCache() }
        .onChange(of: allBlocks.count) { _, _ in seedIconCache() }
    }

    private func seedIconCache() {
        guard let block = allBlocks.first(where: { $0.scriptID == scriptID }) else { return }
        cachedName = block.scriptName ?? cachedName
        if let sf = block.scriptIcon    { cachedIconSF   = sf }
        if let sv = block.scriptIconSVG { cachedIconSVG  = sv }
        if let d  = block.scriptIconData { cachedIconData = d }
    }

    private var restartingOverlay: some View {
        VStack(spacing: 20) {
            ScriptIconView(
                svgString: scriptIconSVG,
                iconData: scriptIconData,
                sfSymbol: scriptIconSF
            )
            .frame(width: 56, height: 56)
            .offset(y: startSessionBlock != nil ? 0 : restartBobOffset)
            .onAppear {
                if startSessionBlock == nil {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                        restartBobOffset = -10
                    }
                }
            }
            .onDisappear { restartBobOffset = 0 }

            if startSessionBlock != nil {
                VStack(spacing: 6) {
                    Text("No active sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to start a new session")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Script restarting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(useBrandColors ? (brandGroup.brandBackground ?? Color(.systemGroupedBackground)) : Color(.systemGroupedBackground))
    }

    private var detailBottomBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                Button { dismiss() } label: {
                    Text("Home")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

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

                NotificationBellButton()

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

    @Environment(\.dismiss) private var dismiss
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
                Button("Close") {
                    dismiss()
                    onClose()
                }
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

// MARK: - Settings sheet

struct SettingsSheetView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(TaskHistoryStore.self) private var taskHistory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showBlockDebugInfo") private var showDebugInfo: Bool = false
    @AppStorage("useBrandColors") private var useBrandColors: Bool = true
    @AppStorage("hiddenMachineIDs") private var hiddenMachineIDsRaw: String = ""
    @State private var machines: [AskMachine] = []
    @State private var showQueueReview = false
    @State private var machineToDelete: AskMachine?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showClearAllTasksConfirm = false

    @Query(sort: \TaskRecord.lastActivityAt, order: .reverse)
    private var taskRecords: [TaskRecord]

    private var hiddenMachineIDs: Set<String> {
        Set(hiddenMachineIDsRaw.split(separator: ",").map(String.init))
    }

    private func toggleHidden(_ machine: AskMachine) {
        var ids = hiddenMachineIDs
        if ids.contains(machine.id) { ids.remove(machine.id) } else { ids.insert(machine.id) }
        hiddenMachineIDsRaw = ids.joined(separator: ",")
    }

    private func deleteMachine(_ machine: AskMachine) {
        machineToDelete = machine
        showDeleteConfirm = true
    }

    private func confirmDelete() async {
        guard let machine = machineToDelete else { return }
        isDeleting = true
        MachineTombstoneStore.record(machineID: machine.id)
        await cloudKit.deleteMachine(machineID: machine.id)
        machines.removeAll { $0.id == machine.id }
        // Also remove from hidden list if present
        var ids = hiddenMachineIDs
        ids.remove(machine.id)
        hiddenMachineIDsRaw = ids.joined(separator: ",")
        isDeleting = false
        machineToDelete = nil
    }

    private var queue: OfflineQueue { .shared }

    // MARK: - Task History section

    /// Groups task records by (machineID, scriptID) for display.
    private var taskHistoryGroups: [(machineID: String, scriptID: String, scriptName: String, count: Int, latest: Date)] {
        var groups: [String: (machineID: String, scriptID: String, scriptName: String, count: Int, latest: Date)] = [:]
        for task in taskRecords {
            let key = "\(task.machineID)/\(task.scriptID)"
            if var g = groups[key] {
                g.count += 1
                if task.lastActivityAt > g.latest { g.latest = task.lastActivityAt }
                groups[key] = g
            } else {
                groups[key] = (task.machineID, task.scriptID, task.scriptName, 1, task.lastActivityAt)
            }
        }
        return groups.values.sorted { $0.latest > $1.latest }
    }

    @ViewBuilder
    private var taskHistorySection: some View {
        if !taskRecords.isEmpty {
            Section {
                ForEach(taskHistoryGroups, id: \.scriptID) { group in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.scriptName)
                                .font(.subheadline)
                            Text("\(group.count) task\(group.count == 1 ? "" : "s") · \(group.latest.briefRelative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? taskHistory.clearHistory(machineID: group.machineID, scriptID: group.scriptID)
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                }
                Button(role: .destructive) {
                    showClearAllTasksConfirm = true
                } label: {
                    Label("Clear All Task History", systemImage: "trash")
                }
            } header: {
                Text("Task History")
            } footer: {
                Text("Stored locally. Swipe a script to clear its task history.")
            }
            .confirmationDialog("Clear All Task History?", isPresented: $showClearAllTasksConfirm, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) {
                    try? taskHistory.clearAllHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all stored task history and downloaded files from this device.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(machines) { machine in
                        NavigationLink {
                            MachineDetailView(machine: machine)
                                .environment(cloudKit)
                        } label: {
                            HStack {
                                MachineRow(machine: machine)
                                Spacer()
                                if hiddenMachineIDs.contains(machine.id) {
                                    Image(systemName: "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteMachine(machine)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                toggleHidden(machine)
                            } label: {
                                let isHidden = hiddenMachineIDs.contains(machine.id)
                                Label(isHidden ? "Show" : "Hide",
                                      systemImage: isHidden ? "eye" : "eye.slash")
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Swipe left to hide a machine from the home screen, or delete its CloudKit records. A running Mac re-registers within 30 seconds.")
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

                taskHistorySection

                Section("Appearance") {
                    Toggle("Script Brand Colors", isOn: $useBrandColors)
                }

                Section("Developer") {
                    Toggle("Show Debug Info on Cards", isOn: $showDebugInfo)
                    LabeledContent("CloudKit Environment") {
                        #if DEBUG
                        Text("Development")
                            .foregroundStyle(.orange)
                        #else
                        Text("Production")
                            .foregroundStyle(.green)
                        #endif
                    }
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
            }
            .sheet(isPresented: $showQueueReview) {
                QueueReviewSheet(isPresented: $showQueueReview)
                    .environment(cloudKit)
            }
            .confirmationDialog(
                "Delete \"\(machineToDelete?.name ?? "")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Machine & Blocks", role: .destructive) {
                    Task { await confirmDelete() }
                }
                Button("Cancel", role: .cancel) { machineToDelete = nil }
            } message: {
                Text("This removes the machine record and all its blocks from iCloud. A running Mac re-registers within 30 seconds.")
            }
            .overlay {
                if isDeleting {
                    ProgressView("Deleting…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
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

// MARK: - Script Log Page

struct ScriptLogView: View {
    let scriptID: String
    let diagnosticsBlock: RKBlock?
    let onRespond: (RKBlock, String) async -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var diag: RKDiagnosticsPayload? { diagnosticsBlock?.diagnosticsPayload }

    var body: some View {
        List {
            // ── Diagnostics ──────────────────────────────────────────────
            Section("Diagnostics") {
                if let d = diag {
                    LabeledContent("Version", value: d.version)
                    LabeledContent("Socket") {
                        Label(d.socketOk ? "Listening" : "Not found",
                              systemImage: d.socketOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(d.socketOk ? .green : .red)
                            .font(.subheadline)
                    }
                    LabeledContent("Hooks") {
                        Label(d.hooksOk ? "All registered" : "Problems found",
                              systemImage: d.hooksOk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(d.hooksOk ? .green : .orange)
                            .font(.subheadline)
                    }
                    if !d.hooksOk {
                        ForEach(d.hooks) { hook in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: hook.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(hook.ok ? .green : .red)
                                    .font(.caption)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hook.event)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(hook.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 4, trailing: 16))
                        }
                    }
                } else {
                    Text("No diagnostics received yet")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            // ── Collect Logs ─────────────────────────────────────────────
            Section {
                if let block = diagnosticsBlock {
                    Button {
                        Task { await onRespond(block, "collect_logs") }
                    } label: {
                        Label("Collect Logs (last 24h)", systemImage: "archivebox")
                    }
                } else {
                    Text("Waiting for script to connect…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } footer: {
                Text("Zips all script logs from the last 24 hours and saves to ~/Downloads on the Mac.")
            }

            // ── Recent log lines ─────────────────────────────────────────
            if let lines = diag?.logLines, !lines.isEmpty {
                Section("Recent Logs") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
