import SwiftUI

struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptManager.self) private var scriptManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            scriptsSection
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            footer
                .padding(12)
        }
        .frame(width: 360)
        .sheet(item: Binding(
            get: { scriptManager.scriptPendingConsent },
            set: { _ in }
        )) { consent in
            PermissionConsentView(
                consent: consent,
                onAllow: { scriptManager.approvePermissions(scriptID: consent.scriptID) },
                onDeny:  { scriptManager.denyPermissions(scriptID: consent.scriptID) }
            )
        }
        .onAppear {
            #if DEBUG
            if MacUITestingSupport.isUITesting {
                openWindow(id: "scripts")
            }
            #endif
        }
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
        if scriptManager.scripts.contains(where: {
            $0.status == .crashed || $0.status == .missingDependencies ||
            $0.status == .permissionDenied || $0.status == .pendingConsent
        }) { return .orange }
        if scriptManager.scripts.contains(where: { $0.status == .running }) { return .green }
        return .secondary
    }

    // MARK: - Scripts

    private var displayedScripts: [ManagedScript] {
        let all = scriptManager.scripts.filter { !$0.isSystem }
        let pins = settings.pinnedScripts
        if pins.isEmpty { return all }
        return pins.compactMap { id in all.first { $0.id == id } }
    }

    private var hasPins: Bool { !settings.pinnedScripts.isEmpty }

    private var unpinnedCount: Int {
        let all = scriptManager.scripts.filter { !$0.isSystem }
        return all.count - displayedScripts.count
    }

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Migration banner — shown once after permissions enforcement is enabled
            if settings.showPermissionMigrationBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Script permissions updated")
                            .font(.caption).fontWeight(.medium)
                        Text("Existing scripts were granted their declared permissions.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        settings.showPermissionMigrationBanner = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Section header
            HStack {
                Text(hasPins ? "Pinned" : "Scripts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                Spacer()
                Button {
                    scriptManager.reload()
                } label: {
                    Label("Restart All", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rescan vault and restart all scripts")
            }

            if displayedScripts.isEmpty {
                Text("No scripts configured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else if hasPins {
                // Tile grid for pinned scripts
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(displayedScripts) { script in
                        ScriptTile(script: script, scriptManager: scriptManager)
                            .contextMenu { pinMenuItem(for: script) }
                    }
                }
            } else {
                // List view for all scripts
                VStack(spacing: 0) {
                    ForEach(displayedScripts) { script in
                        ScriptRow(script: script, scriptManager: scriptManager)
                            .contextMenu { pinMenuItem(for: script) }
                    }
                }
            }

            if hasPins && unpinnedCount > 0 {
                Button {
                    openWindow(id: "scripts")
                    dismiss()
                    activateAskWindow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                        Text("\(unpinnedCount) more script\(unpinnedCount == 1 ? "" : "s") hidden  ·  Manage pins")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
            }

            Button {
                openWindow(id: "scripts")
                dismiss()
                activateAskWindow()
            } label: {
                Text("Open Ask")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func activateAskWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows
                .first { $0.title == "Ask" }?
                .makeKeyAndOrderFront(nil)
        }
    }

    @ViewBuilder
    private func pinMenuItem(for script: ManagedScript) -> some View {
        Button {
            scriptManager.restartScript(id: script.id)
        } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        Divider()
        if settings.isPinned(script.id) {
            Button {
                settings.unpinScript(script.id)
            } label: {
                Label("Remove from Menu Bar", systemImage: "pin.slash")
            }
        } else {
            Button {
                settings.pinScript(script.id)
            } label: {
                Label("Pin to Menu Bar", systemImage: "pin")
            }
        }
    }
}

// MARK: - Script tile (pinned grid view)

private struct ScriptTile: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                iconView
                    .frame(width: 22, height: 22)
                    .padding(.top, 4)

                statusDot
                    .offset(x: 4, y: 0)
            }

            Text(script.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(script.isEnabled ? .primary : .secondary)

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
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.quaternaryLabelColor).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    private var statusDot: some View {
        if script.status == .crashed {
            Circle().fill(Color.red).frame(width: 8, height: 8)
        } else if script.status == .missingDependencies || script.status == .permissionDenied || script.status == .pendingConsent {
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        } else if script.isEnabled {
            let isActive = scriptManager.activeBlocks[script.id]?.isEmpty == false
            Circle()
                .fill(isActive ? Color.green : Color(.tertiaryLabelColor))
                .frame(width: 8, height: 8)
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

// MARK: - Script row (list view)

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
        } else if script.status == .permissionDenied {
            Image(systemName: "lock.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if script.status == .pendingConsent {
            Image(systemName: "lock.badge.clock")
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
