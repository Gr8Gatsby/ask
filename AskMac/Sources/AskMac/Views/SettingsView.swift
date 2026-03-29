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

    @State private var showAddAgent = false

    var body: some View {
        Form {
            Section {
                if settings.agents.isEmpty {
                    Text("No actions configured.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(settings.agents) { agent in
                        AgentRow(agent: agent) {
                            settings.removeAgent(id: agent.id)
                        }
                    }
                }
                Button("Add Action…") { showAddAgent = true }
            } footer: {
                Text("Scripts must be located within the vault directory.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
        .sheet(isPresented: $showAddAgent) {
            AddAgentView()
                .environment(settings)
        }
    }
}

// MARK: - Agent row

private struct AgentRow: View {
    let agent: AgentConfig
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.body)
                Text(agent.scriptName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                capabilityBadges
            }
            Spacer()
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var capabilityBadges: some View {
        HStack(spacing: 4) {
            if agent.capabilityNetwork   { badge("Network",    color: .blue)   }
            if agent.capabilitySubprocess { badge("Subprocess", color: .purple) }
            if !agent.capabilityReadPaths.isEmpty  { badge("Read",  color: .green)  }
            if !agent.capabilityWritePaths.isEmpty { badge("Write", color: .orange) }
        }
        .padding(.top, 2)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Add Agent

struct AddAgentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var availableScripts: [String] = []
    @State private var selectedScript: String? = nil
    @State private var name = ""
    @State private var capabilityNetwork = false
    @State private var capabilitySubprocess = false
    @State private var readPaths = ""
    @State private var writePaths = ""
    @State private var envKeys = ""
    @State private var timeout = 60

    private var isValid: Bool { selectedScript != nil && !name.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action Script") {
                    if availableScripts.isEmpty {
                        Text("No scripts found in vault directory.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Script", selection: $selectedScript) {
                            Text("Select…").tag(Optional<String>.none)
                            ForEach(availableScripts, id: \.self) { script in
                                Text(script).tag(Optional(script))
                            }
                        }
                        .onChange(of: selectedScript) { _, newValue in
                            if let script = newValue, name.isEmpty {
                                name = (script as NSString).deletingPathExtension
                            }
                        }
                    }
                    TextField("Display Name", text: $name)
                }

                Section("Capabilities") {
                    Toggle("Network access", isOn: $capabilityNetwork)
                    Toggle("Subprocess spawning", isOn: $capabilitySubprocess)
                    TextField("Read paths (comma-separated)", text: $readPaths)
                    TextField("Write paths (comma-separated)", text: $writePaths)
                    TextField("Keychain env keys (comma-separated)", text: $envKeys)
                    Stepper("Timeout: \(timeout)s", value: $timeout, in: 10...3600, step: 30)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let script = selectedScript else { return }
                        settings.addAgent(AgentConfig(
                            name: name,
                            scriptName: script,
                            capabilityNetwork: capabilityNetwork,
                            capabilitySubprocess: capabilitySubprocess,
                            capabilityReadPaths: readPaths.splitTrimmed,
                            capabilityWritePaths: writePaths.splitTrimmed,
                            capabilityEnvKeys: envKeys.splitTrimmed,
                            timeout: timeout
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
        .task { loadScripts() }
    }

    private func loadScripts() {
        guard let vault = settings.vaultPath else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: vault.path) else { return }
        let alreadyAdded = Set(settings.agents.map(\.scriptName))
        availableScripts = contents
            .filter { !$0.hasPrefix(".") && !alreadyAdded.contains($0) }
            .sorted()
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
