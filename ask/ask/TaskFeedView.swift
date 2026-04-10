import SwiftUI
import SwiftData

// MARK: - TaskFeedView

/// The unified task list — replaces the old FeedView.
/// Shows all tasks across all machines and scripts in two sections: Active and Recent.
struct TaskFeedView: View {
    let machines: [AskMachine]

    @Environment(TaskHistoryStore.self) private var taskHistory

    @Query(sort: \TaskRecord.lastActivityAt, order: .reverse)
    private var allTasks: [TaskRecord]

    @State private var showOlder = false

    private let olderCutoff = Date().addingTimeInterval(-30 * 24 * 3600)

    // MARK: - Filtered sections

    private var activeTasks: [TaskRecord] {
        allTasks.filter { $0.status == "working" || $0.status == "input-required" }
            .sorted {
                // input-required floats above working
                if $0.status != $1.status {
                    return $0.status == "input-required"
                }
                return $0.lastActivityAt > $1.lastActivityAt
            }
    }

    private var recentTasks: [TaskRecord] {
        allTasks.filter { $0.status == "completed" || $0.status == "failed" || $0.status == "cancelled" }
    }

    private var visibleRecentTasks: [TaskRecord] {
        let recent = recentTasks.filter { $0.lastActivityAt >= olderCutoff }
        let older  = recentTasks.filter { $0.lastActivityAt < olderCutoff }
        if showOlder { return recent + older }
        return recent
    }

    private var hiddenOlderCount: Int {
        recentTasks.filter { $0.lastActivityAt < olderCutoff }.count
    }

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
        }
    }

    // MARK: - Task list

    private var taskList: some View {
        List {
            if !activeTasks.isEmpty {
                Section("Active") {
                    ForEach(activeTasks, id: \.recordName) { task in
                        NavigationLink(value: task) {
                            TaskListRow(task: task)
                        }
                    }
                }
            }

            if !recentTasks.isEmpty {
                Section("Recent") {
                    ForEach(visibleRecentTasks, id: \.recordName) { task in
                        NavigationLink(value: task) {
                            TaskListRow(task: task)
                        }
                    }
                    if hiddenOlderCount > 0 && !showOlder {
                        Button {
                            withAnimation { showOlder = true }
                        } label: {
                            Label("Show \(hiddenOlderCount) older task\(hiddenOlderCount == 1 ? "" : "s")",
                                  systemImage: "clock")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tasks Yet", systemImage: "tray")
        } description: {
            Text("Tasks created by scripts will appear here.")
        }
    }
}

// MARK: - NavigationPath value conformance

extension TaskRecord: Hashable {
    public static func == (lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        lhs.recordName == rhs.recordName
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(recordName)
    }
}
