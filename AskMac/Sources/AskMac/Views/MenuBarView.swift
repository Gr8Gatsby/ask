import SwiftUI

struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobWatcher.self) private var watcher
    @Environment(HeartbeatService.self) private var heartbeat
    @Environment(ResponseWatcherService.self) private var responseWatcher
    @Environment(MessageWatcherService.self) private var messageWatcher

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            iPhoneSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 260)
    }

    private var header: some View {
        HStack {
            Image(systemName: "bolt")
            Text(settings.machineName.isEmpty ? "Ask" : settings.machineName)
                .font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var statusSection: some View {
        Group {
            if watcher.isExecuting, let job = watcher.currentJob {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Running", systemImage: "gearshape.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(job.prompt)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
            } else if !settings.isConfigured {
                Label("Setup required", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Label("Idle", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let lastBeat = heartbeat.lastHeartbeat {
                Text("Last sync \(lastBeat.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var iPhoneSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("iPhone")
                    .font(.subheadline)
                Text(iPhoneSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var iPhoneSubtitle: String {
        if let last = responseWatcher.lastResponseAt {
            return "Responded \(last.formatted(.relative(presentation: .named)))"
        }
        if let last = watcher.lastJobReceivedAt {
            return "Last job \(last.formatted(.relative(presentation: .named)))"
        }
        return "Paired via iCloud"
    }

    private var actions: some View {
        HStack {
            Button("Messages") { openWindow(id: "messages") }
                .buttonStyle(.plain)
                .font(.subheadline)
            Spacer()
            Button("History") { openWindow(id: "history") }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings") { openWindow(id: "settings") }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if !settings.isConfigured { return .orange }
        if watcher.isExecuting { return .blue }
        return .green
    }
}
