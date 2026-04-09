import SwiftUI
import CloudKit
import SwiftData
import Charts

// MARK: - Shared palette & helpers

private let feedPalette: [Color] = [
    Color(hue: 0.60, saturation: 0.7, brightness: 0.80),
    Color(hue: 0.95, saturation: 0.6, brightness: 0.80),
    Color(hue: 0.13, saturation: 0.8, brightness: 0.85),
    Color(hue: 0.35, saturation: 0.6, brightness: 0.70),
    Color(hue: 0.75, saturation: 0.55, brightness: 0.80),
    Color(hue: 0.05, saturation: 0.7, brightness: 0.80),
]

/// Ordered unique scriptIDs from history, oldest-first — gives stable color assignment.
private func orderedScriptIDs(from history: [FeedHistoryEntry]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for entry in history.sorted(by: { $0.createdAt < $1.createdAt }) {
        if seen.insert(entry.scriptID).inserted { ordered.append(entry.scriptID) }
    }
    return ordered
}

private func feedColor(for scriptID: String, orderedIDs: [String]) -> Color {
    let idx = orderedIDs.firstIndex(of: scriptID) ?? 0
    return feedPalette[idx % feedPalette.count]
}

/// Relative time: minutes → hours → days, no seconds.
private func coarseRelativeTime(_ date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 0 { return "just now" }
    let mins = secs / 60
    if mins < 1  { return "just now" }
    if mins < 60 { return "\(mins) min" }
    let hrs = mins / 60
    if hrs  < 24 { return "\(hrs) hr" }
    return "\(hrs / 24) d"
}

/// Relative time with hr+min detail for the detail view.
private func detailedRelativeTime(_ date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 0 { return "just now" }
    let mins = secs / 60
    if mins < 1  { return "just now" }
    if mins < 60 { return "\(mins) min" }
    let hrs = mins / 60
    let rem = mins % 60
    if hrs < 24 { return rem > 0 ? "\(hrs) hr, \(rem) min" : "\(hrs) hr" }
    return "\(hrs / 24) d"
}

// MARK: - Display item model

private enum FeedDisplayItem: Identifiable {
    case single(FeedHistoryEntry)
    case burst(scriptID: String, scriptName: String?, iconData: String?, icon: String?,
               entries: [FeedHistoryEntry])

    var id: String {
        switch self {
        case .single(let e):          return e.blockID
        case .burst(_, _, _, _, let entries): return "burst-\(entries.first?.blockID ?? UUID().uuidString)"
        }
    }
}

private struct BurstSelection: Identifiable {
    let id = UUID()
    let scriptID: String
    let scriptName: String?
    let entries: [FeedHistoryEntry]
}

// MARK: - FeedView

