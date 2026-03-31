import SwiftUI
import CloudKit

// MARK: - FeedView

struct FeedView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.scenePhase) private var scenePhase

    @State private var machines: [AskMachine] = []
    @State private var feedBlocks: [RKBlock] = []
    @State private var activeMachineID: String?
    @State private var hasLoaded = false
    @State private var pollTask: Task<Void, Never>?
    @State private var selectedScriptID: String?

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    private var feedGroups: [ScriptGroup] {
        let grouped = Dictionary(grouping: feedBlocks, by: { $0.scriptID })
        return grouped.keys.sorted().map { ScriptGroup(scriptID: $0, blocks: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if feedGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Updates", systemImage: "tray")
                    } description: {
                        Text("Results from scheduled scripts will appear here.")
                    }
                } else {
                    feedList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
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
                    allBlocks: feedBlocks,
                    isWaiting: false,
                    onRespond: { _, _ in }
                )
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
            ForEach(feedGroups) { group in
                Section {
                    FeedGroupCard(group: group) {
                        selectedScriptID = group.scriptID
                    }
                }
                .listSectionSpacing(4)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Feed")
                .font(.headline)
        }
    }

    // MARK: - Data

    private func load() async {
        if machines.isEmpty {
            if let fresh = try? await cloudKit.fetchMachines() {
                machines = fresh
            }
        }
        if let machine = activeMachine,
           let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
            feedBlocks = fresh.filter { $0.isFeedBlock && $0.blockType != .alert }
        }
        hasLoaded = true
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if let machine = activeMachine,
                   let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                    feedBlocks = fresh.filter { $0.isFeedBlock && $0.blockType != .alert }
                }
            }
        }
    }
}

// MARK: - FeedGroupCard

private struct FeedGroupCard: View {
    let group: ScriptGroup
    let onTap: () -> Void

    private var latestBlock: RKBlock? { group.blocks.max(by: { $0.createdAt < $1.createdAt }) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: icon + name + timestamp
                HStack(spacing: 10) {
                    FeedScriptIconView(iconData: group.iconData, sfSymbol: group.icon ?? "doc.text")
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let date = latestBlock?.createdAt {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Summary: use tile label or first status/info label
                if let label = group.tileLabel ?? group.blocks.first?.statusPayload?.label {
                    HStack(spacing: 6) {
                        if let color = group.tileStatusColor {
                            Circle()
                                .fill(statusColor(color))
                                .frame(width: 7, height: 7)
                        }
                        Text(label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                // Body text if available
                if let body = group.tileBody {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ name: String) -> Color {
        switch name {
        case "green":  return .green
        case "blue":   return .blue
        case "orange": return .orange
        case "red":    return .red
        case "yellow": return .yellow
        default:       return .secondary
        }
    }
}

// MARK: - FeedScriptIconView

private struct FeedScriptIconView: View {
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
