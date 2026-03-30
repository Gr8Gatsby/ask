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
            if !heartbeat.connectedDevices.isEmpty {
                Divider()
                devicesSection
            }
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
                HStack(spacing: 4) {
                    Image(systemName: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("iCloud sync")
                        .foregroundStyle(.secondary)
                    if let lastBeat = heartbeat.lastHeartbeat {
                        Text("·").foregroundStyle(.tertiary)
                        Text(lastBeat, style: .relative).foregroundStyle(.tertiary)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(heartbeat.connectedDevices, id: \.deviceID) { device in
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.deviceName)
                            .font(.subheadline)
                        Text("Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { true },
                        set: { enabled in
                            if !enabled { heartbeat.revokeDevice(device) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
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
                    ScriptRow(script: script, scriptManager: scriptManager)
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

// MARK: - Script row

private struct ScriptRow: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    var body: some View {
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
            if script.status == .crashed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
