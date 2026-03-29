import SwiftUI

struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HeartbeatService.self) private var heartbeat
    @Environment(MessageWatcherService.self) private var messageWatcher
    @Environment(ScriptManager.self) private var scriptManager

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            scriptsSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 260)
    }

    private var header: some View {
        HStack {
            Image(systemName: machineIcon)
            Text(settings.machineName.isEmpty ? "Ask" : settings.machineName)
                .font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var machineIcon: String {
        let name = settings.machineName.lowercased()
        if name.contains("macbook pro") || name.contains("macbook air") || name.contains("macbook") {
            return "laptopcomputer"
        } else if name.contains("mac pro") {
            return "macpro.gen3"
        } else if name.contains("mac mini") {
            return "macmini"
        } else if name.contains("mac studio") {
            return "macstudio"
        } else if name.contains("imac") {
            return "desktopcomputer"
        }
        return "desktopcomputer"
    }

    private var statusSection: some View {
        Group {
            if !settings.isConfigured {
                Label("Setup required", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Label("Ready", systemImage: "checkmark.circle")
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

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scriptManager.scripts.isEmpty {
                Text("No scripts configured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(scriptManager.scripts) { script in
                    HStack(spacing: 8) {
                        if let img = script.iconImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .grayscale(script.isEnabled ? 0 : 1)
                                .opacity(script.isEnabled ? 1 : 0.4)
                        } else {
                            Image(systemName: script.icon ?? "terminal.fill")
                                .font(.caption)
                                .foregroundStyle(script.isEnabled ? .secondary : .tertiary)
                                .frame(width: 14)
                        }
                        Text(script.name)
                            .font(.subheadline)
                            .foregroundStyle(script.isEnabled ? .primary : .secondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { script.isEnabled },
                            set: { enabled in
                                if enabled {
                                    scriptManager.enableScript(id: script.id)
                                } else {
                                    scriptManager.disableScript(id: script.id)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                }
            }
        }
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
        if scriptManager.scripts.contains(where: { $0.status == .running }) { return .green }
        return .secondary
    }
}
