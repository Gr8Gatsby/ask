import SwiftUI
import SwiftData

// MARK: - TaskFeedView

/// The unified task list — replaces the old FeedView.
/// Shows all tasks across all machines and scripts in two sections: Active and Recent.
struct TaskFeedView: View {
    let machines: [AskMachine]

    @Environment(TaskHistoryStore.self) private var taskHistory
    @Environment(iOSCloudKitService.self) private var cloudKit

    @Query(sort: \TaskRecord.lastActivityAt, order: .reverse)
    private var allTasks: [TaskRecord]

    @State private var showInvokeSheet = false

    // MARK: - Body

    var body: some View {
        Group {
            if allTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .refreshable {
            await taskHistory.refresh(machineIDs: machines.map(\.id))
        }
        .task {
            guard !machines.isEmpty else { return }
            await taskHistory.refresh(machineIDs: machines.map(\.id))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await taskHistory.refresh(machineIDs: machines.map(\.id))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInvokeSheet = true
                } label: {
                    Image(systemName: "bolt")
                }
            }
        }
        .sheet(isPresented: $showInvokeSheet) {
            InvokeScriptSheet(machines: machines)
                .environment(cloudKit)
        }
    }

    // MARK: - Task list

    private var taskList: some View {
        List {
            ForEach(allTasks, id: \.recordName) { task in
                NavigationLink {
                    TaskThreadView(task: task)
                        .environment(taskHistory)
                } label: {
                    TaskListRow(task: task)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        try? taskHistory.deleteTask(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Events Yet", systemImage: "tray")
        } description: {
            Text("Events from your scripts will appear here.")
        }
    }
}

// MARK: - Invoke Script Sheet

private struct InvokeScriptSheet: View {
    let machines: [AskMachine]

    @Environment(\.dismiss) private var dismiss
    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var feedScripts: [AskScript] = []
    @State private var isLoading = true
    @State private var invokedIDs = Set<String>()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading scripts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if feedScripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Feed Scripts", systemImage: "bolt.slash")
                    } description: {
                        Text("Feed scripts appear here once AskMac has registered them.")
                    }
                } else {
                    List(feedScripts) { script in
                        HStack {
                            if let icon = script.scriptIcon {
                                Image(systemName: icon)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(script.scriptName)
                                    .font(.subheadline)
                                Text(script.machineName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if invokedIDs.contains(script.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Run") {
                                    invokedIDs.insert(script.id)
                                    Task {
                                        try? await cloudKit.writeInvokeRequest(
                                            machineID: script.machineID,
                                            scriptID: script.scriptID
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Run a Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                feedScripts = await cloudKit.fetchScripts(machines: machines).filter(\.isFeed)
                isLoading = false
            }
        }
    }
}

