#if canImport(AskMacCore)
import AskMacCore
#endif
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Card preview axes

enum CardColorSchemePreview: String, CaseIterable {
    case light = "Light"
    case dark  = "Dark"
}

// MARK: - Script detail view

struct ScriptDetailView: View {
    let script: ManagedScript
    let scriptManager: ScriptManager
    var installer: ScriptInstaller = ScriptInstaller()
    var onUninstall: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(ScriptCatalogService.self) private var catalog

    // Update state
    @State private var isDownloadingUpdate = false
    @State private var updateError: String?
    @State private var showUpdatePopover = false

    @State private var showUninstallConfirm = false
    @State private var cardFlipped = false
    @State private var previewBranded = true
    @State private var previewScheme: CardColorSchemePreview = .light
    @State private var showTools = false
    @State private var checkDrafts: [String: String] = [:]
    @State private var checkResults: [String: Bool?] = [:]
    @State private var checkOutput: [String: String] = [:]
    @State private var checkRunning: Set<String> = []
    @State private var savedDeps: Set<String> = []
    // Add-dependency form state
    @State private var addingDep = false
    @State private var newDepName = ""
    @State private var newDepCheck = ""
    // Brand override state
    @State private var brandColorPickerColor: Color = .white
    @State private var brandHex: String = ""
    @State private var brandColorSaved = false
    @State private var svgDropTargeted = false
    // Schedule editor state (feed scripts)
    @State private var scheduleHourDisplay: Int = 9   // 1–12
    @State private var scheduleIsPM: Bool = false
    @State private var scheduleMinute: Int = 0         // 0, 15, 30, 45
    @State private var scheduleDays: Set<Int> = []     // 0=Sun…6=Sat; empty = every day
    @State private var scheduleSaved = false
    // Setup state
    @State private var configValues: [String: String] = [:]    // key → value being edited
    @State private var configSaved: Set<String> = []           // keys that were just saved
    @State private var showSetupSheet = false
    @State private var setupOutputLines: [String] = []
    @State private var setupRunning = false
    @State private var setupNeedsTerminal = false

