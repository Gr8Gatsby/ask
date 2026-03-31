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
                topSources
            }
            .padding(24)
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Total Events",
                value: "\(history.events.count)",
                systemImage: "bolt.fill",
                color: .blue
            )
            StatCard(
                title: "Responses",
                value: "\(history.events.filter { $0.kind == .blockResponse }.count)",
                systemImage: "hand.tap.fill",
                color: .purple
            )
            StatCard(
                title: "Crashes",
                value: "\(history.events.filter { $0.kind == .scriptCrashed }.count)",
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        }
    }

    // MARK: Daily chart

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity (30 Days)")
                .font(.headline)

            if history.events.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart(dailyCounts) { day in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Events", day.count)
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
        for event in history.events {
            let day = calendar.startOfDay(for: event.timestamp)
            if day >= start { countsByDay[day, default: 0] += 1 }
        }

        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DailyCount(date: date, count: countsByDay[date] ?? 0)
        }
    }

    // MARK: Top sources

    private var topSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Sources")
                .font(.headline)

            if sourceStats.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sourceStats.prefix(8).enumerated()), id: \.element.id) { idx, stat in
                        if idx > 0 { Divider() }
                        SourceStatRow(stat: stat, maxCount: sourceStats[0].count)
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

    private var sourceStats: [SourceStat] {
        var counts: [String: Int] = [:]
        for event in history.events {
            counts[event.source, default: 0] += 1
        }
        return counts.map { SourceStat(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}

// MARK: - Log

private struct LogTab: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var search = ""
    @State private var kindFilter = "all"
    @State private var selectedEvent: HistoryEvent?

    private let filterOptions: [(label: String, tag: String)] = [
        ("All", "all"),
        ("Responses", "response"),
        ("System", "system"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No history yet" : "No results",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(search.isEmpty
                        ? "Script interactions will appear here."
                        : "Try a different search or filter.")
                )
            } else {
                List(filteredEvents, selection: $selectedEvent) { event in
                    HistoryEventRow(event: event)
                        .tag(event)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .sheet(item: $selectedEvent) { event in
            HistoryDetailView(event: event)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sources or details…", text: $search)
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

            Picker("Filter", selection: $kindFilter) {
                ForEach(filterOptions, id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(12)
    }

    private var filteredEvents: [HistoryEvent] {
        history.events.filter { event in
            let matchesKind: Bool
            switch kindFilter {
            case "response": matchesKind = event.kind == .blockResponse
            case "system":   matchesKind = [.scriptEnabled, .scriptDisabled, .scriptCrashed].contains(event.kind)
            default:         matchesKind = true
            }
            let matchesSearch = search.isEmpty
                || event.source.localizedCaseInsensitiveContains(search)
                || event.summary.localizedCaseInsensitiveContains(search)
                || (event.detail ?? "").localizedCaseInsensitiveContains(search)
            return matchesKind && matchesSearch
        }
    }
}

// MARK: - Event row

private struct HistoryEventRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.source)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail sheet

private struct HistoryDetailView: View {
    let event: HistoryEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(event.source, systemImage: event.kind.systemImage)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(event.kind.color)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                LabeledContent("Event") { Text(event.kind.displayName) }
                LabeledContent("Summary") { Text(event.summary) }
                LabeledContent("Time") {
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                if let detail = event.detail {
                    LabeledContent("Detail") {
                        Text(detail)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 280)
    }
}

// MARK: - HistoryEventKind display helpers

extension HistoryEventKind {
    var systemImage: String {
        switch self {
        case .blockResponse:  "hand.tap.fill"
        case .scriptEnabled:  "play.circle.fill"
        case .scriptDisabled: "stop.circle.fill"
        case .scriptCrashed:  "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .blockResponse:  .purple
        case .scriptEnabled:  .green
        case .scriptDisabled: .secondary
        case .scriptCrashed:  .red
        }
    }

    var displayName: String {
        switch self {
        case .blockResponse:  "Block Response"
        case .scriptEnabled:  "Script Enabled"
        case .scriptDisabled: "Script Disabled"
        case .scriptCrashed:  "Script Crashed"
        }
    }
}

// MARK: - Supporting types

private struct DailyCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct SourceStat: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

private struct SourceStatRow: View {
    let stat: SourceStat
    let maxCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(stat.name)
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
