import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var machineName = ""
    @State private var showVaultPicker = false
    @State private var showAddAgent = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Machine") {
                    TextField("Name", text: $settings.machineName)
                    LabeledContent("Machine ID") {
                        Text(settings.machineID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Scripts Vault") {
                    if let vault = settings.vaultPath {
                        LabeledContent("Directory") {
                            Text(vault.abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Button(settings.vaultPath == nil ? "Choose Vault Directory…" : "Change Vault Directory…") {
                        showVaultPicker = true
                    }
                }

                Section {
                    ForEach(settings.agents) { agent in
                        AgentRow(agent: agent)
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { settings.removeAgent(id: settings.agents[$0].id) }
                    }
                    Button("Add Agent…") { showAddAgent = true }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Scripts must be located within the vault directory.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ask Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showVaultPicker,
                allowedContentTypes: [.folder]
            ) { result in
                if case .success(let url) = result {
                    _ = url.startAccessingSecurityScopedResource()
                    settings.vaultPath = url
                }
            }
            .sheet(isPresented: $showAddAgent) {
                AddAgentView()
                    .environment(settings)
            }
        }
        .frame(minWidth: 440, minHeight: 520)
    }
}

// MARK: - Agent row

private struct AgentRow: View {
    let agent: AgentConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(agent.name).font(.body)
            Text(agent.scriptName)
                .font(.caption)
                .foregroundStyle(.secondary)
            capabilityBadges
        }
        .padding(.vertical, 2)
    }

    private var capabilityBadges: some View {
        HStack(spacing: 4) {
            if agent.capabilityNetwork {
                badge("Network", color: .blue)
            }
            if agent.capabilitySubprocess {
                badge("Subprocess", color: .purple)
            }
            if !agent.capabilityReadPaths.isEmpty {
                badge("Read", color: .green)
            }
            if !agent.capabilityWritePaths.isEmpty {
                badge("Write", color: .orange)
            }
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

    @State private var name = ""
    @State private var scriptName = ""
    @State private var capabilityNetwork = false
    @State private var capabilitySubprocess = false
    @State private var readPaths = ""
    @State private var writePaths = ""
    @State private var envKeys = ""
    @State private var timeout = 60

    private var isValid: Bool {
        !name.isEmpty && !scriptName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Agent Name", text: $name)
                    TextField("Script Filename", text: $scriptName)
                        .font(.system(.body, design: .monospaced))
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
            .navigationTitle("Add Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let agent = AgentConfig(
                            name: name,
                            scriptName: scriptName,
                            capabilityNetwork: capabilityNetwork,
                            capabilitySubprocess: capabilitySubprocess,
                            capabilityReadPaths: readPaths.splitTrimmed,
                            capabilityWritePaths: writePaths.splitTrimmed,
                            capabilityEnvKeys: envKeys.splitTrimmed,
                            timeout: timeout
                        )
                        settings.addAgent(agent)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 460)
    }
}

// MARK: - Helpers

private extension String {
    var splitTrimmed: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
