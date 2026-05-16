#if canImport(AskMacCore)
import AskMacCore
#endif
import SwiftUI

struct SessionsView: View {
    @Environment(SessionsService.self) private var service

    var body: some View {
        let groups = service.groupedByMachine()
        VStack(spacing: 0) {
            banners
            Group {
                if service.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList(groups: groups)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if service.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    service.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh now")
            }
        }
        .task { service.setVisible(true) }
        .onDisappear { service.setVisible(false) }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let local = service.localUnavailable {
                bannerRow(systemImage: "exclamationmark.triangle.fill",
                          tint: .orange,
                          message: "Local sessions unavailable — \(local)")
            }
            if let remote = service.remoteUnavailable {
                bannerRow(systemImage: "icloud.slash.fill",
                          tint: .secondary,
                          message: "Remote sessions unavailable — \(remote)")
            }
        }
    }

    private func bannerRow(systemImage: String, tint: Color, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Active Sessions",
            systemImage: "person.crop.circle.dashed",
            description: Text(
                "Sessions appear here while they are running. A session is considered active if it had any activity in the last 10 minutes."
            )
        )
    }

    private func sessionList(groups: [SessionsService.MachineGroup]) -> some View {
        // TimelineView drives the relative-time labels so they tick
        // without requiring service-level refreshes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, now: context.date)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: group.isThisMac ? "laptopcomputer" : "desktopcomputer")
                                .foregroundStyle(group.isThisMac ? Color.accentColor : .secondary)
                            Text(group.isThisMac ? "This Mac · \(group.machineName)" : group.machineName)
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Text("\(group.sessions.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: UnifiedSession
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HealthDot(health: session.health)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.scriptName)
                        .font(.subheadline).fontWeight(.semibold)
                    if let v = session.scriptVersion {
                        Text("v\(v)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let state = session.state, !state.isEmpty {
                        StatePill(state: state)
                    }
                    if let tool = session.currentTool {
                        Text(tool)
                            .font(.caption2).fontWeight(.medium)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                if let preview = session.currentPreview ?? session.lastMessage ?? session.title {
                    Text(preview)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(relative(session.lastActivityAt, now: now))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                Text(session.sessionID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func relative(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86_400))d ago"
    }
}

private struct HealthDot: View {
    let health: UnifiedSession.Health
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .help(health.rawValue)
    }
    private var color: Color {
        switch health {
        case .healthy: .green
        case .warning: .orange
        case .errored: .red
        case .stalled: .gray
        }
    }
}

private struct StatePill: View {
    let state: String
    var body: some View {
        Text(state)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    private var background: Color {
        switch state {
        case "running_tool": Color.blue.opacity(0.12)
        case "idle":         Color.secondary.opacity(0.12)
        case "completed":    Color.green.opacity(0.12)
        case "errored":      Color.red.opacity(0.12)
        default:             Color.secondary.opacity(0.10)
        }
    }
    private var foreground: Color {
        switch state {
        case "running_tool": .blue
        case "completed":    .green
        case "errored":      .red
        default:             .secondary
        }
    }
}
