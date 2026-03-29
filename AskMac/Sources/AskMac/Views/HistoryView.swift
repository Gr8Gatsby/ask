import SwiftUI
import Charts

struct HistoryView: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardTab()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }
                .tag(0)
            LogTab()
                .tabItem { Label("Log", systemImage: "list.bullet") }
                .tag(1)
        }
        .frame(minWidth: 720, minHeight: 520)
        .environment(history)
    }
}

// MARK: - Dashboard

private struct DashboardTab: View {
    @Environment(ActionHistoryService.self) private var history

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCards
                dailyChart
                topActions
            }
            .padding(24)
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Total Runs",
                value: "\(history.entries.count)",
                systemImage: "bolt.fill",
                color: .blue
            )
            StatCard(
                title: "Completed",
                value: "\(history.entries.filter { $0.status == "completed" }.count)",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
            StatCard(
                title: "Failed",
                value: "\(history.entries.filter { $0.status == "failed" }.count)",
                systemImage: "xmark.circle.fill",
                color: .red
            )
            StatCard(
                title: "Success Rate",
                value: successRate,
                systemImage: "percent",
                color: .purple
            )
        }
    }

    private var successRate: String {
        let total = history.entries.count
        guard total > 0 else { return "—" }
        let completed = history.entries.filter { $0.status == "completed" }.count
        return "\(Int(Double(completed) / Double(total) * 100))%"
    }

    // MARK: Daily chart

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs per Day")
                .font(.headline)

            if history.entries.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart(dailyCounts) { day in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Runs", day.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: dailyCounts.count > 14 ? 7 : 1)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 160)
            }
        }
        .padding(16)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dailyCounts: [DailyCount] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -29, to: today) else { return [] }

        var countsByDay: [Date: Int] = [:]
        for entry in history.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if day >= start {
                countsByDay[day, default: 0] += 1
            }
        }

        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DailyCount(date: date, count: countsByDay[date] ?? 0)
        }
    }

    // MARK: Top actions

    private var topActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Actions")
                .font(.headline)

            if actionStats.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(actionStats.prefix(8).enumerated()), id: \.element.id) { idx, stat in
                        if idx > 0 { Divider() }
                        ActionStatRow(stat: stat, maxCount: actionStats[0].count)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 0.5)
                )
            }
        }
        .padding(16)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionStats: [ActionStat] {
        var counts: [String: (total: Int, completed: Int)] = [:]
        for entry in history.entries {
            var pair = counts[entry.actionName] ?? (0, 0)
            pair.total += 1
            if entry.status == "completed" { pair.completed += 1 }
            counts[entry.actionName] = pair
        }
        return counts.map { name, pair in
            ActionStat(
                actionName: name,
                count: pair.total,
                successRate: pair.total > 0 ? Double(pair.completed) / Double(pair.total) : 0
            )
        }
        .sorted { $0.count > $1.count }
    }
}

// MARK: - Log

private struct LogTab: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var search = ""
    @State private var statusFilter = "all"
    @State private var selectedEntry: ActionHistoryEntry?

    private let statusOptions = ["all", "completed", "failed", "cancelled"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No history yet" : "No results",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(search.isEmpty
                        ? "Action runs will appear here."
                        : "Try a different search or filter.")
                )
            } else {
                List(filteredEntries, selection: $selectedEntry) { entry in
                    HistoryEntryRow(entry: entry)
                        .tag(entry)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .sheet(item: $selectedEntry) { entry in
            HistoryDetailView(entry: entry)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search actions or prompts…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Picker("Status", selection: $statusFilter) {
                ForEach(statusOptions, id: \.self) { opt in
                    Text(opt.capitalized).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(12)
    }

    private var filteredEntries: [ActionHistoryEntry] {
        history.entries.filter { entry in
            let matchesStatus = statusFilter == "all" || entry.status == statusFilter
            let matchesSearch = search.isEmpty
                || entry.actionName.localizedCaseInsensitiveContains(search)
                || entry.prompt.localizedCaseInsensitiveContains(search)
            return matchesStatus && matchesSearch
        }
    }
}

// MARK: - Entry row

private struct HistoryEntryRow: View {
    let entry: ActionHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.actionName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(entry.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(durationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch entry.status {
        case "completed": "checkmark.circle.fill"
        case "failed":    "xmark.circle.fill"
        case "cancelled": "minus.circle.fill"
        case "timeout":   "clock.badge.xmark"
        default:          "circle"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case "completed": .green
        case "failed":    .red
        case "cancelled": .secondary
        case "timeout":   .orange
        default:          .secondary
        }
    }

    private var durationLabel: String {
        let s = entry.durationSeconds
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%dm %ds", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Detail sheet

private struct HistoryDetailView: View {
    let entry: ActionHistoryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.actionName)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                LabeledContent("Status") {
                    Text(entry.status.capitalized)
                        .foregroundStyle(entry.status == "completed" ? .green : .red)
                }
                LabeledContent("Started") {
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Duration") {
                    Text(durationLabel)
                        .fontDesign(.monospaced)
                }
                if let code = entry.exitCode {
                    LabeledContent("Exit Code") {
                        Text("\(code)")
                            .fontDesign(.monospaced)
                    }
                }
                LabeledContent("Prompt") {
                    Text(entry.prompt)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 320)
    }

    private var durationLabel: String {
        let s = entry.durationSeconds
        if s < 60 { return String(format: "%.1f seconds", s) }
        return String(format: "%d min %d sec", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Supporting types

private struct DailyCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct ActionStat: Identifiable {
    let actionName: String
    let count: Int
    let successRate: Double
    var id: String { actionName }
}

private struct ActionStatRow: View {
    let stat: ActionStat
    let maxCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(stat.actionName)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: geo.size.width * CGFloat(stat.count) / CGFloat(maxCount))
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 120, height: 14)
            Text("\(stat.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text("\(Int(stat.successRate * 100))%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
