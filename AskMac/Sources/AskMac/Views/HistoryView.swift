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

private enum ChartMode {
    case day, thirtyDays
}

private struct DashboardTab: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var chartMode: ChartMode = .day

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCards
                activityChart
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
            StatCard(
                title: "Dep Issues",
                value: "\(history.events.filter { $0.kind == .dependencyMissing }.count)",
                systemImage: "wrench.and.screwdriver.fill",
                color: .orange
            )
        }
    }

    // MARK: Activity chart

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartMode == .day ? "Activity (Today)" : "Activity (30 Days)")
                    .font(.headline)
                Spacer()
                Picker("", selection: $chartMode) {
                    Text("Today").tag(ChartMode.day)
                    Text("30 Days").tag(ChartMode.thirtyDays)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if chartMode == .day {
                let data = hourlySourceCounts
                if data.isEmpty {
                    Text("No activity today.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    Chart(data) { item in
                        BarMark(
                            x: .value("Hour", item.hour),
                            y: .value("Events", item.count)
                        )
                        .foregroundStyle(by: .value("Source", item.source))
                        .cornerRadius(2)
                    }
                    .chartXScale(domain: 0...23)
                    .chartXAxis {
                        AxisMarks(values: Array(stride(from: 0, through: 23, by: 6))) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let h = value.as(Int.self) {
                                    Text(hourLabel(h))
                                }
                            }
                        }
                    }
                    .frame(height: 160)
                }
            } else {
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
        }
        .padding(16)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12am"
        case 12: return "12pm"
        default: return hour < 12 ? "\(hour)am" : "\(hour - 12)pm"
        }
    }

    private var hourlySourceCounts: [HourlySourceCount] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        var counts: [Int: [String: Int]] = [:]
        for event in history.events {
            guard event.timestamp >= today && event.timestamp < tomorrow else { continue }
            let hour = calendar.component(.hour, from: event.timestamp)
            counts[hour, default: [:]][event.source, default: 0] += 1
        }

        return counts.flatMap { hour, sourceCounts in
            sourceCounts.map { HourlySourceCount(hour: hour, source: $0.key, count: $0.value) }
        }.sorted { $0.hour < $1.hour }
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
    @State private var showDetails = false

    private let filterOptions: [(label: String, tag: String)] = [
        ("All",       "all"),
        ("Responses", "response"),
        ("Crashes",   "crash"),
        ("Lifecycle", "lifecycle"),
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
                    if showDetails {
                        HistoryEventDetailRow(event: event)
                            .tag(event)
                    } else {
                        HistoryEventRow(event: event)
                            .tag(event)
                    }
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
                TextField("Search sources, summaries or stderr…", text: $search)
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

            Divider()
                .frame(height: 18)

            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: showDetails ? "list.bullet.indent" : "list.bullet")
                    .help(showDetails ? "Switch to friendly view" : "Switch to detail view")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showDetails ? Color.accentColor : Color.secondary)
        }
        .padding(12)
    }

    private var filteredEvents: [HistoryEvent] {
        history.events.filter { event in
            let matchesKind: Bool
            switch kindFilter {
            case "response":  matchesKind = event.kind == .blockResponse
            case "crash":     matchesKind = event.kind == .scriptCrashed
            case "lifecycle": matchesKind = [.scriptStarted, .scriptEnabled, .scriptDisabled, .dependencyMissing].contains(event.kind)
            default:          matchesKind = true
            }
            let matchesSearch = search.isEmpty
                || event.source.localizedCaseInsensitiveContains(search)
                || event.summary.localizedCaseInsensitiveContains(search)
                || (event.detail ?? "").localizedCaseInsensitiveContains(search)
                || (event.stderrTail ?? "").localizedCaseInsensitiveContains(search)
            return matchesKind && matchesSearch
        }
    }
}

// MARK: - Event row (friendly)

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

// MARK: - Event row (detail)

