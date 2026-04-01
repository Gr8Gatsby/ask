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

private struct AgentSession: Identifiable {
    let id = UUID()
    let controller: String
    let sessionID: String
    let project: String
    let cwd: String
    let tty: String
}

private struct LiveProcess: Identifiable {
    let id = UUID()
    let controller: String
    let pid: String
    let tty: String
    let comm: String
}

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var showVaultPicker = false
    @State private var agentSessions: [AgentSession] = []
    @State private var liveProcesses: [LiveProcess] = []

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

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

            Section {
                if agentSessions.isEmpty {
                    Text("No tracked sessions yet.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(agentSessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(s.controller).font(.caption).fontWeight(.medium)
                                Text(s.project).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(s.tty.isEmpty ? "no TTY" : s.tty)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(s.tty.isEmpty ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                            Text(s.cwd)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                HStack {
                    Text("Agent Sessions")
                    Spacer()
                    Button("Refresh") { refreshSessions() }
                        .font(.caption)
                }
            }

            Section("Live Processes") {
                if liveProcesses.isEmpty {
                    Text("No Claude or Codex processes found.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(liveProcesses) { p in
                        HStack {
                            Text(p.comm).font(.caption).fontWeight(.medium)
                            Spacer()
                            Text("PID \(p.pid)  TTY \(p.tty)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("AskMac Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 240)
        .onAppear { refreshSessions() }
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

    private func refreshSessions() {
        let statusFiles: [(controller: String, path: String)] = [
            ("Claude Code", NSHomeDirectory() + "/.ask/status/claudecode-controller.json"),
            ("Codex",       NSHomeDirectory() + "/.ask/status/codex-controller.json"),
        ]
        var sessions: [AgentSession] = []
        var procs: [LiveProcess] = []
        for (controller, path) in statusFiles {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let list = json["sessions"] as? [[String: Any]] {
                for s in list {
                    sessions.append(AgentSession(
                        controller: controller,
                        sessionID: s["session_id"] as? String ?? "",
                        project:   s["project"]    as? String ?? "",
                        cwd:       s["cwd"]        as? String ?? "",
                        tty:       s["tty"]        as? String ?? ""
                    ))
                }
            }
            if let list = json["live_processes"] as? [[String: Any]] {
                for p in list {
                    procs.append(LiveProcess(
                        controller: controller,
                        pid:  p["pid"]  as? String ?? "",
                        tty:  p["tty"]  as? String ?? "",
                        comm: p["comm"] as? String ?? ""
                    ))
                }
            }
        }
        agentSessions = sessions
        liveProcesses = procs
    }
}

// MARK: - Actions tab

private struct ActionsSettingsTab: View {
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
                        if let version = script.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if script.status == .crashed {
                            Label("Crashed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if let desc = script.description {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
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
