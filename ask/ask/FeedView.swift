import SwiftUI
import CloudKit

// MARK: - FeedView

struct FeedView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.scenePhase) private var scenePhase

    var machines: [AskMachine] = []
    var activeMachineID: String? = nil

    @State private var store = FeedStore.shared
    @State private var pollTask: Task<Void, Never>?
    @State private var selectedItem: LocalFeedItem?

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("No Feed Updates", systemImage: "tray")
                } description: {
                    Text("Updates from scheduled scripts will appear here.")
                }
            } else {
                feedList
            }
        }
        .sheet(item: $selectedItem) { item in
            FeedItemDetailSheet(item: item)
        }
        .task {
            await fetchFromCloudKit()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await fetchFromCloudKit() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askRefreshRequired)) { _ in
            Task<Void, Never> { await fetchFromCloudKit() }
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        List {
            ForEach(store.items) { item in
                Button { selectedItem = item } label: {
                    FeedItemRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .refreshable { await fetchFromCloudKit() }
    }

    // MARK: - Data

    private func fetchFromCloudKit() async {
        guard let machine = activeMachine else { return }
        _ = try? await cloudKit.fetchBlocks(machineID: machine.id)
        // FeedStore.shared.upsert() is called inside fetchBlocks for feed_item blocks
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await fetchFromCloudKit()
            }
        }
    }
}

// MARK: - FeedItemRow

private struct FeedItemRow: View {
    let item: LocalFeedItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(item.statusColor))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var sourceLine: String {
        item.scriptName ?? item.scriptID
    }

    private func statusColor(_ name: String?) -> Color {
        switch name {
        case "green":  return .green
        case "blue":   return .blue
        case "orange": return .orange
        case "red":    return .red
        case "yellow": return .yellow
        default:       return Color(.systemGray4)
        }
    }
}

// MARK: - FeedItemDetailSheet

private struct FeedItemDetailSheet: View {
    let item: LocalFeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.headline)
                        .font(.headline)

                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Label(item.scriptName ?? item.scriptID, systemImage: "app.badge")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label(item.timestamp.formatted(date: .long, time: .shortened), systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(item.scriptName ?? item.scriptID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
