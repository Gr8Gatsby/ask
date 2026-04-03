import SwiftUI

struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptManager.self) private var scriptManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            // Scripts
            scriptsSection
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            // Open app button
            Button {
                openWindow(id: "scripts")
                dismiss()
            } label: {
                Text("Open Ask")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(12)
        }
        .frame(width: 270)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: machineIcon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        if name.contains("macbook") { return "laptopcomputer" }
        if name.contains("mac pro") { return "macpro.gen3" }
        if name.contains("mac mini") { return "macmini" }
        if name.contains("mac studio") { return "macstudio" }
        if name.contains("imac") { return "desktopcomputer" }
        return "desktopcomputer"
    }

    private var statusColor: Color {
        if !settings.isConfigured { return .orange }
        if scriptManager.scripts.contains(where: { $0.status == .crashed || $0.status == .missingDependencies }) { return .orange }
        if scriptManager.scripts.contains(where: { $0.status == .running }) { return .green }
        return .secondary
    }

    // MARK: - Scripts

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scripts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                Spacer()
                Button {
                    scriptManager.reload()
                } label: {
                    Label("Restart Scripts", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rescan vault and restart all scripts")
            }

            if scriptManager.scripts.isEmpty {
                Text("No scripts configured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(scriptManager.scripts) { script in
                        ScriptRow(script: script, scriptManager: scriptManager)
                    }
                }
            }
        }
    }
}

// MARK: - Script row

private struct ScriptRow: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 22, height: 22)

            Text(script.name)
                .font(.subheadline)
                .foregroundStyle(script.isEnabled ? .primary : .secondary)

            Spacer()

            statusIcon

            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { enabled in
                    if enabled { scriptManager.enableScript(id: script.id) }
                    else { scriptManager.disableScript(id: script.id) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var iconView: some View {
        if let img = effectiveIcon {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.body)
                .foregroundStyle(script.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if script.status == .crashed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if script.status == .missingDependencies {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if script.lastEmitTime != nil {
            let isActive = scriptManager.activeBlocks[script.id]?.isEmpty == false
            Image(systemName: "icloud")
                .font(.caption)
                .foregroundStyle(isActive ? Color.green : Color(.tertiaryLabelColor))
        }
    }

    private var effectiveIcon: NSImage? {
        guard colorScheme == .dark, let svg = script.svgString else { return script.iconImage }
        return svgToWhiteMenuBar(svg) ?? script.iconImage
    }

    private func svgToWhiteMenuBar(_ svg: String) -> NSImage? {
        var s = svg
        s = s.replacingOccurrences(of: "currentColor", with: "white", options: .caseInsensitive)
        let darkColors = ["#000000", "#000", "black", "#111111", "#111",
                          "#1a1a1a", "#222222", "#222", "#333333", "#333"]
        for color in darkColors {
            for attr in ["fill", "stroke"] {
                s = s.replacingOccurrences(of: "\(attr)=\"\(color)\"", with: "\(attr)=\"white\"", options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr)='\(color)'",  with: "\(attr)='white'",  options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr):\(color)",    with: "\(attr):white",    options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr): \(color)",   with: "\(attr): white",   options: .caseInsensitive)
            }
        }
        guard let data = s.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }
}