    private var liveBlocks: [LiveBlock] {
        Array((scriptManager.activeBlocks[script.id] ?? [:]).values)
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scriptCard

                // Toggle bar — only for non-system scripts that declare tools
                if !script.tools.isEmpty && !script.isSystem {
                    Picker("", selection: $showTools) {
                        Text("Live Preview").tag(false)
                        Text("Methods").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if script.isSystem || showTools {
                    // System scripts always show their tools (no Live Preview).
                    // Non-system scripts show tools when the Methods tab is selected.
                    scriptToolsPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if script.status == .crashed, let error = script.lastError {
                        crashBanner(error)
                    }

                    // Two-column: live blocks on the left, script log on the right
                    HStack(alignment: .top, spacing: 16) {
                        // Left — live block preview
                        VStack(alignment: .leading, spacing: 8) {
                            if liveBlocks.isEmpty {
                                ContentUnavailableView(
                                    "No Active Blocks",
                                    systemImage: "rectangle.stack",
                                    description: Text("This script hasn't emitted any blocks yet.")
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                            } else {
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
                        .frame(maxWidth: .infinity)

                        // Right — script log
                        stderrLogSection
                            .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity, minHeight: 210)
        .animation(.easeInOut(duration: 0.2), value: cardFlipped)
    }

    private var scriptCardFront: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + name/info
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .center, spacing: 6) {
                    scriptIcon
                        .frame(width: 48, height: 48)

                    if let update = catalog.availableUpdates[script.id] {
                        Button {
                            showUpdatePopover = true
                        } label: {
                            Text("Update")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
                            updatePopoverView(entry: update)
                        }
                    } else if script.needsSetup {
                        Button {
                            runSetup()
                        } label: {
                            Text("Setup")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(.orange)
                    }
                }

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

            // Permissions section
            if !script.permissions.isEmpty {
                Divider()
                    .opacity(0.3)
                permissionsSection
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, script.requires.isEmpty && !script.hasSetup ? 44 : 0)
            }

            // Dependencies section
            if !script.requires.isEmpty {
                Divider()
                    .opacity(0.3)
                dependenciesSection
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 44) // leave room for bottom overlay controls
            }

            if script.hasSetup {
                Divider()
                    .opacity(0.3)
                setupInCard
                    .padding(.bottom, 54)  // leave room for the bottom overlay controls (Light/Dark/toggle)
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

                if hasBrand {
                    Button {
                        withAnimation(.spring(duration: 0.5)) { cardFlipped = true }
                    } label: {
                        Image(systemName: "paintpalette")
                            .font(.body)
                            .foregroundStyle(brandForegroundPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Edit brand colors")
                }

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
                        HStack(spacing: 4) {
                            Image(systemName: previewBranded ? "checkmark.square.fill" : "square")
                            Text("Show brand")
                        }
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
        .alert("Remove \(script.name)?", isPresented: $showUninstallConfirm) {
            Button("Remove", role: .destructive) {
                onUninstall()
                scriptManager.uninstallScript(id: script.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop the script, clear its blocks from your iPhone, and move its files to the Trash.")
        }
    }

    private var scriptCardBack: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Script Settings")
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
                    // Brand override editor
                    if hasBrand {
                        brandOverrideSection
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                    }

                    // Schedule editor (feed scripts only)
                    if script.scriptType == "feed" && script.schedule != nil {
                        scheduleEditorSection
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                    }

                    // Dependency checks header + add button
                    HStack {
                        Text("Dependency Checks")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(brandForegroundPrimary)
                        Spacer()
                        Button {
                            addingDep = true
                            newDepName = ""
                            newDepCheck = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Add dependency check")
                    }

                    // Inline add form
                    if addingDep {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name (e.g. node)", text: $newDepName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            TextField("Check command (exit 0 = installed)", text: $newDepCheck)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption2, design: .monospaced))

                            HStack {
                                Spacer()
                                Button("Cancel") { addingDep = false }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Add") { addDepCheck() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(newDepName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                              newDepCheck.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(8)
                        .background(brandForegroundSecondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if script.requires.isEmpty && !addingDep {
                        Text("No dependency checks defined.")
                            .font(.caption)
                            .foregroundStyle(brandForegroundTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                    // Run Setup — always visible here; tinted orange when setup is needed
                    if script.setupScript != nil {
                        Divider()
                            .background(brandForegroundSecondary.opacity(0.2))
                        Button {
                            runSetup()
                        } label: {
                            Label("Run Setup", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(script.needsSetup ? .orange : .accentColor)
                        .sheet(isPresented: $showSetupSheet) {
                            SetupOutputSheet(
                                scriptName: script.name,
                                lines: $setupOutputLines,
                                running: $setupRunning
                            )
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

                                Button {
                                    removeDepCheck(dep)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.borderless)
                                .help("Remove dependency check")
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
            // Initialise brand color state
            initBrandColor()

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

    private func addDepCheck() {
        let name = newDepName.trimmingCharacters(in: .whitespaces)
        let check = newDepCheck.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !check.isEmpty,
              let manifestPath = script.manifestPath,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let newEntry: [String: Any] = ["id": id, "name": name, "check": check]
        var requires = (json["requires"] as? [[String: Any]]) ?? []
        requires.append(newEntry)
        json["requires"] = requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        addingDep = false
        newDepName = ""
        newDepCheck = ""
    }

    private func removeDepCheck(_ dep: ScriptDependency) {
        guard let manifestPath = script.manifestPath,
              let data = try? Data(contentsOf: manifestPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var requires = json["requires"] as? [[String: Any]] else { return }

        requires.removeAll { $0["id"] as? String == dep.id }
        json["requires"] = requires.isEmpty ? nil : requires

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? newData.write(to: manifestPath)
        }
        checkDrafts.removeValue(forKey: dep.id)
        checkResults.removeValue(forKey: dep.id)
        checkOutput.removeValue(forKey: dep.id)
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

    // MARK: Brand override editor

    private func initBrandColor() {
        if let hex = settings.brandColorOverride(for: script.id), let c = Color(hex: hex) {
            brandColorPickerColor = c
            brandHex = hex
        }
        // no override → leave blank (hex = "", picker = .white defaults)
    }

    private var brandHexIsValid: Bool {
        let h = brandHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return h.count == 6 && UInt64(h, radix: 16) != nil
    }

    private func saveBrandColor() {
        guard brandHexIsValid else { return }
        let hex = brandHex.hasPrefix("#") ? brandHex : "#\(brandHex)"
        settings.setBrandColorOverride(scriptID: script.id, hex: hex)
        brandColorSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { brandColorSaved = false }
    }

    @discardableResult
    private func handleIconDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "svg",
                  let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.settings.setSVGOverride(scriptID: self.script.id, svg: svg) }
        }
        return true
    }

    private func handleIconPaste() {
        guard let str = NSPasteboard.general.string(forType: .string),
              str.contains("<svg") else { return }
        settings.setSVGOverride(scriptID: script.id, svg: str)
    }

    @ViewBuilder
    private var brandOverrideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brand")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundPrimary)

            // Background color
            VStack(alignment: .leading, spacing: 6) {
                Text("Background Color")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)

                HStack(spacing: 8) {
                    ColorPicker("", selection: $brandColorPickerColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: brandColorPickerColor) { _, newColor in
                            // Picker → hex (one direction only to avoid circular updates)
                            brandHex = newColor.hexString
                            brandColorSaved = false
                        }

                    TextField("#RRGGBB", text: $brandHex)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .onChange(of: brandHex) { _, _ in
                            brandColorSaved = false
                        }
                        .onSubmit {
                            // Hex → picker only on submit to avoid circular onChange loop
                            if let c = Color(hex: brandHex) { brandColorPickerColor = c }
                        }

                    Spacer()

                    Button { saveBrandColor() } label: {
                        Text(brandColorSaved ? "Saved ✓" : "Save")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(brandColorSaved || !brandHexIsValid)
                }
            }

            // SVG icon override
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon (SVG)")
                    .font(.caption)
                    .foregroundStyle(brandForegroundSecondary)

                HStack(spacing: 10) {
                    // Drop zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                svgDropTargeted ? Color.accentColor : brandForegroundSecondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5])
                            )
                            .frame(width: 48, height: 48)

                        if let svgStr = settings.svgOverride(for: script.id),
                           let data = svgStr.data(using: .utf8),
                           let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title3)
                                .foregroundStyle(brandForegroundTertiary)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $svgDropTargeted) { providers in
                        handleIconDrop(providers)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Button("Paste SVG") { handleIconPaste() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                        if settings.svgOverride(for: script.id) != nil {
                            Button("Remove") { settings.setSVGOverride(scriptID: script.id, svg: nil) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Drop .svg file here")
                                .font(.caption2)
                                .foregroundStyle(brandForegroundTertiary)
                        }
                    }
                }
            }

            // Reset all brand overrides
            let hasAnyOverride = settings.brandColorOverride(for: script.id) != nil
                              || settings.svgOverride(for: script.id) != nil
            if hasAnyOverride {
                HStack {
                    Spacer()
                    Button("Reset Brand") {
                        settings.setBrandColorOverride(scriptID: script.id, hex: nil)
                        settings.setSVGOverride(scriptID: script.id, svg: nil)
                        initBrandColor()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
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
        let label = script.scriptType == "feed" ? "Feed"
                  : script.scriptType == "system" ? "System"
                  : "Tile"
        Text(label)
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
        case .needsSetup:           .orange
        case .pendingConsent:       .orange
        case .permissionDenied:     .orange
        case .starting:             .yellow
        case .stopped:              .secondary
        }
    }

    // MARK: - Setup

    private var setupInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if script.setupCheckRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        scriptManager.runSetupCheck(id: script.id)
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Config form
            if !script.configItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(script.configItems) { item in
                        configRow(item)
                    }
                }
            }

            // Check results
            if !script.setupChecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.setupChecks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(check.ok ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.label)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                if let msg = check.message {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if script.setupCheckRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        scriptManager.runSetupCheck(id: script.id)
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Config form — required secret/string fields
            if !script.configItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(script.configItems) { item in
                        configRow(item)
                    }
                }
            }

            // Check results
            if !script.setupChecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(script.setupChecks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(check.ok ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.label)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                if let msg = check.message {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            // Run Setup button
            if script.setupScript != nil {
                let failedChecks = script.setupChecks.filter { !$0.ok }
                let needsTerminal = failedChecks.contains { $0.needsTerminal == true }

                Button {
                    if needsTerminal {
                        scriptManager.setupInstallInTerminal(id: script.id)
                    } else {
                        setupOutputLines = []
                        showSetupSheet = true
                        Task {
                            setupRunning = true
                            for await line in scriptManager.setupInstallStream(id: script.id) {
                                setupOutputLines.append(line)
                            }
                            setupRunning = false
                            scriptManager.runSetupCheck(id: script.id)
                        }
                    }
                } label: {
                    Label(needsTerminal ? "Open Terminal to Setup" : "Run Setup",
                          systemImage: needsTerminal ? "terminal" : "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(script.needsSetup ? .orange : .accentColor)
                .sheet(isPresented: $showSetupSheet) {
                    SetupOutputSheet(
                        scriptName: script.name,
                        lines: $setupOutputLines,
                        running: $setupRunning
                    )
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(script.needsSetup ? Color.orange.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func configRow(_ item: ScriptConfigItem) -> some View {
        let binding = Binding<String>(
            get: { configValues[item.key] ?? KeychainService.shared.get(scriptID: script.id, key: item.key) ?? "" },
            set: { configValues[item.key] = $0 }
        )
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.label)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(brandForegroundPrimary)
                    if item.required == true {
                        Text("required")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let desc = item.description {
                    Text(desc).font(.caption2).foregroundStyle(brandForegroundTertiary)
                }
            }
            Spacer()
            if item.type == "secret" {
                SecureField("••••••••", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            } else {
                TextField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if let helpURL = item.helpURL, let url = URL(string: helpURL) {
                Link(destination: url) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                let val = configValues[item.key] ?? ""
                guard !val.isEmpty else { return }
                try? KeychainService.shared.set(scriptID: script.id, key: item.key, value: val)
                configSaved.insert(item.key)
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    configSaved.remove(item.key)
                }
                scriptManager.runSetupCheck(id: script.id)
            } label: {
                Image(systemName: configSaved.contains(item.key) ? "checkmark" : "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(configSaved.contains(item.key) ? .green : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled((configValues[item.key] ?? "").isEmpty)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permissions")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(brandForegroundTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if script.status == .permissionDenied {
                    Button("Review") {
                        scriptManager.reviewPermissions(scriptID: script.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                } else if script.status == .pendingConsent {
                    Text("Awaiting approval")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            let granted = settings.permissionsGranted(for: script.id)
            VStack(spacing: 4) {
                ForEach(script.permissions, id: \.self) { token in
                    let info = ScriptPermissionInfo.info(for: token)
                    let isGranted = granted.contains(token)
                    HStack(spacing: 8) {
                        Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isGranted ? Color.green : Color.orange)
                        Text(info.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(brandForegroundPrimary)
                        Spacer(minLength: 0)
                        if isGranted {
                            Button("Revoke") {
                                settings.resetScriptPermissions(for: script.id)
                                scriptManager.reviewPermissions(scriptID: script.id)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if script.status == .permissionDenied {
                Text("This script is not running because you denied its permissions.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Dependencies

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dependencies")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(brandForegroundTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(script.requires, id: \.id) { dep in
                    let isMissing = script.missingDeps.contains { $0.id == dep.id }
                    HStack(spacing: 6) {
                        Image(systemName: isMissing ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isMissing ? .red : .green)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(dep.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(brandForegroundPrimary)
                                .lineLimit(1)
                            if isMissing, let install = dep.install {
                                Text(install)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(brandForegroundTertiary)
                                    .lineLimit(1)
                            } else {
                                Text(isMissing ? "Missing" : "Installed")
                                    .font(.caption2)
                                    .foregroundStyle(brandForegroundTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Retry button — shown once if any are missing
            if script.missingDeps.contains(where: { _ in true }) {
                Button("Retry") {
                    scriptManager.retryDependencies(id: script.id)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
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

    private var hasBrand: Bool { true }

    // MARK: Brand colors — effective (respects preview toggles)

    /// Background actually applied to the card.
    private var brandBackground: Color {
        if !previewBranded {
            return effectiveColorScheme == .dark ? Color(white: 0.15) : Color(white: 0.96)
        }
        // User override
        if let hex = settings.brandColorOverride(for: script.id), let c = Color(hex: hex) {
            return c
        }
        // Built-in script brands
        switch script.id {
        case "claudecode-controller":
            return effectiveColorScheme == .dark
                ? Color(red: 0.15, green: 0.13, blue: 0.11)
                : Color(red: 250/255, green: 249/255, blue: 245/255)
        case "github":
            return effectiveColorScheme == .light
                ? Color(red: 250/255, green: 250/255, blue: 250/255)
                : Color(red: 0x24/255, green: 0x29/255, blue: 0x2F/255)
        default:
            return effectiveColorScheme == .dark ? Color(white: 0.15) : Color(white: 0.96)
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
        default:                     return nil
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
        // SVG override takes priority
        let svgSource = settings.svgOverride(for: script.id) ?? script.svgString
        if let svg = svgSource {
            if cardIsOnDark { return svgToWhite(svg) ?? script.iconImage }
            return NSImage(data: svg.data(using: .utf8) ?? Data()) ?? script.iconImage
        }
        return script.iconImage
    }

    // MARK: Crash banner

    @ViewBuilder
    private var stderrLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Script Log", systemImage: "terminal")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(script.stderrLog.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(script.stderrLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(nil)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 200)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Update popover

    @ViewBuilder
    private func updatePopoverView(entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Update Available")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(script.version ?? "?") → \(entry.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let log = entry.changelog, !log.isEmpty {
                Text(log)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = updateError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showUpdatePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button {
                    showUpdatePopover = false
                    installUpdate(entry: entry)
                } label: {
                    if isDownloadingUpdate {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Downloading…")
                        }
                    } else {
                        Text("Install Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isDownloadingUpdate || installer.phase != .idle)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Setup helper

    private func runSetup() {
        let failedChecks = script.setupChecks.filter { !$0.ok }
        let needsTerminal = failedChecks.contains { $0.needsTerminal == true }
        if needsTerminal {
            scriptManager.setupInstallInTerminal(id: script.id)
        } else {
            setupOutputLines = []
            showSetupSheet = true
            Task {
                setupRunning = true
                for await line in scriptManager.setupInstallStream(id: script.id) {
                    setupOutputLines.append(line)
                }
                setupRunning = false
                scriptManager.runSetupCheck(id: script.id)
            }
        }
    }

    private func installUpdate(entry: CatalogEntry) {
        isDownloadingUpdate = true
        updateError = nil
        Task {
            do {
                let zipURL = try await catalog.downloadZip(for: entry)
                await MainActor.run {
                    isDownloadingUpdate = false
                    installer.load(zipURL: zipURL, existingScripts: scriptManager.scripts)
                }
            } catch {
                await MainActor.run {
                    isDownloadingUpdate = false
                    updateError = "Download failed: \(error.localizedDescription)"
                }
            }
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
}
