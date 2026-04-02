import SwiftUI
import UniformTypeIdentifiers

// MARK: - SVG dark-mode helper

/// Rewrites dark/black fill and stroke values to white so an SVG icon
/// renders legibly on dark brand card backgrounds.
private func svgToWhite(_ svg: String) -> NSImage? {
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

// MARK: - Top-level tab

private enum MacTab: String, CaseIterable {
    case scripts, feed, machine

    var label: String {
        switch self {
        case .scripts: "Scripts"
        case .feed:    "Feed"
        case .machine: "Machine"
        }
    }
}

// MARK: - Mac main window

struct MacScriptsView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(ActionHistoryService.self) private var actionHistory
    @Environment(AppSettings.self) private var settings

    @State private var activeTab: MacTab = .scripts

    var body: some View {
        Group {
            switch activeTab {
            case .scripts:
                ScriptsTabView()
                    .environment(scriptManager)
            case .feed:
                MacFeedView()
                    .environment(actionHistory)
            case .machine:
                MachineDetailView()
                    .environment(settings)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $activeTab) {
                    ForEach(MacTab.allCases, id: \.self) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if activeTab == .scripts {
                ToolbarItem(placement: .automatic) {
                    Button { scriptManager.reload() } label: {
                        Label("Reload Scripts", systemImage: "arrow.clockwise")
                    }
                    .help("Scan for new scripts and start any that aren't running yet")
                }
            }
        }
    }
}

// MARK: - Scripts tab (sidebar + detail)

private struct ScriptsTabView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @State private var selectedScriptID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedScriptID) {
                if scriptManager.scripts.isEmpty {
                    Text("No scripts found in vault directory.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 4)
                } else {
                    ForEach(scriptManager.scripts) { script in
                        ScriptSidebarRow(script: script, scriptManager: scriptManager)
                            .tag(script.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let id = selectedScriptID,
               let script = scriptManager.scripts.first(where: { $0.id == id }) {
                ScriptDetailView(script: script, scriptManager: scriptManager)
            } else {
                ContentUnavailableView(
                    "Select a Script",
                    systemImage: "terminal",
                    description: Text("Choose a script from the sidebar to view its active blocks.")
                )
            }
        }
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
        return svgToWhite(svg) ?? script.iconImage
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
                scriptCard

                if script.status == .crashed, let error = script.lastError {
                    crashBanner(error)
                }

                if liveBlocks.isEmpty {
                    ContentUnavailableView(
                        "No Active Blocks",
                        systemImage: "rectangle.stack",
                        description: Text("This script hasn't emitted any blocks yet.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
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
    }

    // MARK: Script card

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + info + toggle
            HStack(alignment: .center, spacing: 14) {
                scriptIcon
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(script.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(brandForegroundPrimary)

                        if let version = script.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(brandForegroundSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(brandForegroundSecondary.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        typeBadge
                    }

                    if let desc = script.description {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(brandForegroundSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(script.id)
                            .font(.caption)
                            .foregroundStyle(brandForegroundTertiary)
                            .fontDesign(.monospaced)

                        if let schedule = script.schedule {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(schedule)
                                    .font(.caption2)
                                    .fontDesign(.monospaced)
                            }
                            .foregroundStyle(brandForegroundTertiary)
                        }

                        Spacer()

                        statusBadge
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
                .toggleStyle(.switch)
                .controlSize(.regular)
            }
            .padding(16)

            // Dependencies section
            if !script.requires.isEmpty {
                Divider()
                    .opacity(0.3)
                dependenciesSection
                    .padding(16)
            }
        }
        .background(brandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .ifLet(brandColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    // MARK: Badges

    @ViewBuilder
    private var typeBadge: some View {
        let isFeed = script.scriptType == "feed"
        Text(isFeed ? "Feed" : "Tile")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(brandAccent ?? brandForegroundSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((brandAccent ?? brandForegroundSecondary).opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(script.status.label)
                .font(.caption)
                .foregroundStyle(brandForegroundSecondary)
        }
    }

    private var statusColor: Color {
        switch script.status {
        case .running:              .green
        case .crashed:              .red
        case .missingDependencies:  .orange
        case .starting:             .yellow
        case .stopped:              .secondary
        }
    }

    // MARK: Dependencies

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dependencies")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(script.requires, id: \.id) { dep in
                let isMissing = script.missingDeps.contains { $0.id == dep.id }
                HStack(spacing: 8) {
                    Image(systemName: isMissing ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isMissing ? .red : .green)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(dep.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(brandForegroundPrimary)
                        if isMissing, let install = dep.install {
                            Text(install)
                                .font(.caption2)
                                .foregroundStyle(brandForegroundTertiary)
                                .fontDesign(.monospaced)
                        } else if !isMissing {
                            Text("Installed")
                                .font(.caption2)
                                .foregroundStyle(brandForegroundTertiary)
                        }
                    }

                    Spacer()

                    if isMissing {
                        Button("Retry") {
                            scriptManager.retryDependencies(id: script.id)
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: Brand colors

    @Environment(\.colorScheme) private var colorScheme

    private var brandBackground: Color {
        switch script.id {
        case "claudecode-controller":
            return colorScheme == .dark
                ? Color(red: 0.15, green: 0.13, blue: 0.11)
                : Color(red: 250/255, green: 249/255, blue: 245/255)
        case "github":
            return Color(red: 0x24/255, green: 0x29/255, blue: 0x2F/255)
        default:
            return Color.secondary.opacity(0.07)
        }
    }

    private var brandColorScheme: ColorScheme? {
        switch script.id {
        case "github": .dark
        default: nil
        }
    }

    private var brandAccent: Color? {
        switch script.id {
        case "claudecode-controller": Color(red: 202/255, green: 124/255, blue: 94/255)
        case "github":               Color(red: 0x09/255, green: 0x69/255, blue: 0xDA/255)
        default: nil
        }
    }

    private var brandForegroundPrimary: Color {
        switch script.id {
        case "github": .white
        default: .primary
        }
    }

    private var brandForegroundSecondary: Color {
        switch script.id {
        case "github": Color(.secondaryLabelColor).opacity(0.85)
        default: .secondary
        }
    }

    private var brandForegroundTertiary: Color {
        switch script.id {
        case "github": Color(.tertiaryLabelColor)
        default: Color(.tertiaryLabelColor)
        }
    }

    // MARK: Icon

    @ViewBuilder
    private var scriptIcon: some View {
        if let img = cardIcon {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .grayscale(script.isEnabled ? 0 : 1)
                .opacity(script.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: script.icon ?? "terminal.fill")
                .font(.largeTitle)
                .foregroundStyle(script.isEnabled ? brandForegroundPrimary : brandForegroundTertiary)
        }
    }

    /// Icon image adapted for the card's brand color scheme.
    /// Dark brand cards (e.g. GitHub) get SVG strokes recoloured to white.
    private var cardIcon: NSImage? {
        if brandColorScheme == .dark, let svg = script.svgString {
            return svgToWhite(svg) ?? script.iconImage
        }
        return script.iconImage
    }

    // MARK: Crash banner

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

// MARK: - Machine detail view

private struct MachineDetailView: View {
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
        .navigationTitle("Machine")
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

// MARK: - View helpers

private extension View {
    /// Applies a transform only when the optional value is non-nil.
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
