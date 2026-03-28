import SwiftUI

struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobWatcher.self) private var watcher
    @Environment(HeartbeatService.self) private var heartbeat

    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 260)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(settings)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.accentColor)
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

    private var actions: some View {
        HStack {
            Button("Settings") { showSettings = true }
                .buttonStyle(.plain)
                .font(.subheadline)
            Spacer()
            Button("Quit Ask") { NSApplication.shared.terminate(nil) }
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
