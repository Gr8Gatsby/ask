import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar selection

private enum SidebarItem: Hashable {
    case feed
    case script(String)
}

// MARK: - Mac Scripts Home

struct MacScriptsView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(ActionHistoryService.self) private var actionHistory
    @Environment(AppSettings.self) private var settings

    @State private var selectedItem: SidebarItem? = nil
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingSettings) {
            GeneralSettingsView()
                .environment(settings)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedItem) {
            Section {
                Label("Feed", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.feed)
            }

            Section("Scripts") {
                if scriptManager.scripts.isEmpty {
                    Text("No scripts found in vault directory.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 4)
                } else {
                    ForEach(scriptManager.scripts) { script in
                        ScriptSidebarRow(script: script, scriptManager: scriptManager)
                            .tag(SidebarItem.script(script.id))
                    }
                }
            }
        }
        .navigationTitle("Ask")
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { scriptManager.reload() } label: {
                    Label("Reload Scripts", systemImage: "arrow.clockwise")
                }
                .help("Scan for new scripts and start any that aren't running yet")
            }
            ToolbarItem(placement: .automatic) {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("General settings")
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedItem {
        case .feed:
            MacFeedView()
                .environment(actionHistory)
        case .script(let id):
            if let script = scriptManager.scripts.first(where: { $0.id == id }) {
                ScriptDetailView(script: script, scriptManager: scriptManager)
            } else {
                scriptPlaceholder
            }
        case nil:
            scriptPlaceholder
        }
    }

    private var scriptPlaceholder: some View {
        ContentUnavailableView(
            "Select a Script",
            systemImage: "terminal",
            description: Text("Choose a script from the sidebar to view its active blocks.")
        )
    }
}

// MARK: - Sidebar row

private struct ScriptSidebarRow: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            scriptIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(script.name)
                    .font(.body)
                    .foregroundStyle(script.isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(script.status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { enabled in
                    if enabled { scriptManager.enableScript(id: script.id) }
                    else { scriptManager.disableScript(id: script.id) }
                }
            ))
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch script.status {
        case .running:              .green
        case .crashed:              .red
        case .missingDependencies:  .orange
        case .starting:             .yellow
        case .stopped:              Color(.tertiaryLabelColor)
        }
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = effectiveIcon {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.title3)
                .foregroundStyle(script.isEnabled ? .primary : .tertiary)
        }
    }

    private var effectiveIcon: NSImage? {
        guard colorScheme == .dark, let svg = script.svgString else { return script.iconImage }
        return darkModeImage(from: svg) ?? script.iconImage
    }

    private func darkModeImage(from svg: String) -> NSImage? {
        var s = svg
        s = s.replacingOccurrences(of: "currentColor", with: "white", options: .caseInsensitive)
        let darkColors = ["#000000", "#000", "black", "#111111", "#111",
                          "#1a1a1a", "#222222", "#222", "#333333", "#333"]
        for color in darkColors {
            for attr in ["fill", "stroke"] {
                s = s.replacingOccurrences(of: "\(attr)=\"\(color)\"", with: "\(attr)=\"white\"", options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr)='\(color)'", with: "\(attr)='white'", options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr):\(color)", with: "\(attr):white", options: .caseInsensitive)
                s = s.replacingOccurrences(of: "\(attr): \(color)", with: "\(attr): white", options: .caseInsensitive)
            }
        }
        guard let data = s.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Script detail view

private struct ScriptDetailView: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    private var liveBlocks: [LiveBlock] {
        Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scriptHeader

                Divider()

                if script.status == .crashed, let error = script.lastError {
                    crashBanner(error)
                } else if script.status == .missingDependencies && !script.missingDeps.isEmpty {
                    missingDepsBanner
                }

                if liveBlocks.isEmpty {
                    ContentUnavailableView(
                        "No Active Blocks",
                        systemImage: "rectangle.stack",
                        description: Text("This script hasn't emitted any blocks yet.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
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
            .padding(20)
        }
        .navigationTitle(script.name)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(script.isEnabled ? "Enabled" : "Disabled", isOn: Binding(
                    get: { script.isEnabled },
                    set: { enabled in
                        if enabled { scriptManager.enableScript(id: script.id) }
                        else { scriptManager.disableScript(id: script.id) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var scriptHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            scriptIcon
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(script.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let version = script.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(script.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)

                    if let desc = script.description {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = script.iconImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.largeTitle)
                .foregroundStyle(script.isEnabled ? .primary : .tertiary)
        }
    }

    private func crashBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Script crashed")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var missingDepsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Missing dependencies")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            ForEach(script.missingDeps, id: \.id) { dep in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(dep.name) not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let install = dep.install {
                        Text(install)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fontDesign(.monospaced)
                    }
                }
            }
            Button("Retry") {
                scriptManager.retryDependencies(id: script.id)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Feed view

private struct MacFeedView: View {
    @Environment(ActionHistoryService.self) private var history

    var body: some View {
        Group {
            if history.events.isEmpty {
                ContentUnavailableView(
                    "No Feed Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Script interactions and lifecycle events will appear here.")
                )
            } else {
                List {
                    ForEach(history.events) { event in
                        FeedEventRow(event: event)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Feed")
    }
}

private struct FeedEventRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.source)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fontDesign(.monospaced)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - General settings sheet

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

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

        VStack(spacing: 0) {
            Form {
                Section("Machine") {
                    LabeledContent("Name") {
                        HStack(spacing: 6) {
                            TextField(AppSettings.defaultMachineName, text: $settings.machineName)
                                .multilineTextAlignment(.trailing)
                                .onAppear {
                                    if settings.machineName.isEmpty {
                                        settings.machineName = AppSettings.defaultMachineName
                                    }
                                }
                            if settings.machineName != AppSettings.defaultMachineName {
                                Button {
                                    settings.machineName = AppSettings.defaultMachineName
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Reset to Mac computer name")
                            }
                        }
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
        }
        .frame(width: 480, height: 520)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
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

// MARK: - Helpers

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

private extension String {
    func abbreviatingWithTildeInPath() -> String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        path.abbreviatingWithTildeInPath()
    }
}
