#if canImport(AskMacCore)
import AskMacCore
#endif
import AppKit
import SwiftUI

// MARK: - Feed filter

enum FeedFilter: Hashable {
    case all
    case kind(HistoryEventKind)
    case source(String)
}

// MARK: - Feed view

struct MacFeedView: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var feedFilter: FeedFilter? = .all
    @State private var selectedEvent: HistoryEvent?
    @State private var showVerbose = true

    // Cached derived state — recomputed only when events change, not every render
    @State private var filteredEvents: [HistoryEvent] = []
    @State private var kindCounts: [HistoryEventKind: Int] = [:]
    @State private var sourceStats: [SourceStat] = []

    private struct SourceStat: Identifiable {
        let name: String; let count: Int; let latest: Date?
        let eventsPerMinute: Double?
        var id: String { name }
    }

    private func recompute(events: [HistoryEvent], filter: FeedFilter?) {
        // Single pass: kind counts + per-source count, earliest, latest
        var kc: [HistoryEventKind: Int] = [:]
        var sc: [String: (count: Int, earliest: Date, latest: Date)] = [:]
        for event in events {
            kc[event.kind, default: 0] += 1
            if let prev = sc[event.source] {
                sc[event.source] = (prev.count + 1, min(prev.earliest, event.timestamp), max(prev.latest, event.timestamp))
            } else {
                sc[event.source] = (1, event.timestamp, event.timestamp)
            }
        }
        kindCounts = kc
        sourceStats = sc.map { name, val in
            let spanMinutes = val.latest.timeIntervalSince(val.earliest) / 60.0
            let rate: Double? = spanMinutes >= 0.5 ? Double(val.count) / spanMinutes : nil
            return SourceStat(name: name, count: val.count, latest: val.latest, eventsPerMinute: rate)
        }.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }

        // Filtered events
        filteredEvents = switch filter {
        case .all, nil:      events
        case .kind(let k):   events.filter { $0.kind == k }
        case .source(let s): events.filter { $0.source == s }
        }
    }

    var body: some View {
        NavigationSplitView {
            feedSidebar
        } detail: {
            feedDetail
        }
        .navigationTitle("Feed")
        .sheet(item: $selectedEvent) { event in
            FeedEventDetailSheet(event: event)
        }
        .task { recompute(events: history.events, filter: feedFilter) }
        .onChange(of: history.events.count) { recompute(events: history.events, filter: feedFilter) }
        .onChange(of: feedFilter) { recompute(events: history.events, filter: feedFilter) }
    }

    // MARK: Sidebar

    private var feedSidebar: some View {
        List(selection: $feedFilter) {
            Section {
                HStack {
                    Label("All Activity", systemImage: "scroll")
                    Spacer()
                    Text("\(history.events.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(FeedFilter.all)
            }

            Section("By Type") {
                kindRow(kind: .scriptCrashed,      label: "Crashes",      icon: "exclamationmark.triangle.fill")
                kindRow(kind: .blockResponse,      label: "Responses",    icon: "hand.point.up.left")
                kindRow(kind: .scriptStarted,      label: "Starts",       icon: "arrow.clockwise.circle.fill")
                kindRow(kind: .scriptEnabled,      label: "Enabled",      icon: "play.circle.fill")
                kindRow(kind: .scriptDisabled,     label: "Disabled",     icon: "stop.circle.fill")
                kindRow(kind: .dependencyMissing,  label: "Dep Missing",  icon: "wrench.and.screwdriver.fill")
                kindRow(kind: .blockEmitted,       label: "Emitted",      icon: "icloud.and.arrow.up")
            }

            if !sourceStats.isEmpty {
                Section("By Script") {
                    ForEach(sourceStats) { stat in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.name).font(.subheadline)
                                if let rate = stat.eventsPerMinute {
                                    Text(String(format: "%.1f/min", rate))
                                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                } else if let date = stat.latest {
                                    Text(date, style: .relative)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text("\(stat.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(FeedFilter.source(stat.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    @ViewBuilder
    private func kindRow(kind: HistoryEventKind, label: String, icon: String) -> some View {
        let n = kindCounts[kind, default: 0]
        if n > 0 {
            HStack {
                Label(label, systemImage: icon).foregroundStyle(kind.color)
                Spacer()
                Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .tag(FeedFilter.kind(kind))
        }
    }

    // MARK: Event list

    @State private var sortOrder = [KeyPathComparator(\HistoryEvent.timestamp, order: .reverse)]
    @State private var tableSelection: Set<HistoryEvent.ID> = []

    private var feedDetail: some View {
        Group {
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "scroll",
                    description: Text("Script interactions and lifecycle events will appear here.")
                )
            } else if showVerbose {
                logTable
            } else {
                compactList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button { showVerbose.toggle() } label: {
                        Label(
                            showVerbose ? "Compact" : "Table",
                            systemImage: showVerbose ? "list.bullet" : "tablecells"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showVerbose ? Color.accentColor : Color.secondary)
                    .help(showVerbose ? "Switch to compact view" : "Switch to table view")
                    Button {
                        history.purge()
                    } label: {
                        Label("Purge Log", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.secondary)
                    .help("Delete all log entries")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    // Compact list (friendly rows)
    private var compactList: some View {
        List {
            ForEach(filteredEvents) { event in
                FeedEventRow(event: event)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEvent = event }
                    .listRowBackground(
                        event.kind == .scriptCrashed ? Color.red.opacity(0.04) : Color.clear
                    )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // Verbose table
    private var logTable: some View {
        Table(filteredEvents, selection: $tableSelection, sortOrder: $sortOrder) {
            // Timestamp
            TableColumn("Time", value: \.timestamp) { event in
                Text(event.timestamp.formatted(.dateTime.month(.twoDigits).day().hour().minute().second()))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)

            // Kind badge
            TableColumn("Type") { event in
                Text(event.kind.shortLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(event.kind.color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(event.kind.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(min: 80, ideal: 90)

            // Script name + version
            TableColumn("Script", value: \.source) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.source).font(.caption).fontWeight(.medium)
                    if let v = event.scriptVersion {
                        Text("v\(v)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 90, ideal: 110)

            // Summary
            TableColumn("Summary", value: \.summary) { event in
                Text(event.summary).font(.caption).lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            // Exit / signal
            TableColumn("Exit") { event in
                ExitCodeCell(exitCode: event.exitCode, exitedBySignal: event.exitedBySignal)
            }
            .width(min: 44, ideal: 52)

            // Detail: stderr first line, block type, or dep names
            TableColumn("Detail") { event in
                FeedDetailCell(event: event)
            }
            .width(min: 160)
        }
        .onChange(of: tableSelection) { _, ids in
            if let id = ids.first,
               let event = filteredEvents.first(where: { $0.id == id }) {
                selectedEvent = event
                tableSelection = []
            }
        }
        .contextMenu(forSelectionType: HistoryEvent.ID.self) { ids in
            if let id = ids.first,
               let event = filteredEvents.first(where: { $0.id == id }) {
                Button("View Full Detail") { selectedEvent = event }
            }
        }
    }
}

struct ExitCodeCell: View {
    let exitCode: Int32?
    let exitedBySignal: Bool?
    var body: some View {
        if let code = exitCode {
            let bySignal = exitedBySignal == true
            let label = bySignal ? "SIG \(code)" : "\(code)"
            let color: Color = code == 0 ? .secondary : .red
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
        } else {
            Text("—").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct FeedDetailCell: View {
    let event: HistoryEvent
    var body: some View {
        let text: String = {
            if let tail = event.stderrTail,
               let line = tail.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                return line
            }
            if let bt = event.blockType { return bt }
            if let d = event.detail,
               let line = d.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                return line
            }
            return "—"
        }()
        let isMono = event.stderrTail != nil
        Group {
            if isMono {
                Text(text).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

struct FeedEventRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.color)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.source).font(.subheadline).fontWeight(.medium)
                Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let title = event.blockTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let tail = event.stderrTail,
                   let line = tail.components(separatedBy: "\n").first(where: { !$0.isEmpty }) {
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Feed event detail sheet

struct FeedEventDetailSheet: View {
    let event: HistoryEvent
    @Environment(\.dismiss) private var dismiss

    private var hasStderr: Bool { !(event.stderrTail ?? "").isEmpty }
    private var hasPayload: Bool { !(event.blockPayload ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: event.kind.systemImage)
                    .font(.title2).foregroundStyle(event.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.source).font(.title3).fontWeight(.semibold)
                    Text(event.kind.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Core metadata
                    Group {
                        infoRow("Time",    event.timestamp.formatted(date: .abbreviated, time: .complete))
                        infoRow("Summary", event.summary)
                        if let version = event.scriptVersion { infoRow("Version", version) }
                        if let bt = event.blockType          { infoRow("Block Type", bt) }
                        if let bid = event.blockID           { infoRow("Block ID", bid) }
                        if let title = event.blockTitle, !title.isEmpty { infoRow("Prompt", title) }
                        if let opts = event.blockOptions, !opts.isEmpty { infoRow("Options", opts) }
                    }
                    .padding(.horizontal, 16)

                    // Crash diagnostics
                    if let code = event.exitCode {
                        Divider().padding(.vertical, 8)

                        let label = (event.exitedBySignal == true)
                            ? "Killed by signal \(code)"
                            : (code == 0 ? "Unexpected clean exit (0)" : "Exit code \(code)")

                        HStack(spacing: 8) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text(label)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Stderr block
                    if let tail = event.stderrTail, !tail.isEmpty {
                        let lineCount = tail.components(separatedBy: "\n").count
                        VStack(alignment: .leading, spacing: 6) {
                            Text("STDERR — \(lineCount) line\(lineCount == 1 ? "" : "s")")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)

                            ScrollView {
                                Text(tail)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                            .padding(10)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    } else if let detail = event.detail, !detail.isEmpty {
                        // Non-crash detail (dependency list, etc.)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DETAIL")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)
                            Text(detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // Block payload (emitted blocks)
                    if let payload = event.blockPayload, !payload.isEmpty {
                        Divider().padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BLOCK PAYLOAD")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary).tracking(0.5)
                            ScrollView {
                                Text(payload)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 300)
                            .padding(10)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 500, height: hasStderr || hasPayload ? 540 : 280)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        Divider()
    }
}