struct FeedView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var machines: [AskMachine] = []
    var activeMachineID: String? = nil

    @State private var pollTask: Task<Void, Never>?
    @State private var hasLoaded = false
    @State private var selectedEntry: FeedHistoryEntry?
    @State private var selectedBurst: BurstSelection?

    @Query(sort: \FeedHistoryEntry.createdAt, order: .reverse)
    private var history: [FeedHistoryEntry]

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    private func historyFor(_ scriptID: String) -> [FeedHistoryEntry] {
        history.filter { $0.scriptID == scriptID }
    }

    // Stable color IDs derived from full history (oldest appearance first)
    private var scriptIDs: [String] { orderedScriptIDs(from: history) }

    // Group consecutive same-script runs of 2+ into burst cards
    private var displayItems: [FeedDisplayItem] {
        guard !history.isEmpty else { return [] }
        var items: [FeedDisplayItem] = []
        var run: [FeedHistoryEntry] = [history[0]]

        func commit(_ r: [FeedHistoryEntry]) {
            if r.count >= 2 {
                let first = r[0]
                items.append(.burst(scriptID: first.scriptID, scriptName: first.scriptName,
                                    iconData: first.scriptIconData, icon: first.scriptIcon,
                                    entries: r))
            } else {
                items.append(.single(r[0]))
            }
        }

        for entry in history.dropFirst() {
            if entry.scriptID == run[0].scriptID {
                run.append(entry)
            } else {
                commit(run)
                run = [entry]
            }
        }
        commit(run)
        return items
    }

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                feedList
            }
        }
        .sheet(item: $selectedEntry) { entry in
            FeedItemDetailView(entry: entry, scriptEntries: historyFor(entry.scriptID))
        }
        .sheet(item: $selectedBurst) { burst in
            NavigationStack {
                FeedScriptDetailView(scriptID: burst.scriptID, entries: burst.entries)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedBurst = nil }
                        }
                    }
            }
        }
        .task {
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

    // MARK: - Feed list

    private var feedList: some View {
        List {
            Section {
                ActivitySparklineCard(history: history, scriptIDs: scriptIDs)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                if displayItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Feed Activity", systemImage: "tray")
                    } description: {
                        Text("Results from scheduled scripts will appear here.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(displayItems) { item in
                        switch item {
                        case .single(let entry):
                            FeedEntryRow(
                                entry: entry,
                                color: feedColor(for: entry.scriptID, orderedIDs: scriptIDs)
                            ) { selectedEntry = entry }

                        case .burst(let sid, let name, _, _, let entries):
                            FeedBurstRow(
                                scriptID: sid,
                                scriptName: name,
                                entries: entries,
                                color: feedColor(for: sid, orderedIDs: scriptIDs)
                            ) {
                                selectedBurst = BurstSelection(scriptID: sid, scriptName: name, entries: entries)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - Data

    private func load() async {
        if let machine = activeMachine,
           let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
            let feedBlocks = fresh.filter { $0.isFeedBlock && !$0.requiresResponse && $0.blockType != .tile }
            await MainActor.run { saveToHistory(feedBlocks) }
        }
        hasLoaded = true
    }

    private func saveToHistory(_ blocks: [RKBlock]) {
        let existingIDs = Set(history.map(\.blockID))
        for block in blocks where !existingIDs.contains(block.id) {
            modelContext.insert(FeedHistoryEntry(
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
            ))
        }
        try? modelContext.save()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }
}

// MARK: - Activity sparkline card

private struct ActivitySparklineCard: View {
    let history: [FeedHistoryEntry]
    let scriptIDs: [String]

    private struct ScriptBucket: Identifiable {
        let id: String
        let start: Date
        let scriptID: String
        let scriptName: String
        let count: Int
    }

    private var windowStart: Date {
        Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
    }

    private var buckets: [ScriptBucket] {
        let cal = Calendar.current
        let now = Date()
        let start24 = cal.date(byAdding: .hour, value: -24, to: now)!
        let recent = history.filter { $0.createdAt >= start24 }
        let scripts = scriptIDs.filter { sid in recent.contains { $0.scriptID == sid } }
        var result: [ScriptBucket] = []
        for i in 0..<24 {
            let sliceStart = cal.date(byAdding: .hour, value: -(24 - i), to: now)!
            let sliceEnd   = cal.date(byAdding: .hour, value: -(23 - i), to: now)!
            let inHour = recent.filter { $0.createdAt >= sliceStart && $0.createdAt < sliceEnd }
            for sid in scripts {
                let count = inHour.filter { $0.scriptID == sid }.count
                if count > 0 {
                    let name = inHour.first { $0.scriptID == sid }?.scriptName ?? sid
                    result.append(ScriptBucket(id: "\(i)-\(sid)", start: sliceStart,
                                               scriptID: sid, scriptName: name, count: count))
                }
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(history.count) events · 24 h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", bucket.start, unit: .hour),
                    y: .value("Events", bucket.count)
                )
                .foregroundStyle(by: .value("Script", bucket.scriptName))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale { (name: String) in
                let idx = buckets.first(where: { $0.scriptName == name })
                    .flatMap { b in scriptIDs.firstIndex(of: b.scriptID) } ?? 0
                return feedPalette[idx % feedPalette.count]
            }
            .chartXScale(domain: windowStart...Date())
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 64)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Feed entry row (single)

private struct FeedEntryRow: View {
    let entry: FeedHistoryEntry
    let color: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Colored left stripe
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.trailing, 9)

                FeedIconView(iconData: entry.scriptIconData, sfSymbol: entry.scriptIcon ?? "doc.text")
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.scriptName ?? entry.scriptID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.headline)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.leading, 9)

                Spacer()

                HStack(spacing: 5) {
                    if let statusColor = entry.statusColor {
                        Circle()
                            .fill(namedColor(statusColor))
                            .frame(width: 6, height: 6)
                    }
                    Text(coarseRelativeTime(entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feed burst row (grouped)

private struct FeedBurstRow: View {
    let scriptID: String
    let scriptName: String?
    let entries: [FeedHistoryEntry]
    let color: Color
    let onTap: () -> Void

    // entries are newest-first; oldest is last
    private var newest: FeedHistoryEntry { entries[0] }
    private var oldest: FeedHistoryEntry { entries[entries.count - 1] }

    private var timeRange: String {
        let t1 = coarseRelativeTime(oldest.createdAt)
        let t2 = coarseRelativeTime(newest.createdAt)
        return t1 == t2 ? t1 : "\(t2) – \(t1)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Colored left stripe
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.trailing, 9)

                FeedIconView(iconData: newest.scriptIconData, sfSymbol: newest.scriptIcon ?? "doc.text")
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(scriptName ?? scriptID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(entries.count) events")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("·")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Text(timeRange)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 9)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feed script detail view

struct FeedScriptDetailView: View {
    let scriptID: String
    let entries: [FeedHistoryEntry]

    var body: some View {
        List {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Circle()
                        .fill(namedColor(entry.statusColor))
                        .frame(width: 7, height: 7)
                    Text(entry.headline)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(detailedRelativeTime(entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entries.first?.scriptName ?? scriptID)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Feed item detail view

struct FeedItemDetailView: View {
    let entry: FeedHistoryEntry
    let scriptEntries: [FeedHistoryEntry]
    @Environment(\.dismiss) private var dismiss

    private var itemBody: String? {
        guard entry.blockTypeRaw == "feed_item",
              let data = entry.payloadJSON.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(RKFeedItemPayload.self, from: data))?.body
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if let color = entry.statusColor {
                                Circle()
                                    .fill(namedColor(color))
                                    .frame(width: 8, height: 8)
                            }
                            Text(entry.headline)
                                .font(.headline)
                        }
                        Text(entry.createdAt.formatted(date: .long, time: .shortened))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let body = itemBody {
                    Section("Details") {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    NavigationLink {
                        FeedScriptDetailView(scriptID: entry.scriptID, entries: scriptEntries)
                    } label: {
                        Label(
                            entry.scriptName ?? entry.scriptID,
                            systemImage: entry.scriptIcon ?? "doc.text"
                        )
                        .font(.subheadline)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(entry.scriptName ?? entry.scriptID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Feed icon

private struct FeedIconView: View {
    let iconData: String?
    let sfSymbol: String

    var body: some View {
        Group {
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
        .frame(width: 28, height: 28)
    }
}

// MARK: - Helpers

func namedColor(_ name: String?) -> Color {
    switch name {
    case "green":  return .green
    case "blue":   return .blue
    case "orange": return .orange
    case "red":    return .red
    case "yellow": return .yellow
    default:       return .secondary
    }
}

// MARK: - RKBlock feed helpers (used at save time)

extension RKBlock {
    var feedHeadline: String {
        switch blockType {
        case .feedItem:    return feedItemPayload?.headline ?? scriptName ?? scriptID
        case .status:      return statusPayload?.label ?? scriptName ?? scriptID
        case .detail:      return detailPayload?.title ?? scriptName ?? scriptID
        case .infoCard:    return infoCardPayload?.title ?? scriptName ?? scriptID
        case .iconCard:    return iconCardPayload?.title ?? scriptName ?? scriptID
        case .confirmation: return confirmationPayload?.title ?? scriptName ?? scriptID
        case .prompt:      return promptPayload?.title ?? scriptName ?? scriptID
        case .chatPrompt:  return chatPromptPayload?.title ?? scriptName ?? scriptID
        case .quickReply:  return quickReplyPayload?.title ?? scriptName ?? scriptID
        case .alert:       return alertPayload?.title ?? scriptName ?? scriptID
        default:           return scriptName ?? scriptID
        }
    }

    var feedStatusColor: String? {
        switch blockType {
        case .feedItem: return feedItemPayload?.statusColor
        case .status:   return statusPayload?.color
        default:        return nil
        }
    }
}
