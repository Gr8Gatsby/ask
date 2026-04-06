import SwiftUI
import CloudKit
import SwiftData
import Charts

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

    @Query(sort: \FeedHistoryEntry.createdAt, order: .reverse)
    private var history: [FeedHistoryEntry]

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    private func historyFor(_ scriptID: String) -> [FeedHistoryEntry] {
        history.filter { $0.scriptID == scriptID }
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
                ActivitySparklineCard(history: history)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                if history.isEmpty {
                    ContentUnavailableView {
                        Label("No Feed Activity", systemImage: "tray")
                    } description: {
                        Text("Results from scheduled scripts will appear here.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(history) { entry in
                        FeedEntryRow(entry: entry) {
                            selectedEntry = entry
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

    private struct HourBucket: Identifiable {
        let id: Int
        let start: Date
        let count: Int
    }

    private var buckets: [HourBucket] {
        let now = Date()
        let cal = Calendar.current
        return (0..<24).map { i in
            let start = cal.date(byAdding: .hour, value: -(24 - i), to: now)!
            let end   = cal.date(byAdding: .hour, value: -(23 - i), to: now)!
            let count = history.filter { $0.createdAt >= start && $0.createdAt < end }.count
            return HourBucket(id: i, start: start, count: count)
        }
    }

    private var lastActivity: Date? { history.map(\.createdAt).max() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = lastActivity {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", bucket.start),
                    y: .value("Events", bucket.count)
                )
                .foregroundStyle(Color.secondary.opacity(0.55))
                .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 44)

            Text("\(history.count) events · 24 h")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Feed entry row

private struct FeedEntryRow: View {
    let entry: FeedHistoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                FeedIconView(iconData: entry.scriptIconData, sfSymbol: entry.scriptIcon ?? "doc.text")

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.scriptName ?? entry.scriptID)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(entry.headline)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let color = entry.statusColor {
                        Circle()
                            .fill(namedColor(color))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .padding(.vertical, 2)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(namedColor(entry.statusColor))
                            .frame(width: 8, height: 8)
                        Text(entry.headline)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(entry.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        case .feedItem: return feedItemPayload?.headline ?? scriptName ?? scriptID
        case .status:   return statusPayload?.label ?? scriptName ?? scriptID
        case .detail:   return detailPayload?.title ?? scriptName ?? scriptID
        case .infoCard: return infoCardPayload?.title ?? scriptName ?? scriptID
        case .iconCard: return iconCardPayload?.title ?? scriptName ?? scriptID
        default:        return scriptName ?? scriptID
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