private struct HistoryEventDetailRow: View {
    let event: HistoryEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Kind badge
                Text(event.kind.shortLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(event.kind.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(event.kind.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(event.source)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // Absolute timestamp
                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(event.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Exit code badge for crashes
            if let code = event.exitCode {
                let label = (event.exitedBySignal == true)
                    ? "signal \(code)"
                    : "exit \(code)"
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // First line of stderr / detail
            if let tail = event.stderrTail ?? event.detail,
               let firstLine = tail.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                Text(firstLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail sheet

private struct HistoryDetailView: View {
    let event: HistoryEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: event.kind.systemImage)
                    .foregroundStyle(event.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.source)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(event.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Core fields
                    metaSection

                    // Crash diagnostics
                    if event.kind == .scriptCrashed {
                        crashSection
                    }

                    // Block metadata
                    if let blockID = event.blockID {
                        blockSection(blockID: blockID)
                    }
                }
            }
        }
        .frame(width: 560, height: event.stderrTail != nil ? 520 : 300)
    }

    // MARK: Sections

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("Time",    event.timestamp.formatted(date: .abbreviated, time: .complete))
            detailRow("Summary", event.summary)
            if let version = event.scriptVersion {
                detailRow("Version", version)
            }
            if let detail = event.detail, event.stderrTail == nil {
                // Non-crash detail (dependency list, etc.)
                detailRow("Detail", detail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var crashSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CRASH DIAGNOSTICS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            if let code = event.exitCode {
                let label = (event.exitedBySignal == true)
                    ? "Killed by signal \(code)"
                    : (code == 0 ? "Unexpected clean exit (0)" : "Exit code \(code)")
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
            }

            if let tail = event.stderrTail, !tail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("STDERR (\(tail.components(separatedBy: "\n").count) lines)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)

                    ScrollView {
                        Text(tail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .padding(10)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else {
                Text("No stderr captured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }

    private func blockSection(blockID: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.top, 8)
            detailRow("Block ID",   blockID)
            if let bt = event.blockType { detailRow("Block Type", bt) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Helpers

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        Divider()
    }
}

// MARK: - HistoryEventKind display helpers

extension HistoryEventKind {
    var systemImage: String {
        switch self {
        case .blockResponse:     "hand.point.up.left"
        case .scriptEnabled:     "play.circle.fill"
        case .scriptDisabled:    "stop.circle.fill"
        case .scriptCrashed:     "exclamationmark.triangle.fill"
        case .scriptStarted:     "arrow.clockwise.circle.fill"
        case .dependencyMissing: "wrench.and.screwdriver.fill"
        case .blockEmitted:      "icloud.and.arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .blockResponse:     .purple
        case .scriptEnabled:     .green
        case .scriptDisabled:    .secondary
        case .scriptCrashed:     .red
        case .scriptStarted:     .blue
        case .dependencyMissing: .orange
        case .blockEmitted:      .teal
        }
    }

    var displayName: String {
        switch self {
        case .blockResponse:     "Block Response"
        case .scriptEnabled:     "Script Enabled"
        case .scriptDisabled:    "Script Disabled"
        case .scriptCrashed:     "Script Crashed"
        case .scriptStarted:     "Script Started"
        case .dependencyMissing: "Dependency Missing"
        case .blockEmitted:      "Block Emitted"
        }
    }

    /// Compact label used in the detail-row kind badge.
    var shortLabel: String {
        switch self {
        case .blockResponse:     "RESPONSE"
        case .scriptEnabled:     "ENABLED"
        case .scriptDisabled:    "DISABLED"
        case .scriptCrashed:     "CRASH"
        case .scriptStarted:     "STARTED"
        case .dependencyMissing: "DEP MISSING"
        case .blockEmitted:      "EMITTED"
        }
    }
}

// MARK: - Supporting types

private struct DailyCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct HourlySourceCount: Identifiable {
    let hour: Int
    let source: String
    let count: Int
    var id: String { "\(hour)-\(source)" }
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
