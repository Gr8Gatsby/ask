import SwiftUI
import UniformTypeIdentifiers

// MARK: - Copy Button

private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy path")
    }
}

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
    case scripts, feed, blocks, messages, machine

    var icon: String {
        switch self {
        case .scripts:  "terminal"
        case .feed:     "clock.arrow.circlepath"
        case .blocks:   "rectangle.stack"
        case .messages: "bubble.left.and.bubble.right"
        case .machine:  "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .scripts:  "Scripts"
        case .feed:     "Feed"
        case .blocks:   "Blocks"
        case .messages: "Messages"
        case .machine:  "Machine"
        }
    }
}

// MARK: - Mac main window

struct MacScriptsView: View {
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(ActionHistoryService.self) private var actionHistory
    @Environment(AppSettings.self) private var settings
    @Environment(CloudKitService.self) private var cloudKit
    @Environment(MessageWatcherService.self) private var messageWatcher

    @State private var activeTab: MacTab = .scripts
    @State private var builderBlocks: [BuilderBlock] = []
    @State private var builderShowJSON = true

    var body: some View {
        Group {
            switch activeTab {
            case .scripts:
                ScriptsTabView()
                    .environment(scriptManager)
            case .feed:
                MacFeedView()
                    .environment(actionHistory)
            case .blocks:
                BlocksBuilderView(blocks: $builderBlocks, showJSON: $builderShowJSON)
            case .messages:
                MacMessagesView()
                    .environment(settings)
                    .environment(cloudKit)
                    .environment(messageWatcher)
            case .machine:
                MachineDetailView()
                    .environment(settings)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $activeTab) {
                    ForEach(MacTab.allCases, id: \.self) { tab in
                        Image(systemName: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(activeTab.label)
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
                    Text(statusLabel)
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

    private var statusLabel: String {
        script.status == .stopped && script.scriptType == "feed" ? "Scheduled" : script.status.label
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

// MARK: - Card preview axes

private enum CardColorSchemePreview: String, CaseIterable {
    case light = "Light"
    case dark  = "Dark"
}

// MARK: - Script detail view

private struct ScriptDetailView: View {
    let script: ManagedScript
    let scriptManager: ScriptManager

    @Environment(AppSettings.self) private var settings

    @State private var cardFlipped = false
    @State private var previewBranded = true
    @State private var previewScheme: CardColorSchemePreview = .light
    @State private var showTools = false
    @State private var checkDrafts: [String: String] = [:]
    @State private var checkResults: [String: Bool?] = [:]
    @State private var checkOutput: [String: String] = [:]
    @State private var checkRunning: Set<String> = []
    @State private var savedDeps: Set<String> = []
    // Schedule editor state (feed scripts)
    @State private var scheduleHourDisplay: Int = 9   // 1–12
    @State private var scheduleIsPM: Bool = false
    @State private var scheduleMinute: Int = 0         // 0, 15, 30, 45
    @State private var scheduleDays: Set<Int> = []     // 0=Sun…6=Sat; empty = every day
    @State private var scheduleSaved = false

    private var liveBlocks: [LiveBlock] {
        Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scriptCard

                // Toggle bar — only shown when the script declares tools
                if !script.tools.isEmpty {
                    Picker("", selection: $showTools) {
                        Text("Live Preview").tag(false)
                        Text("Methods").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if showTools {
                    scriptToolsPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .navigationTitle(script.name)
    }

    // MARK: Script tools panel

    @ViewBuilder
    private var scriptToolsPanel: some View {
        if !script.tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tools")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            if let desc = tool.description {
                                Text(desc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }

                            if let params = tool.params, !params.isEmpty {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(params, id: \.name) { param in
                                        HStack(spacing: 4) {
                                            Text(param.name)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            if let type = param.type {
                                                Text(type)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            if param.required != true {
                                                Text("opt")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .italic()
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: Script card

    private var scriptCard: some View {
        Group {
            if cardFlipped {
                scriptCardBack
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
            } else {
                scriptCardFront
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210)
        .animation(.easeInOut(duration: 0.2), value: cardFlipped)
    }

    private var scriptCardFront: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + name/info
            HStack(alignment: .top, spacing: 14) {
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
            }
            .padding(16)

            // Dependencies section
            if !script.requires.isEmpty {
                Divider()
                    .opacity(0.3)
                dependenciesSection
                    .padding(16)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(brandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .ifLet(brandColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                Button {
                    if let dir = script.manifestPath?.deletingLastPathComponent() {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.body)
                        .foregroundStyle(brandForegroundPrimary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if script.scriptType == "feed" && script.schedule != nil {
                    Button {
                        withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                    } label: {
                        Image(systemName: "clock")
                            .font(.body)
                            .foregroundStyle(brandForegroundPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Edit schedule")
                }

                if !script.requires.isEmpty {
                    Button {
                        withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                    } label: {
                        Image(systemName: "checklist")
                            .font(.body)
                            .foregroundStyle(brandForegroundPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Edit dependency checks")
                }
            }
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                // Theme buttons — explicit colours so they're always visible on any card background
                HStack(spacing: 3) {
                    ForEach(CardColorSchemePreview.allCases, id: \.self) { s in
                        Button {
                            previewScheme = s
                            if cardFlipped { cardFlipped = false }
                        } label: {
                            Text(s.rawValue)
                                .font(.caption)
                                .fontWeight(previewScheme == s ? .semibold : .regular)
                                .foregroundStyle(previewScheme == s ? Color.white : Color(white: 0.2))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(previewScheme == s ? Color.accentColor : Color(white: 0.88))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hasBrand {
                    Button {
                        previewBranded.toggle()
                        if cardFlipped { cardFlipped = false }
                    } label: {
                        Text("Brand")
                            .font(.caption)
                            .fontWeight(previewBranded ? .semibold : .regular)
                            .foregroundStyle(previewBranded ? Color.white : Color(white: 0.2))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(previewBranded ? Color.accentColor : Color(white: 0.88))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
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
            .padding(14)
        }
    }

    private var scriptCardBack: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(script.scriptType == "feed" ? "Script Settings" : "Dependency Checks")
                    .font(.headline)
                    .foregroundStyle(brandForegroundPrimary)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.5)) { cardFlipped = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(brandForegroundSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Schedule editor (feed scripts only)
                    if script.scriptType == "feed" && script.schedule != nil {
                        scheduleEditorSection
                        if !script.requires.isEmpty {
                            Divider()
                                .background(brandForegroundSecondary.opacity(0.2))
                            Text("Dependency Checks")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(brandForegroundPrimary)
                        }
                    }

                    ForEach(script.requires, id: \.id) { dep in
                        VStack(alignment: .leading, spacing: 6) {
                            // Row: status icon + name + Run + Save
                            HStack(spacing: 6) {
                                Group {
                                    if checkRunning.contains(dep.id) {
                                        ProgressView().controlSize(.mini)
                                    } else if let result = checkResults[dep.id] {
                                        Image(systemName: result == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(result == true ? Color.green : Color.red)
                                    } else {
                                        Image(systemName: "circle.dotted")
                                            .foregroundStyle(brandForegroundTertiary)
                                    }
                                }
                                .font(.caption)
                                .frame(width: 14)

                                Text(dep.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(brandForegroundPrimary)

                                Toggle("", isOn: Binding(
                                    get: { !settings.isDepCheckSkipped(scriptID: script.id, depID: dep.id) },
                                    set: { settings.setDepCheckSkipped(scriptID: script.id, depID: dep.id, skipped: !$0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Enable dependency check")

                                Spacer()

                                Button {
                                    Task { await runDepCheck(dep) }
                                } label: {
                                    if checkRunning.contains(dep.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Text("Run")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(checkRunning.contains(dep.id))

                                Button {
                                    saveDepCheck(dep)
                                } label: {
                                    Text(savedDeps.contains(dep.id) ? "Saved ✓" : "Save")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled((checkDrafts[dep.id] ?? dep.check) == dep.check || savedDeps.contains(dep.id))
                            }

                            // Editable check command
                            TextEditor(text: Binding(
                                get: { checkDrafts[dep.id] ?? dep.check },
                                set: { checkDrafts[dep.id] = $0 }
                            ))
                            .font(.system(.caption2, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(brandForegroundSecondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(minHeight: 44, maxHeight: 80)

                            // Output from last run
                            if let output = checkOutput[dep.id], !output.isEmpty {
                                let passed = checkResults[dep.id] == true
                                Text(output)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(passed ? Color.green : Color.red)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(brandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Initialise schedule state from manifest cron expression
            if let cron = script.schedule {
                let parts = cron.split(separator: " ")
                if parts.count == 5,
                   let min = Int(parts[0]),
                   let hr  = Int(parts[1]) {
                    scheduleMinute = [0, 15, 30, 45].contains(min) ? min : 0
                    scheduleIsPM = hr >= 12
                    scheduleHourDisplay = { let h = hr % 12; return h == 0 ? 12 : h }()
                    let dayStr = String(parts[4])
                    if dayStr == "*" {
                        scheduleDays = []
                    } else {
                        var days = Set<Int>()
                        for part in dayStr.split(separator: ",") {
                            let s = String(part)
                            if s.contains("-"), let dash = s.firstIndex(of: "-") {
                                let after = s.index(after: dash)
                                if let start = Int(s[s.startIndex..<dash]),
                                   let end   = Int(s[after...]) {
                                    for d in start...end { days.insert(d) }
                                }
                            } else if let d = Int(s) {
                                days.insert(d)
                            }
                        }
                        scheduleDays = days
                    }
                }
            }
            // Initialise drafts and run checks when back is shown
            for dep in script.requires {
                if checkDrafts[dep.id] == nil { checkDrafts[dep.id] = dep.check }
            }
            Task {
                for dep in script.requires { await runDepCheck(dep) }
            }
        }
        .ifLet(brandColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    private func runDepCheck(_ dep: ScriptDependency) async {
        let command = checkDrafts[dep.id] ?? dep.check

        // Strip output suppression so we can capture and display what the check found
        let displayCommand = command
            .replacingOccurrences(of: " >/dev/null 2>&1", with: "")
            .replacingOccurrences(of: " 2>/dev/null", with: "")
            .replacingOccurrences(of: " >/dev/null", with: "")

        checkRunning.insert(dep.id)
        checkResults[dep.id] = nil
        checkOutput[dep.id] = ""

        let (passed, output) = await Task.detached(priority: .userInitiated) {
            // Run original command for authoritative exit code
            let checkProc = Process()
            checkProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            checkProc.arguments = ["-l", "-c", command]
            checkProc.standardOutput = Pipe()
            checkProc.standardError = Pipe()
            try? checkProc.run()
            checkProc.waitUntilExit()
            let passed = checkProc.terminationStatus == 0

            // Run display version to capture output
            let outPipe = Pipe()
            let errPipe = Pipe()
            let displayProc = Process()
            displayProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            displayProc.arguments = ["-l", "-c", displayCommand]
            displayProc.standardOutput = outPipe
            displayProc.standardError = errPipe
            try? displayProc.run()
            displayProc.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
            return (passed, combined)
        }.value

        checkRunning.remove(dep.id)
        checkResults[dep.id] = passed
        checkOutput[dep.id] = output
    }

    private func saveDepCheck(_ dep: ScriptDependency) {
        guard let manifestPath = script.manifestPath,
              let draft = checkDrafts[dep.id],
              draft != dep.check,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var requires = json["requires"] as? [[String: Any]] else { return }

        guard let idx = requires.firstIndex(where: { $0["id"] as? String == dep.id }) else { return }
        requires[idx]["check"] = draft
        json["requires"] = requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        savedDeps.insert(dep.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            savedDeps.remove(dep.id)
        }
    }

    private func saveSchedule() {
        guard let manifestURL = script.manifestPath else { return }
        let hr24: Int = {
            if scheduleIsPM { return scheduleHourDisplay == 12 ? 12 : scheduleHourDisplay + 12 }
            else             { return scheduleHourDisplay == 12 ? 0  : scheduleHourDisplay }
        }()
        let dayStr = scheduleDays.isEmpty ? "*" : scheduleDays.sorted().map(String.init).joined(separator: ",")
        let cron = "\(scheduleMinute) \(hr24) * * \(dayStr)"

        guard let data = try? Data(contentsOf: manifestURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["schedule"] = cron
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestURL)
        }
        scheduleSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { scheduleSaved = false }
    }

    // MARK: Schedule editor (feed scripts)

    private var scheduleEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundPrimary)

            // Time of day
            HStack(spacing: 8) {
                Text("Time")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)
                    .frame(width: 36, alignment: .leading)

                Picker("", selection: $scheduleHourDisplay) {
                    ForEach(1...12, id: \.self) { h in Text("\(h)").tag(h) }
                }
                .labelsHidden()
                .frame(width: 56)
                .onChange(of: scheduleHourDisplay) { _, _ in scheduleSaved = false }

                Text(":")
                    .foregroundStyle(brandForegroundSecondary)

                Picker("", selection: $scheduleMinute) {
                    Text("00").tag(0)
                    Text("15").tag(15)
                    Text("30").tag(30)
                    Text("45").tag(45)
                }
                .labelsHidden()
                .frame(width: 56)
                .onChange(of: scheduleMinute) { _, _ in scheduleSaved = false }

                Picker("", selection: $scheduleIsPM) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 80)
                .onChange(of: scheduleIsPM) { _, _ in scheduleSaved = false }
            }

            // Days of week
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Days")
                        .font(.caption)
                        .foregroundStyle(brandForegroundSecondary)
                        .frame(width: 36, alignment: .leading)

                    HStack(spacing: 4) {
                        let dayLabels = ["S","M","T","W","T","F","S"]
                        ForEach(0..<7, id: \.self) { day in
                            let selected = scheduleDays.contains(day)
                            Button {
                                if selected { scheduleDays.remove(day) }
                                else        { scheduleDays.insert(day) }
                                scheduleSaved = false
                            } label: {
                                Text(dayLabels[day])
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(width: 26, height: 26)
                                    .background(selected ? Color.accentColor : brandForegroundSecondary.opacity(0.12))
                                    .foregroundStyle(selected ? Color.white : brandForegroundPrimary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Spacer().frame(width: 40)
                    Text(scheduleSummary)
                        .font(.caption2)
                        .foregroundStyle(brandForegroundTertiary)
                }
            }

            // Save
            HStack {
                if !scheduleDays.isEmpty {
                    Button("Every day") {
                        scheduleDays = []
                        scheduleSaved = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button { saveSchedule() } label: {
                    Text(scheduleSaved ? "Saved ✓" : "Save Schedule")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(scheduleSaved)
            }
        }
    }

    private var scheduleSummary: String {
        let ampm = scheduleIsPM ? "PM" : "AM"
        let timeStr = String(format: "%d:%02d %@", scheduleHourDisplay, scheduleMinute, ampm)
        if scheduleDays.isEmpty { return "Every day at \(timeStr)" }
        let names = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        let sorted = scheduleDays.sorted()
        if sorted == [1,2,3,4,5] { return "Weekdays at \(timeStr)" }
        if sorted == [0,6]       { return "Weekends at \(timeStr)" }
        return sorted.map { names[$0] }.joined(separator: ", ") + " at \(timeStr)"
    }

    private func manifestRow(_ key: String, value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(brandForegroundTertiary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontDesign(monospaced ? .monospaced : .default)
                .foregroundStyle(brandForegroundSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            if copyable {
                CopyButton(value: value)
            }
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
            Text(cardStatusLabel)
                .font(.caption)
                .foregroundStyle(brandForegroundSecondary)
        }
    }

    private var cardStatusLabel: String {
        script.status == .stopped && script.scriptType == "feed" ? "Scheduled" : script.status.label
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

    // MARK: Brand colors — raw (script's actual brand)

    @Environment(\.colorScheme) private var colorScheme

    /// The color scheme the card will render in, accounting for preview selection.
    private var effectiveColorScheme: ColorScheme {
        previewScheme == .dark ? .dark : .light
    }

    private var scriptBrandColorScheme: ColorScheme? {
        switch script.id {
        case "github": .dark
        default: nil
        }
    }

    private var hasBrand: Bool {
        switch script.id {
        case "claudecode-controller", "github": true
        default: false
        }
    }

    // MARK: Brand colors — effective (respects preview toggles)

    /// Background actually applied to the card.
    private var brandBackground: Color {
        if !previewBranded {
            return effectiveColorScheme == .dark
                ? Color(white: 0.15)
                : Color(white: 0.96)
        }
        switch script.id {
        case "claudecode-controller":
            return effectiveColorScheme == .dark
                ? Color(red: 0.15, green: 0.13, blue: 0.11)
                : Color(red: 250/255, green: 249/255, blue: 245/255)
        case "github":
            // GitHub always uses its dark card; light preview switches to a neutral surface
            return effectiveColorScheme == .light
                ? Color(red: 250/255, green: 250/255, blue: 250/255)
                : Color(red: 0x24/255, green: 0x29/255, blue: 0x2F/255)
        default:
            return effectiveColorScheme == .dark
                ? Color(white: 0.15)
                : Color(white: 0.96)
        }
    }

    /// Color scheme environment applied to the card.
    private var brandColorScheme: ColorScheme? {
        previewScheme == .dark ? .dark : .light
    }

    /// Whether the card is rendering on a dark background (drives icon SVG recolouring).
    private var cardIsOnDark: Bool {
        previewScheme == .dark
    }

    private var brandAccent: Color? {
        guard previewBranded else { return nil }
        switch script.id {
        case "claudecode-controller": return Color(red: 202/255, green: 124/255, blue: 94/255)
        case "github":               return Color(red: 0x09/255, green: 0x69/255, blue: 0xDA/255)
        default: return nil
        }
    }

    private var brandForegroundPrimary: Color {
        cardIsOnDark ? .white : Color(white: 0.0)
    }

    private var brandForegroundSecondary: Color {
        cardIsOnDark ? Color(white: 1.0, opacity: 0.65) : Color(white: 0.0, opacity: 0.55)
    }

    private var brandForegroundTertiary: Color {
        cardIsOnDark ? Color(white: 1.0, opacity: 0.4) : Color(white: 0.0, opacity: 0.35)
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

    /// Icon image adapted for the card's effective color scheme.
    /// Dark background cards get SVG strokes recoloured to white.
    private var cardIcon: NSImage? {
        if cardIsOnDark, let svg = script.svgString {
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

// MARK: - Feed filter

private enum FeedFilter: Hashable {
    case all
    case kind(HistoryEventKind)
    case source(String)
}

// MARK: - Feed view

private struct MacFeedView: View {
    @Environment(ActionHistoryService.self) private var history
    @State private var feedFilter: FeedFilter? = .all
    @State private var selectedEvent: HistoryEvent?

    private var filteredEvents: [HistoryEvent] {
        switch feedFilter {
        case .all, nil:         return history.events
        case .kind(let k):      return history.events.filter { $0.kind == k }
        case .source(let s):    return history.events.filter { $0.source == s }
        }
    }

    // Per-kind counts shown in the type section
    private func count(for kind: HistoryEventKind) -> Int {
        history.events.filter { $0.kind == kind }.count
    }

    private struct SourceStat: Identifiable {
        let name: String
        let count: Int
        let latest: Date?
        var id: String { name }
    }

    private var sourceStats: [SourceStat] {
        var counts: [String: (count: Int, latest: Date?)] = [:]
        for event in history.events {
            let existing = counts[event.source]
            let latestDate = existing.flatMap { $0.latest }.map { max($0, event.timestamp) } ?? event.timestamp
            counts[event.source] = ((existing?.count ?? 0) + 1, latestDate)
        }
        return counts.map { SourceStat(name: $0.key, count: $0.value.count, latest: $0.value.latest) }
            .sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
    }

    var body: some View {
        NavigationSplitView {
            feedSidebar
        } detail: {
            feedDetail
        }
        .navigationTitle("Feed")
        .sheet(item: $selectedEvent) { event in
            FeedEventDetailSheet(event: event)
        }
    }

    // MARK: Sidebar — analytics + filters

    private var feedSidebar: some View {
        List(selection: $feedFilter) {
            // All
            Section {
                HStack {
                    Label("All Activity", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(history.events.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(FeedFilter.all)
            }

            // By type
            Section("By Type") {
                kindRow(kind: .scriptCrashed,  label: "Crashes",   icon: "exclamationmark.triangle.fill")
                kindRow(kind: .blockResponse,  label: "Responses",  icon: "hand.point.up.left")
                kindRow(kind: .scriptEnabled,  label: "Enabled",    icon: "play.circle.fill")
                kindRow(kind: .scriptDisabled, label: "Disabled",   icon: "stop.circle.fill")
            }

            // By script
            if !sourceStats.isEmpty {
                Section("By Script") {
                    ForEach(sourceStats) { stat in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.name)
                                    .font(.subheadline)
                                if let date = stat.latest {
                                    Text(date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text("\(stat.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(FeedFilter.source(stat.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    @ViewBuilder
    private func kindRow(kind: HistoryEventKind, label: String, icon: String) -> some View {
        let n = count(for: kind)
        if n > 0 {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundStyle(kind.color)
                Spacer()
                Text("\(n)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(FeedFilter.kind(kind))
        }
    }

    // MARK: Detail — event list

    private var feedDetail: some View {
        Group {
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    "No Feed Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Script interactions and lifecycle events will appear here.")
                )
            } else {
                List {
                    ForEach(filteredEvents) { event in
                        FeedEventRow(event: event)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedEvent = event }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
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
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Feed event detail sheet

private struct FeedEventDetailSheet: View {
    let event: HistoryEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: event.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(event.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.source)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(event.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                LabeledContent("Summary") {
                    Text(event.summary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Time") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                        Text(event.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = event.detail, !detail.isEmpty {
                    LabeledContent("Detail") {
                        Text(detail)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 280)
    }
}

// MARK: - Machine detail view

private enum MachineSection: String, CaseIterable, Identifiable {
    case cloud    = "Cloud"
    case devices  = "Devices"
    case machine  = "Machine"
    case vault    = "Scripts Vault"
    case sessions = "Sessions"
    case about    = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloud:    "icloud"
        case .devices:  "iphone"
        case .machine:  "desktopcomputer"
        case .vault:    "folder"
        case .sessions: "cpu"
        case .about:    "info.circle"
        }
    }
}

private struct MachineDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HeartbeatService.self) private var heartbeat

    @State private var selectedSection: MachineSection? = .cloud
    @State private var showVaultPicker = false
    @State private var vaultPathText: String = ""
    @State private var agentSessions: [AgentSession] = []
    @State private var liveProcesses: [LiveProcess] = []

    var body: some View {
        NavigationSplitView {
            List(MachineSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selectedSection ?? .cloud {
            case .cloud:    machineCloudSection
            case .devices:  machineDevicesSection
            case .machine:  machineMachineSection
            case .vault:    machineVaultSection
            case .sessions: machineSessionsSection
            case .about:    machineAboutSection
            }
        }
        .navigationTitle("Machine")
        .onAppear { refreshSessions() }
        .fileImporter(
            isPresented: $showVaultPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                settings.vaultPath = url
                vaultPathText = url.abbreviatingWithTildeInPath
            }
        }
    }

    // MARK: Section: Cloud

    private var machineCloudSection: some View {
        Form {
            Section("iCloud Sync") {
                LabeledContent("Status") {
                    if let lastBeat = heartbeat.lastHeartbeat {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(lastBeat, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    } else if let syncError = heartbeat.error {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label("Sync error", systemImage: "exclamationmark.icloud")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(syncError.localizedDescription)
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Heartbeat Interval") {
                    Text("\(Int(HeartbeatService.interval))s")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Machine ID") {
                    Text(settings.machineID)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Container") {
                    Text("iCloud.simple.ask")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("Database") {
                    Text("Private")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cloud")
    }

    // MARK: Section: Devices

    private var machineDevicesSection: some View {
        Form {
            Section {
                if heartbeat.connectedDevices.isEmpty {
                    Text("No iPhones seen in the last hour.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(heartbeat.connectedDevices, id: \.deviceID) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.deviceName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                HStack(spacing: 8) {
                                    Label(device.lastSeen.formatted(.relative(presentation: .named)),
                                          systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption2)
                                    Text(device.deviceID.prefix(8) + "…")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fontDesign(.monospaced)
                                        .textSelection(.enabled)
                                }
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { device.enabled },
                                set: { heartbeat.setDeviceEnabled(device, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Connected iPhones")
                    Spacer()
                    if !heartbeat.connectedDevices.isEmpty {
                        Text("\(heartbeat.connectedDevices.count) device\(heartbeat.connectedDevices.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
    }

    // MARK: Section: Machine

    private var machineMachineSection: some View {
        @Bindable var settings = settings
        return Form {
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

            Section("MCP Tools") {
                ForEach([
                    ("emit_block",            "Display a UI block on the iOS device",         "blockId, blockType, payload, ttl?"),
                    ("clear_block",           "Remove a UI block from the iOS device",         "blockId"),
                    ("get_schema",            "Get payload schemas for all block types",        "—"),
                    ("list_terminal_sessions","List interactive terminal sessions on this Mac", "filter?"),
                ], id: \.0) { name, desc, params in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(.body, design: .monospaced))
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(params)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Machine")
    }

    // MARK: Section: Scripts Vault

    private var machineVaultSection: some View {
        Form {
            Section {
                Toggle("Include App Bundle Scripts", isOn: Binding(
                    get: { settings.usesBundledScripts },
                    set: { settings.usesBundledScripts = $0 }
                ))

                if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("Scripts").abbreviatingWithTildeInPath {
                    Text(bundlePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    TextField("Vault Path", text: $vaultPathText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .onSubmit { applyVaultPathText() }
                    Button { showVaultPicker = true } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose folder")
                }
            } header: {
                Text("Scripts Vault")
            } footer: {
                Text("Vault scripts override bundle scripts with the same ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scripts Vault")
        .onAppear {
            vaultPathText = settings.vaultPath?.abbreviatingWithTildeInPath ?? "~/.ask/scripts"
        }
    }

    private func applyVaultPathText() {
        let expanded = vaultPathText.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + vaultPathText.dropFirst()
            : vaultPathText
        settings.vaultPath = URL(fileURLWithPath: expanded)
    }


    // MARK: Section: Sessions

    private var machineSessionsSection: some View {
        Form {
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
                            Text(p.name).font(.caption).fontWeight(.medium)
                            Spacer()
                            Text("PID \(p.pid)  TTY \(p.tty)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sessions")
    }

    // MARK: Section: About

    private var machineAboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Form {
            Section("About") {
                LabeledContent("AskMac Version") {
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    // MARK: Data loading

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
                    let comm = p["comm"] as? String ?? ""
                    let name = p["name"] as? String ?? URL(fileURLWithPath: comm).lastPathComponent
                    procs.append(LiveProcess(
                        controller: controller,
                        pid:  p["pid"]  as? String ?? "",
                        tty:  p["tty"]  as? String ?? "",
                        comm: comm,
                        name: name
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
    let name: String
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
