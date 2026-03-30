import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ActionsSettingsTab()
                .tabItem { Label("Actions", systemImage: "terminal") }
        }
        .frame(width: 480)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var showVaultPicker = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Machine") {
                LabeledContent("Name") {
                    TextField("Machine name", text: $settings.machineName)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Machine ID") {
                    Text(settings.machineID)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Scripts Vault") {
                LabeledContent("Directory") {
                    Text(settings.vaultPath?.abbreviatingWithTildeInPath ?? "Not set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Change Vault Directory…") { showVaultPicker = true }
            }

            if !settings.blockedDevices.isEmpty {
                Section("Blocked Devices") {
                    ForEach(settings.blockedDevices) { device in
                        HStack {
                            Image(systemName: "iphone.slash")
                                .foregroundStyle(.secondary)
                            Text(device.deviceName)
                                .font(.subheadline)
                            Spacer()
                            Button("Unblock") {
                                settings.unblockDevice(id: device.deviceID)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 240)
        .fileImporter(
            isPresented: $showVaultPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                settings.vaultPath = url
            }
        }
    }
}

// MARK: - Actions tab

private struct ActionsSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptManager.self) private var scriptManager

    var body: some View {
        Form {
            Section {
                if scriptManager.scripts.isEmpty {
                    Text("No scripts found in vault directory.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(scriptManager.scripts) { script in
                        ScriptSettingsRow(script: script, scriptManager: scriptManager)
                    }
                }
            } footer: {
                Text("Scripts are auto-discovered from your vault directory. Add a folder with a manifest.json to register a new script.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    scriptManager.reload()
                } label: {
                    Label("Reload Scripts", systemImage: "arrow.clockwise")
                }
                .help("Scan for new scripts and start any that aren't running yet")
            }
        }
    }
}

// MARK: - Script settings row

private struct ScriptSettingsRow: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    @State private var previewVisible = false

    private var liveBlocks: [LiveBlock] {
        Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: icon + name/id + preview toggle + enable toggle
            HStack(spacing: 10) {
                scriptIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.name).font(.body)
                    HStack(spacing: 4) {
                        Text(script.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if script.status == .crashed {
                            Label("Crashed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                Spacer()
                // Eye icon — show/hide live block previews
                Button {
                    previewVisible.toggle()
                } label: {
                    Image(systemName: previewVisible ? "eye.fill" : "eye")
                        .foregroundStyle(previewVisible ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .help(previewVisible ? "Hide preview" : "Show preview")

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
                .labelsHidden()
            }

            // Error detail when crashed
            if script.status == .crashed, let error = script.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Live block previews — shown only when eye is open
            if previewVisible && !liveBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(liveBlocks) { block in
                        BlockPreviewView(block: block) { value in
                            scriptManager.respondToBlock(
                                scriptID: script.id,
                                blockID: block.id,
                                value: value
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = script.iconImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .frame(width: 20)
                .foregroundStyle(script.isEnabled ? .primary : .tertiary)
        }
    }
}

// MARK: - Helpers

private extension String {
    var splitTrimmed: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func abbreviatingWithTildeInPath() -> String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        path.abbreviatingWithTildeInPath()
    }
}
