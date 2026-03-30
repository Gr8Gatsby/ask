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
    @Environment(AgentManager.self) private var agentManager

    @State private var showAddAgent = false
    @State private var editingAgent: AgentConfig? = nil

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

            Section(
                header: Text("Agents"),
                footer: Text("Agents run on-demand jobs sent from your iPhone. Each agent points to a script in your vault and declares its capabilities.")
            ) {
                if agentManager.agents.isEmpty {
                    Text("No agents configured.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(agentManager.agents) { agent in
                        AgentSettingsRow(agent: agent) {
                            editingAgent = agent
                        } onDelete: {
                            Task { await agentManager.delete(id: agent.id) }
                        }
                    }
                }
                Button("Add Agent…") { showAddAgent = true }
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
        .sheet(isPresented: $showAddAgent) {
            AddEditAgentSheet(vaultPath: settings.vaultPath) { config in
                Task { await agentManager.add(config) }
            }
        }
        .sheet(item: $editingAgent) { agent in
            AddEditAgentSheet(existing: agent, vaultPath: settings.vaultPath) { updated in
                Task { await agentManager.update(updated) }
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

// MARK: - Agent settings row

private struct AgentSettingsRow: View {
    let agent: AgentConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.body)
                Text(agent.scriptName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            capabilitySummary
            Button("Edit") { onEdit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var capabilitySummary: some View {
        HStack(spacing: 4) {
            if agent.capabilityNetwork {
                capabilityChip("Network", color: .blue)
            }
            if agent.capabilitySubprocess {
                capabilityChip("Subprocess", color: .purple)
            }
        }
    }

    private func capabilityChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Add / edit agent sheet

private struct AddEditAgentSheet: View {
    let existing: AgentConfig?
    let vaultPath: URL?
    let onSave: (AgentConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var scriptName: String
    @State private var timeout: Int
    @State private var capabilityNetwork: Bool
    @State private var capabilitySubprocess: Bool
    @State private var readPaths: [String]
    @State private var writePaths: [String]
    @State private var envKeys: [String]
    @State private var showScriptPicker = false

    @State private var newReadPath = ""
    @State private var newWritePath = ""
    @State private var newEnvKey = ""

    init(existing: AgentConfig? = nil, vaultPath: URL?, onSave: @escaping (AgentConfig) -> Void) {
        self.existing = existing
        self.vaultPath = vaultPath
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _scriptName = State(initialValue: existing?.scriptName ?? "")
        _timeout = State(initialValue: existing?.timeout ?? 60)
        _capabilityNetwork = State(initialValue: existing?.capabilityNetwork ?? false)
        _capabilitySubprocess = State(initialValue: existing?.capabilitySubprocess ?? false)
        _readPaths = State(initialValue: existing?.capabilityReadPaths ?? [])
        _writePaths = State(initialValue: existing?.capabilityWritePaths ?? [])
        _envKeys = State(initialValue: existing?.capabilityEnvKeys ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "Add Agent" : "Edit Agent")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || scriptName.isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section("Identity") {
                    LabeledContent("Name") {
                        TextField("e.g. Build Runner", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Script") {
                        HStack {
                            Text(scriptName.isEmpty ? "Not selected" : scriptName)
                                .foregroundStyle(scriptName.isEmpty ? .tertiary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { showScriptPicker = true }
                                .disabled(vaultPath == nil)
                        }
                    }
                }

                Section("Limits") {
                    Stepper("Timeout: \(timeout)s", value: $timeout, in: 10...3600, step: 10)
                }

                Section("Capabilities") {
                    Toggle("Network access", isOn: $capabilityNetwork)
                    Toggle("Subprocess (spawn child processes)", isOn: $capabilitySubprocess)
                }

                Section("Read Paths") {
                    ForEach(readPaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { readPaths.removeAll { $0 == path } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Add path…", text: $newReadPath)
                        Button("Add") {
                            let p = newReadPath.trimmingCharacters(in: .whitespaces)
                            if !p.isEmpty { readPaths.append(p); newReadPath = "" }
                        }.disabled(newReadPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Write Paths") {
                    ForEach(writePaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { writePaths.removeAll { $0 == path } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Add path…", text: $newWritePath)
                        Button("Add") {
                            let p = newWritePath.trimmingCharacters(in: .whitespaces)
                            if !p.isEmpty { writePaths.append(p); newWritePath = "" }
                        }.disabled(newWritePath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section(
                    header: Text("Environment Keys"),
                    footer: Text("Named items from macOS Keychain (Generic Password, service = key name) injected as environment variables.")
                ) {
                    ForEach(envKeys, id: \.self) { key in
                        HStack {
                            Text(key).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { envKeys.removeAll { $0 == key } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Keychain item name…", text: $newEnvKey)
                        Button("Add") {
                            let k = newEnvKey.trimmingCharacters(in: .whitespaces)
                            if !k.isEmpty { envKeys.append(k); newEnvKey = "" }
                        }.disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 560)
        .fileImporter(
            isPresented: $showScriptPicker,
            allowedContentTypes: [.unixExecutable, .shellScript, .item],
            onCompletion: { result in
                if case .success(let url) = result {
                    _ = url.startAccessingSecurityScopedResource()
                    // Store relative path within vault
                    if let vault = vaultPath {
                        let rel = url.path.hasPrefix(vault.path + "/")
                            ? String(url.path.dropFirst(vault.path.count + 1))
                            : url.lastPathComponent
                        scriptName = rel
                    } else {
                        scriptName = url.lastPathComponent
                    }
                }
            }
        )
    }

    private func save() {
        var config = existing ?? AgentConfig(name: "", scriptName: "")
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.scriptName = scriptName
        config.timeout = timeout
        config.capabilityNetwork = capabilityNetwork
        config.capabilitySubprocess = capabilitySubprocess
        config.capabilityReadPaths = readPaths
        config.capabilityWritePaths = writePaths
        config.capabilityEnvKeys = envKeys
        onSave(config)
        dismiss()
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
