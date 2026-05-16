import AppKit
import CloudKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "Diagnostics")

// MARK: - Models

enum DiagnosticStatus: String, Sendable {
    case ok
    case warning
    case fail
    case info

    var symbol: String {
        switch self {
        case .ok:      "✅"
        case .warning: "⚠️"
        case .fail:    "❌"
        case .info:    "ℹ️"
        }
    }
}

struct Diagnostic: Identifiable, Sendable {
    let id: String       // stable identifier, e.g. "hooks.session_start"
    let label: String
    let status: DiagnosticStatus
    let detail: String
    let fixHint: String?
}

struct DiagnosticSection: Identifiable, Sendable {
    let id: String
    let title: String
    let diagnostics: [Diagnostic]
}

struct DiagnosticReport: Sendable {
    let runAt: Date
    let sections: [DiagnosticSection]
    let machine: String
    let osVersion: String
    let appVersion: String
    let appPath: String
    let appBuildKind: String
}

// MARK: - Service

@Observable
final class DiagnosticsService {

    private(set) var report: DiagnosticReport?
    private(set) var isRunning = false
    private(set) var lastError: String?

    weak var scriptManager: ScriptManager?
    let settings: AppSettings
    weak var cloudKit: CloudKitService?
    weak var appUpdater: AppUpdater?
    weak var sessions: SessionsService?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Public entry points

    @MainActor
    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        defer { isRunning = false }

        var sections: [DiagnosticSection] = []
        sections.append(await Self.systemSection())
        sections.append(await Self.askMacSection(settings: settings))
        sections.append(await Self.updaterSection(appUpdater: appUpdater))
        sections.append(await Self.updateLogsSection())
        sections.append(await Self.cloudKitSection(cloudKit: cloudKit))
        sections.append(await Self.hooksSection())
        sections.append(await Self.daemonsSection(scriptManager: scriptManager))
        sections.append(await Self.scriptsSection(scriptManager: scriptManager, settings: settings))
        sections.append(await Self.sessionsSection())
        sections.append(await Self.sessionsTabReadoutSection(sessions: sessions))
        sections.append(await Self.toolsSection())
        sections.append(await Self.orphansAndLocksSection(scriptManager: scriptManager))
        sections.append(await Self.crashesSection())
        sections.append(await Self.probeSection(scriptManager: scriptManager))
        sections.append(await Self.recentHookEventsSection())
        sections.append(await Self.recentErrorsSection())

        self.report = DiagnosticReport(
            runAt: Date(),
            sections: sections,
            machine: Self.machineName(),
            osVersion: Self.macOSVersion(),
            appVersion: Self.askMacVersion(),
            appPath: Bundle.main.bundlePath,
            appBuildKind: Self.buildKind()
        )
    }

    @MainActor
    func copyMarkdownToClipboard() {
        guard let report = report else { return }
        let md = Self.renderMarkdown(report)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)
    }

    // MARK: - Sections

    static func systemSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        diags.append(Diagnostic(id: "sys.macos", label: "macOS version",
                                status: .info, detail: macOSVersion(), fixHint: nil))
        diags.append(Diagnostic(id: "sys.arch", label: "Architecture",
                                status: .info, detail: cpuArch(), fixHint: nil))
        let path = Bundle.main.bundlePath
        diags.append(Diagnostic(id: "sys.app_path", label: "AskMac path",
                                status: .info, detail: path, fixHint: nil))
        diags.append(Diagnostic(id: "sys.build_kind", label: "Build kind",
                                status: .info, detail: buildKind(), fixHint: nil))
        diags.append(Diagnostic(id: "sys.version", label: "AskMac version",
                                status: .info, detail: askMacVersion(), fixHint: nil))
        diags.append(Diagnostic(id: "sys.signature", label: "Code signature",
                                status: .info, detail: codeSignIdentity(), fixHint: nil))
        diags.append(Diagnostic(id: "sys.uptime", label: "System uptime",
                                status: .info, detail: systemUptime(), fixHint: nil))
        diags.append(Diagnostic(id: "sys.disk", label: "$HOME disk free",
                                status: .info, detail: diskFree(), fixHint: nil))
        return DiagnosticSection(id: "system", title: "System", diagnostics: diags)
    }

    @MainActor
    static func updaterSection(appUpdater: AppUpdater?) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        guard let updater = appUpdater else {
            diags.append(Diagnostic(id: "updater.unavail", label: "Sparkle updater",
                                    status: .info, detail: "service unavailable", fixHint: nil))
            return DiagnosticSection(id: "updater", title: "Sparkle updater", diagnostics: diags)
        }
        diags.append(Diagnostic(
            id: "updater.can_check",
            label: "Can check for updates",
            status: updater.canCheckForUpdates ? .ok : .info,
            detail: updater.canCheckForUpdates ? "yes" : "no (busy or just started)",
            fixHint: nil
        ))
        if let err = updater.lastUpdateError {
            diags.append(Diagnostic(
                id: "updater.last_error",
                label: "Last update error",
                status: .fail,
                detail: err,
                fixHint: "Install latest PKG manually: https://github.com/Gr8Gatsby/ask/releases/latest"
            ))
        } else {
            diags.append(Diagnostic(id: "updater.no_error", label: "Recent errors",
                                    status: .ok, detail: "none since launch", fixHint: nil))
        }
        return DiagnosticSection(id: "updater", title: "Sparkle updater", diagnostics: diags)
    }

    /// Pulls the macOS unified-log entries that touch Sparkle and AskMac's
    /// own update flow, plus the recent /var/log/install.log tail. The whole
    /// point is "press one button" — if the Sparkle delegate didn't catch an
    /// error, the raw logs almost always have it, and users shouldn't need
    /// to type `log show` commands.
    ///
    /// Each subprocess is bounded by a small predicate window and a tail so
    /// we never produce more than a few KB. The shell helpers run synchronously
    /// off the main actor via the diagnostic Task; the section as a whole is
    /// `async` so the caller awaits.
    static func updateLogsSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []

        // 1. macOS unified log, scoped to Sparkle subsystem. Captures most
        //    Sparkle library errors: bad signature, download failure, helper
        //    crash, etc.
        let sparkleLog = runShell("/usr/bin/log", "show",
                                  "--predicate", "subsystem CONTAINS \"Sparkle\"",
                                  "--last", "30m",
                                  "--info",
                                  "--style", "compact")
        let sparkleLines = sparkleLog
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Timestamp") && !$0.contains("Filtering the log data") }
            .suffix(25)
        if sparkleLines.isEmpty {
            diags.append(Diagnostic(
                id: "logs.sparkle.empty",
                label: "Sparkle subsystem log",
                status: .info,
                detail: "no Sparkle entries in the last 30 min",
                fixHint: nil
            ))
        } else {
            diags.append(Diagnostic(
                id: "logs.sparkle.recent",
                label: "Sparkle subsystem log (last \(sparkleLines.count))",
                status: .info,
                detail: sparkleLines.joined(separator: "\n"),
                fixHint: nil
            ))
        }

        // 2. AskMac's own process log, filtered for update/installer chatter.
        //    Catches anything we logged from AppUpdater or surrounding views.
        let askmacLog = runShell("/usr/bin/log", "show",
                                 "--predicate", "process == \"AskMac\"",
                                 "--last", "30m",
                                 "--info",
                                 "--style", "compact")
        let askmacLines = askmacLog
            .split(separator: "\n")
            .filter { line in
                let l = line.lowercased()
                return l.contains("sparkle") || l.contains("update") || l.contains("appcast")
                    || l.contains("signature") || l.contains("download")
            }
            .suffix(15)
        if askmacLines.isEmpty {
            diags.append(Diagnostic(
                id: "logs.askmac.empty",
                label: "AskMac update-related log",
                status: .info,
                detail: "no update chatter in the last 30 min",
                fixHint: nil
            ))
        } else {
            diags.append(Diagnostic(
                id: "logs.askmac.recent",
                label: "AskMac update log (last \(askmacLines.count))",
                status: .info,
                detail: askmacLines.joined(separator: "\n"),
                fixHint: nil
            ))
        }

        // 3. /var/log/install.log — the macOS Installer's own log. Surfaces
        //    silent PKG postinstall failures (the bug pattern that bit us on
        //    the work machine).
        let installLog = runShell("/usr/bin/tail", "-200", "/var/log/install.log")
        let installLines = installLog
            .split(separator: "\n")
            .filter { $0.lowercased().contains("askmac") }
            .suffix(15)
        if installLines.isEmpty {
            diags.append(Diagnostic(
                id: "logs.installer.empty",
                label: "macOS Installer log (AskMac)",
                status: .info,
                detail: "no AskMac installer entries in the last 200 lines",
                fixHint: nil
            ))
        } else {
            diags.append(Diagnostic(
                id: "logs.installer.recent",
                label: "macOS Installer log (last \(installLines.count))",
                status: .info,
                detail: installLines.joined(separator: "\n"),
                fixHint: nil
            ))
        }

        return DiagnosticSection(id: "update-logs", title: "Update logs", diagnostics: diags)
    }

    static func askMacSection(settings: AppSettings) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let pid = ProcessInfo.processInfo.processIdentifier
        diags.append(Diagnostic(id: "app.pid", label: "AskMac PID",
                                status: .info, detail: "\(pid)", fixHint: nil))
        let vault = settings.vaultPath?.path ?? "(unset)"
        let isDevVault = vault.contains(".ask/dev-vault")
        diags.append(Diagnostic(
            id: "app.vault",
            label: "Vault path",
            status: isDevVault ? .warning : .ok,
            detail: vault,
            fixHint: isDevVault ? "Prod build reading from dev vault — relaunch AskMac (v1.2.0+ auto-heals)." : nil
        ))
        diags.append(Diagnostic(id: "app.bundled", label: "usesBundledScripts",
                                status: .info, detail: "\(settings.usesBundledScripts)", fixHint: nil))
        let loginItem = isLoginItem()
        diags.append(Diagnostic(id: "app.login_item", label: "Auto-launch at login",
                                status: .info, detail: loginItem ? "yes" : "no", fixHint: nil))
        return DiagnosticSection(id: "askmac", title: "AskMac state", diagnostics: diags)
    }

    static func cloudKitSection(cloudKit: CloudKitService?) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let status: String
        if let cloudKit = cloudKit {
            do {
                let s = try await CKContainer.default().accountStatus()
                switch s {
                case .available:   status = "available"
                case .noAccount:   status = "no iCloud account"
                case .restricted:  status = "restricted"
                case .couldNotDetermine: status = "could not determine"
                case .temporarilyUnavailable: status = "temporarily unavailable"
                @unknown default: status = "unknown (\(s.rawValue))"
                }
            } catch {
                status = "error: \(error.localizedDescription)"
            }
            _ = cloudKit // silence unused
        } else {
            status = "service unavailable"
        }
        let isOK = status == "available"
        diags.append(Diagnostic(id: "ck.account", label: "iCloud account",
                                status: isOK ? .ok : .fail,
                                detail: status,
                                fixHint: isOK ? nil : "Sign in to iCloud in System Settings."))
        diags.append(Diagnostic(id: "ck.container", label: "Container",
                                status: .info, detail: "iCloud.simple.ask", fixHint: nil))
        let envEnt = entitlementValue(key: "com.apple.developer.icloud-container-environment")
        let env = envEnt.isEmpty ? "(default)" : envEnt
        diags.append(Diagnostic(id: "ck.env", label: "icloud-container-environment",
                                status: .info, detail: env, fixHint: nil))

        // Per-record-type schema-presence probe. Only runs when the
        // account is available; otherwise the result would always be
        // "error: not authenticated".
        if isOK, let cloudKit = cloudKit {
            let probes = await cloudKit.probeRecordTypes()
            for type in CloudKitService.probedRecordTypes {
                let result = probes[type] ?? .error(description: "no result")
                let (status, detail, fix): (DiagnosticStatus, String, String?) = {
                    switch result {
                    case .present(let count, let capped):
                        return (.ok, capped ? "present (≥\(count) records)" : "present (\(count) record\(count == 1 ? "" : "s"))", nil)
                    case .notDeployed:
                        return (.info,
                                "not deployed (no records of this type in account schema yet)",
                                nil)
                    case .error(let desc):
                        return (.warning, "error: \(desc)", "Check CloudKit Dashboard for container iCloud.simple.ask.")
                    }
                }()
                diags.append(Diagnostic(
                    id: "ck.type.\(type)",
                    label: "Record type · \(type)",
                    status: status,
                    detail: detail,
                    fixHint: fix
                ))
            }
        }

        return DiagnosticSection(id: "cloudkit", title: "CloudKit", diagnostics: diags)
    }

    /// Mirrors the live Sessions tab into the report: banner state plus
    /// row counts grouped by origin and machine. Reusing the same in-
    /// memory state guarantees the report cannot disagree with the UI.
    @MainActor
    static func sessionsTabReadoutSection(sessions: SessionsService?) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        guard let sessions = sessions else {
            diags.append(Diagnostic(
                id: "sessions_tab.unavailable",
                label: "Sessions tab",
                status: .info,
                detail: "service not wired into diagnostics",
                fixHint: nil
            ))
            return DiagnosticSection(id: "sessions_tab", title: "Sessions tab readout", diagnostics: diags)
        }

        let rows = sessions.sessions
        diags.append(Diagnostic(
            id: "sessions_tab.row_count",
            label: "Rows rendered",
            status: .info,
            detail: "\(rows.count) total · \(rows.filter { $0.isLocal }.count) local · \(rows.filter { !$0.isLocal }.count) remote",
            fixHint: nil
        ))

        let groups = sessions.groupedByMachine()
        for group in groups {
            diags.append(Diagnostic(
                id: "sessions_tab.group.\(group.machineID)",
                label: group.isThisMac ? "This Mac · \(group.machineName)" : group.machineName,
                status: .info,
                detail: "\(group.sessions.count) row\(group.sessions.count == 1 ? "" : "s")",
                fixHint: nil
            ))
        }

        diags.append(Diagnostic(
            id: "sessions_tab.banner.local",
            label: "Local banner",
            status: sessions.localUnavailable == nil ? .ok : .warning,
            detail: sessions.localUnavailable ?? "(none)",
            fixHint: nil
        ))
        diags.append(Diagnostic(
            id: "sessions_tab.banner.remote",
            label: "Remote banner",
            status: sessions.remoteUnavailable == nil ? .ok : .warning,
            detail: sessions.remoteUnavailable ?? "(none)",
            fixHint: nil
        ))

        return DiagnosticSection(id: "sessions_tab", title: "Sessions tab readout", diagnostics: diags)
    }

    static func hooksSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let settingsPath = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: settingsPath)
        diags.append(Diagnostic(
            id: "hooks.settings_json",
            label: "~/.claude/settings.json",
            status: exists ? .ok : .fail,
            detail: exists ? "present" : "missing",
            fixHint: exists ? nil : "Reload claude-3 in AskMac → it installs hooks."
        ))

        if exists {
            let url = URL(fileURLWithPath: settingsPath)
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hooks = json["hooks"] as? [String: Any] {
                let expected = ["SessionStart", "Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact", "PermissionRequest"]
                for event in expected {
                    let referenced = hooks[event] != nil
                    let claudeHook = (hooks[event] as? [[String: Any]] ?? [])
                        .flatMap { (($0["hooks"] as? [[String: Any]]) ?? []) }
                        .compactMap { $0["command"] as? String }
                        .first { $0.contains("claude-3/hooks") }
                    var status: DiagnosticStatus = referenced ? .ok : .fail
                    var detail = ""
                    var fix: String? = nil
                    if let cmd = claudeHook {
                        let path = cmd.components(separatedBy: " ").last ?? cmd
                        let fileExists = FileManager.default.fileExists(atPath: path)
                        let executable = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
                            .map { ($0 & 0o111) != 0 } ?? false
                        if !fileExists {
                            status = .fail
                            detail = "file missing: \(path)"
                            fix = "Reload claude-3 in AskMac."
                        } else if !executable {
                            status = .warning
                            detail = "not executable: \(path)"
                            fix = "chmod +x \(path)"
                        } else {
                            detail = "ok — \(path)"
                        }
                    } else if referenced {
                        status = .warning
                        detail = "registered but not for claude-3"
                    } else {
                        detail = "not registered"
                        fix = "Reload claude-3 in AskMac."
                    }
                    diags.append(Diagnostic(id: "hooks.\(event)", label: event,
                                            status: status, detail: detail, fixHint: fix))
                }
            } else {
                diags.append(Diagnostic(id: "hooks.parse", label: "settings.json parse",
                                        status: .fail, detail: "could not parse JSON",
                                        fixHint: "Inspect ~/.claude/settings.json by hand."))
            }
        }
        return DiagnosticSection(id: "hooks", title: "Hooks (Claude Code)", diagnostics: diags)
    }

    static func daemonsSection(scriptManager: ScriptManager?) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let socketDir = ("~/.ask/sockets" as NSString).expandingTildeInPath
        let entries: [String] = (try? FileManager.default.contentsOfDirectory(atPath: socketDir)) ?? []

        // Build set of currently-installed script IDs so we don't flag stale sockets
        // from scripts the user has since uninstalled (e.g. claudecode-controller,
        // codex-controller). Without this filter, every uninstalled-but-orphan-socket
        // shows as a red ❌ that the user can't fix.
        let installedScriptIDs: Set<String> = Set((scriptManager?.scripts ?? []).map { $0.id })

        for sock in entries.sorted() where sock.hasSuffix(".sock") {
            let path = "\(socketDir)/\(sock)"
            let name = (sock as NSString).deletingPathExtension
            // Skip sockets from uninstalled scripts — they are stale files,
            // not failures. Cleaning them up is a separate concern.
            guard installedScriptIDs.contains(name) else { continue }
            let alive = await pingUnixSocket(path: path, timeout: 2.0)
            diags.append(Diagnostic(
                id: "daemon.socket.\(name)",
                label: "\(name) socket",
                status: alive ? .ok : .fail,
                detail: alive ? "accepts connections at \(path)" : "connection refused at \(path)",
                fixHint: alive ? nil : "Reload \(name) in AskMac to respawn daemon."
            ))
        }

        // Daemon processes: PID + parent PID. Orphan if PPID=1.
        let psOutput = runShell("/bin/ps", "-axo", "pid,ppid,command")
        let askmacPID = ProcessInfo.processInfo.processIdentifier
        var liveDaemons: [(pid: Int32, ppid: Int32, cmd: String)] = []
        var orphanDaemons: [(pid: Int32, ppid: Int32, cmd: String)] = []
        for line in psOutput.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            let cmd = parts[2]
            guard cmd.contains("/.ask/scripts/") || cmd.contains("/.ask/dev-vault/") else { continue }
            guard cmd.hasSuffix("main.sh") || cmd.hasSuffix("main.py") else { continue }
            if ppid == 1 {
                orphanDaemons.append((pid, ppid, cmd))
            } else {
                liveDaemons.append((pid, ppid, cmd))
            }
        }
        diags.append(Diagnostic(
            id: "daemon.process_count",
            label: "Running daemons",
            status: liveDaemons.isEmpty ? .warning : .ok,
            detail: "\(liveDaemons.count) child of AskMac (pid=\(askmacPID))",
            fixHint: liveDaemons.isEmpty ? "No daemons spawned — reload scripts in AskMac." : nil
        ))
        diags.append(Diagnostic(
            id: "daemon.orphans",
            label: "Orphan daemons (PPID=1)",
            status: orphanDaemons.isEmpty ? .ok : .fail,
            detail: "\(orphanDaemons.count)",
            fixHint: orphanDaemons.isEmpty ? nil : "Run `pkill -f '\\.ask/(scripts|dev-vault)/.*main\\.(sh|py)'` to clean up; v1.2.0+ AskMac auto-reaps on launch."
        ))
        _ = scriptManager
        return DiagnosticSection(id: "daemons", title: "Daemons", diagnostics: diags)
    }

    static func scriptsSection(scriptManager: ScriptManager?, settings: AppSettings) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        guard let sm = scriptManager else {
            diags.append(Diagnostic(id: "scripts.unavailable", label: "ScriptManager",
                                    status: .warning, detail: "service unavailable", fixHint: nil))
            return DiagnosticSection(id: "scripts", title: "Scripts", diagnostics: diags)
        }
        for script in sm.scripts where !script.isSystem {
            let enabled = !settings.disabledScripts.contains(script.id)
            let label = "\(script.name) (\(script.id))"
            let detail = "v\(script.version ?? "?") · \(enabled ? "enabled" : "disabled")"
            let status: DiagnosticStatus = enabled ? .ok : .info
            diags.append(Diagnostic(id: "script.\(script.id)", label: label,
                                    status: status, detail: detail, fixHint: nil))
        }
        return DiagnosticSection(id: "scripts", title: "Scripts", diagnostics: diags)
    }

    /// Expanded Session Health section. For each daemon registry it
    /// surfaces the registry path + count, per-session detail rows,
    /// live `ps` process count, live tmux pane count, and a delta
    /// summary line that flips to warning when the daemon under-counts.
    static func sessionsSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let registries: [(label: String, file: String, exec: String)] = [
            ("claude-3", "~/.ask/claude3-sessions.json", "claude"),
            ("codex-3",  "~/.ask/codex3-sessions.json",  "codex"),
        ]
        let now = Date().timeIntervalSince1970

        for (label, file, exec) in registries {
            let path = (file as NSString).expandingTildeInPath
            let registered = parseSessionRegistry(at: path)
            let liveProcesses = countLiveProcesses(executable: exec)
            let livePanes = countTmuxPanes(currentCommand: exec)

            diags.append(Diagnostic(
                id: "sessions.\(label).registry",
                label: "\(label) registry",
                status: .info,
                detail: registered == nil ? "missing or unreadable — \(file)" : "\(registered!.count) sessions · \(file)",
                fixHint: nil
            ))

            if let sessions = registered {
                // Per-session detail rows. Routed-or-not flag is derived
                // from presence of `tty` or `tmux_target`.
                let sorted = sessions.sorted { $0.key < $1.key }
                for (sid, info) in sorted {
                    let state = (info["state"] as? String) ?? "?"
                    let cwd   = (info["cwd"] as? String) ?? ""
                    let tty   = (info["tty"] as? String) ?? ""
                    let tmux  = (info["tmux_target"] as? String) ?? ""
                    let lastSeen = (info["last_seen"] as? Double) ?? 0
                    let ageSec   = lastSeen > 0 ? Int(max(0, now - lastSeen)) : -1
                    let routed   = !tty.isEmpty || !tmux.isEmpty
                    let detail =
                        "state=\(state) · cwd=\(cwd.isEmpty ? "—" : cwd) · tty=\(tty.isEmpty ? "—" : tty)"
                        + " · tmux=\(tmux.isEmpty ? "—" : tmux) · age=\(ageSec < 0 ? "—" : "\(ageSec)s")"
                        + " · routed=\(routed ? "yes" : "no")"
                    diags.append(Diagnostic(
                        id: "sessions.\(label).row.\(sid)",
                        label: "\(label) · \(sid)",
                        status: routed ? .info : .warning,
                        detail: detail,
                        fixHint: routed ? nil : "Daemon has no terminal routing for this session. If a live process exists, reload \(label) to trigger discover_sessions."
                    ))
                }
            }

            // Live signal rows + delta summary.
            diags.append(Diagnostic(
                id: "sessions.\(label).live_processes",
                label: "\(label) live processes",
                status: .info,
                detail: "\(liveProcesses) running (matched by executable name)",
                fixHint: nil
            ))
            diags.append(Diagnostic(
                id: "sessions.\(label).tmux_panes",
                label: "\(label) tmux panes",
                status: .info,
                detail: livePanes == nil ? "n/a (tmux unavailable)" : "\(livePanes!) panes running \(exec)",
                fixHint: nil
            ))

            let registeredCount = registered?.count ?? 0
            let referenceCount = max(liveProcesses, livePanes ?? 0)
            let missing = max(0, referenceCount - registeredCount)
            diags.append(Diagnostic(
                id: "sessions.\(label).delta",
                label: "\(label) delta",
                status: missing > 0 ? .warning : .ok,
                detail: "registered=\(registeredCount) · live_processes=\(liveProcesses) · tmux_panes=\(livePanes.map(String.init) ?? "n/a") · missing=\(missing)",
                fixHint: missing > 0 ? "Daemon registry is short by \(missing). Reload \(label) so discover_sessions re-scans live processes / tmux panes." : nil
            ))
        }
        return DiagnosticSection(id: "sessions", title: "Session Health", diagnostics: diags)
    }

    /// Reads and parses a daemon session-registry JSON file. Returns
    /// `nil` if the file is missing OR cannot be parsed; an empty
    /// dictionary means "file is present but contains zero sessions".
    private static func parseSessionRegistry(at path: String) -> [String: [String: Any]]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return nil }
        return json
    }

    /// Counts processes belonging to the current user whose command-line
    /// basename matches `executable`. Equivalent to `pgrep -f` filtered
    /// by basename, but avoids depending on pgrep behavior across macOS
    /// versions.
    private static func countLiveProcesses(executable: String) -> Int {
        let ps = runShell("/bin/ps", "-axo", "command")
        var count = 0
        for line in ps.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // First whitespace-separated token is the command path/name.
            let first = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let base = (first as NSString).lastPathComponent
            if base == executable { count += 1 }
        }
        return count
    }

    /// Counts tmux panes whose `pane_current_command` equals `currentCommand`.
    /// Returns `nil` when tmux is not installed or no server is running.
    private static func countTmuxPanes(currentCommand: String) -> Int? {
        guard let tmuxPath = which("tmux") else { return nil }
        // -a = across all sessions. If no server is running, tmux exits
        // non-zero with empty output; we treat that as "0 panes" but
        // distinguish it from "tmux unavailable" by checking for tmux's
        // presence first.
        let out = runShell(tmuxPath, "list-panes", "-a", "-F", "#{pane_current_command}")
        let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        return lines.filter { $0 == currentCommand }.count
    }

    static func toolsSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let tools: [(label: String, cmd: String, arg: String)] = [
            ("Claude Code CLI", "claude", "--version"),
            ("Codex CLI", "codex", "--version"),
            ("tmux", "tmux", "-V"),
            ("python3", "python3", "--version"),
        ]
        for t in tools {
            let path = which(t.cmd)
            let installed = path != nil
            let version: String = installed ? runShell(path!, t.arg).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            diags.append(Diagnostic(
                id: "tool.\(t.cmd)",
                label: t.label,
                status: installed ? .ok : .warning,
                detail: installed ? "\(version) — \(path!)" : "not in PATH",
                fixHint: installed ? nil : "Install \(t.cmd) and re-launch AskMac so the daemon picks it up."
            ))
        }
        return DiagnosticSection(id: "tools", title: "Required CLIs", diagnostics: diags)
    }

    static func orphansAndLocksSection(scriptManager: ScriptManager? = nil) async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let runDir = ("~/.ask/run" as NSString).expandingTildeInPath
        let installedScriptIDs: Set<String> = Set((scriptManager?.scripts ?? []).map { $0.id })

        guard let lockFiles = try? FileManager.default.contentsOfDirectory(atPath: runDir).filter({ $0.hasSuffix(".lock") }) else {
            diags.append(Diagnostic(id: "locks.dir_missing", label: "Lock directory",
                                    status: .ok, detail: "no ~/.ask/run dir yet", fixHint: nil))
            return DiagnosticSection(id: "locks", title: "Locks & guards", diagnostics: diags)
        }

        var heldByLive = 0, abandoned = 0, foreign = 0
        for lock in lockFiles {
            let path = "\(runDir)/\(lock)"
            let scriptID = (lock as NSString).deletingPathExtension
            // Suppress stale locks from scripts no longer installed — they're
            // harmless artifacts, not actionable signals.
            guard installedScriptIDs.contains(scriptID) else { foreign += 1; continue }
            // Two lock formats in the wild:
            //   1. PID-file (current bash daemons): the lock file contains the
            //      holder's PID as a single line. The writer closes the file
            //      immediately, so lsof will not report any holder even when
            //      the script is running fine — we must parse the PID and
            //      check kill(0) instead.
            //   2. flock-style (legacy): the holder keeps fd 9 open as long
            //      as it runs, so lsof correctly reports a live holder.
            //
            // Try PID-file first; if the file doesn't contain a usable PID,
            // fall back to lsof for flock-style. Without this, every bash
            // daemon running the v1.3.4+ PID-file lock got reported as
            // "abandoned" while it was actually running fine.
            var isHeld = false
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed), pid > 0 {
                    // kill(pid, 0) — does NOT send a signal, returns 0 if the
                    // process exists and we have permission to signal it.
                    isHeld = (kill(pid, 0) == 0)
                }
            }
            if !isHeld {
                let lsof = runShell("/usr/sbin/lsof", path).trimmingCharacters(in: .whitespacesAndNewlines)
                isHeld = lsof.split(separator: "\n").count > 1   // header + ≥1 entry
            }
            if isHeld {
                heldByLive += 1
                diags.append(Diagnostic(id: "locks.\(lock).held", label: "\(scriptID) lock",
                                        status: .ok, detail: "held by live daemon", fixHint: nil))
            } else {
                abandoned += 1
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let mtime = (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                diags.append(Diagnostic(
                    id: "locks.\(lock).stale",
                    label: "\(scriptID) lock",
                    status: .warning,
                    detail: "abandoned (no live holder) — last touched \(mtime)",
                    fixHint: "rm \(path) — script will recreate on next start"
                ))
            }
        }

        if heldByLive == 0 && abandoned == 0 && foreign == 0 {
            diags.append(Diagnostic(id: "locks.empty", label: "Single-instance locks",
                                    status: .ok, detail: "none present", fixHint: nil))
        } else if foreign > 0 {
            diags.append(Diagnostic(id: "locks.foreign", label: "Stale locks (uninstalled scripts)",
                                    status: .info,
                                    detail: "\(foreign) lock file\(foreign == 1 ? "" : "s") for scripts no longer installed — harmless",
                                    fixHint: nil))
        }

        return DiagnosticSection(id: "locks", title: "Locks & guards", diagnostics: diags)
    }

    static func crashesSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let crashDir = ("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath
        let entries: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: crashDir)) ?? [])
            .filter { $0.hasPrefix("AskMac-") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .sorted()
        let recent = entries.suffix(5)
        if recent.isEmpty {
            diags.append(Diagnostic(id: "crashes.none", label: "Recent AskMac crashes",
                                    status: .ok, detail: "none in DiagnosticReports", fixHint: nil))
        } else {
            for f in recent {
                diags.append(Diagnostic(id: "crashes.\(f)", label: f,
                                        status: .warning, detail: "\(crashDir)/\(f)",
                                        fixHint: "Open in Console.app to inspect."))
            }
        }
        return DiagnosticSection(id: "crashes", title: "Crash reports", diagnostics: diags)
    }

    static func probeSection(scriptManager: ScriptManager?) async -> DiagnosticSection {
        // Quick internal probe: socket ping + MCP RPC roundtrip via existing daemons.
        var diags: [Diagnostic] = []
        let socketPath = ("~/.ask/sockets/claude-3.sock" as NSString).expandingTildeInPath
        let socketAlive = await pingUnixSocket(path: socketPath, timeout: 2.0)
        diags.append(Diagnostic(
            id: "probe.socket",
            label: "claude-3 socket ping",
            status: socketAlive ? .ok : .fail,
            detail: socketAlive ? "responded" : "no response",
            fixHint: socketAlive ? nil : "Daemon down — reload claude-3."
        ))
        _ = scriptManager
        return DiagnosticSection(id: "probe", title: "Internal probe", diagnostics: diags)
    }

    /// Parses recent `socket event type=...` lines from the claude-3/codex-3
    /// daemon logs and reports a per-type tally + the most recent event.
    /// Lets us see whether hooks (session_start, user_prompt, session_stop, ...)
    /// are actually reaching the daemon, separately from whether the daemon
    /// emits anything back. Critical when chat history isn't appearing on
    /// iPhone but the terminal-side conversation looks fine — we need to
    /// know whether the Stop hook is even arriving.
    static func recentHookEventsSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let daemons = ["claude-3", "codex-3"]
        for name in daemons {
            let path = ("~/.ask/logs/\(name).log" as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }
            let suffix = data.suffix(131_072)
            let text = String(data: suffix, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n")
            let eventLines = lines.filter { $0.contains("socket event type=") }
            if eventLines.isEmpty {
                diags.append(Diagnostic(
                    id: "hooks.\(name).none",
                    label: "\(name) hook events",
                    status: .warning,
                    detail: "no socket events seen in last 128KB of log",
                    fixHint: "If you've been actively using claude on this machine, hooks may not be reaching the daemon. Check ~/.claude/settings.json and the daemon socket."
                ))
                continue
            }
            var counts: [String: Int] = [:]
            for line in eventLines {
                if let r = line.range(of: "socket event type='") {
                    let after = line[r.upperBound...]
                    if let end = after.firstIndex(of: "'") {
                        let type = String(after[..<end])
                        counts[type, default: 0] += 1
                    }
                }
            }
            let summary = counts.sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            let last = eventLines.suffix(1).first.map(String.init) ?? ""
            diags.append(Diagnostic(
                id: "hooks.\(name).summary",
                label: "\(name) hook events",
                status: .ok,
                detail: "\(summary)\nmost recent: \(last)",
                fixHint: nil
            ))
        }
        if diags.isEmpty {
            diags.append(Diagnostic(
                id: "hooks.none",
                label: "Hook events",
                status: .info,
                detail: "no daemon logs present yet",
                fixHint: nil
            ))
        }
        return DiagnosticSection(id: "hook-events", title: "Recent hook events", diagnostics: diags)
    }

    static func recentErrorsSection() async -> DiagnosticSection {
        var diags: [Diagnostic] = []
        let logs = ["claude-3", "codex-3", "terminal-manager"]
        for name in logs {
            let path = ("~/.ask/logs/\(name).log" as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }
            // Read last ~32 KB of the log
            let suffix = data.suffix(32_768)
            let text = String(data: suffix, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n")
            let errors = lines.filter { $0.contains("[ERROR]") || $0.contains("[WARN]") }.suffix(10)
            if errors.isEmpty {
                diags.append(Diagnostic(id: "log.\(name).clean", label: "\(name).log",
                                        status: .ok, detail: "no recent errors/warns in last 32KB",
                                        fixHint: nil))
            } else {
                let detail = errors.joined(separator: "\n")
                diags.append(Diagnostic(id: "log.\(name).errors", label: "\(name).log (last \(errors.count))",
                                        status: .warning, detail: detail, fixHint: nil))
            }
        }
        return DiagnosticSection(id: "logs", title: "Recent log errors", diagnostics: diags)
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(_ report: DiagnosticReport) -> String {
        let df = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# AskMac Diagnostics Report")
        lines.append("")
        lines.append("- **Generated:** \(df.string(from: report.runAt))")
        lines.append("- **Machine:** \(report.machine)")
        lines.append("- **macOS:** \(report.osVersion)")
        lines.append("- **AskMac:** v\(report.appVersion) · \(report.appBuildKind)")
        lines.append("- **Path:** `\(report.appPath)`")
        lines.append("")
        for section in report.sections {
            lines.append("## \(section.title)")
            lines.append("")
            for d in section.diagnostics {
                lines.append("- \(d.status.symbol) **\(d.label)** — \(d.detail)")
                if let fix = d.fixHint {
                    lines.append("    - _fix:_ \(fix)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func machineName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func askMacVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static func buildKind() -> String {
        let path = Bundle.main.bundlePath
        if path.contains("DerivedData") { return "Debug (DerivedData)" }
        if path.contains("/.build/") { return "Debug (SwiftPM)" }
        if path.hasPrefix("/Applications/") { return "Release" }
        return "Custom (\(path))"
    }

    static func cpuArch() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func codeSignIdentity() -> String {
        // codesign emits to stderr, not stdout. Capture both.
        let out = runShellCombined("/usr/bin/codesign", "-dvv", Bundle.main.bundlePath)
        // Order of probing: prefer Developer ID (release), then Apple Development (dev),
        // then any Authority line. "ad-hoc / unsigned" only when we truly find no Authority.
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Authority=Developer ID Application") { return s }
        }
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Authority=Developer ID") { return s }
            if s.hasPrefix("Authority=Apple Development") { return s }
        }
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Authority=") { return s }
        }
        if out.contains("Signed Time=") || out.contains("TeamIdentifier=") {
            return "signed (no explicit Authority found in codesign output)"
        }
        return "ad-hoc / unsigned"
    }

    /// `runShell` only captures stdout; `codesign` writes its descriptor info to stderr.
    static func runShellCombined(_ launchPath: String, _ args: String...) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func systemUptime() -> String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let d = s / 86_400
        let h = (s % 86_400) / 3_600
        let m = (s % 3_600) / 60
        return "\(d)d \(h)h \(m)m"
    }

    static func diskFree() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else {
            return "?"
        }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB]
        fmt.countStyle = .file
        return "\(fmt.string(fromByteCount: free)) free of \(fmt.string(fromByteCount: Int64(total)))"
    }

    static func entitlementValue(key: String) -> String {
        let out = runShell("/usr/bin/codesign", "-d", "--entitlements", "-", Bundle.main.bundlePath)
        // crude but works: find the key and the next <string>
        guard let r = out.range(of: key) else { return "" }
        let tail = out[r.upperBound...]
        if let s = tail.range(of: "<string>"), let e = tail.range(of: "</string>", range: s.upperBound..<tail.endIndex) {
            return String(tail[s.upperBound..<e.lowerBound])
        }
        return ""
    }

    static func isLoginItem() -> Bool {
        // Best-effort: check `osascript` for AskMac in login items list
        let out = runShell("/usr/bin/osascript", "-e",
                           "tell application \"System Events\" to get the name of every login item")
        return out.contains("AskMac")
    }

    static func which(_ cmd: String) -> String? {
        // Common locations + PATH
        let candidates = [
            "/usr/local/bin/\(cmd)",
            "/opt/homebrew/bin/\(cmd)",
            "\(NSHomeDirectory())/.local/bin/\(cmd)",
            "/usr/bin/\(cmd)",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let out = runShell("/usr/bin/which", cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func runShell(_ launchPath: String, _ args: String...) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Synchronous Unix-socket connect with a wall-clock timeout.
    /// Runs on a background queue so callers can `await` without blocking the actor.
    static func pingUnixSocket(path: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false); return
                }
                defer { close(fd) }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = path.utf8CString
                guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                    continuation.resume(returning: false); return
                }
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                        pathBytes.withUnsafeBufferPointer { src in
                            _ = memcpy(dest, src.baseAddress, pathBytes.count)
                        }
                    }
                }

                // Per-syscall timeout via SO_SNDTIMEO. `connect` will return EAGAIN/ETIMEDOUT
                // if the daemon doesn't accept within `timeout` seconds.
                var tv = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
                )
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let r = withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                continuation.resume(returning: r == 0)
            }
        }
    }

    /// `ps -axo pid,command` and parse `lsof` for cwd, scoped to processes matching `executableMatches`.
    /// Map of cwd → (pid, cmd).
    static func livePIDsByCwd(executableMatches: [String]) -> [String: (pid: Int32, cmd: String)] {
        var result: [String: (Int32, String)] = [:]
        let ps = runShell("/bin/ps", "-axo", "pid,command")
        for line in ps.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let cmd = parts[1]
            let exe = (cmd.split(separator: " ").first.map(String.init)) ?? ""
            let base = (exe as NSString).lastPathComponent
            guard executableMatches.contains(base) else { continue }
            let lsof = runShell("/usr/sbin/lsof", "-p", "\(pid)")
            for l in lsof.split(separator: "\n") where l.contains("cwd") {
                let cols = l.split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 9 {
                    let cwd = String(cols.last!)
                    result[cwd] = (pid, cmd)
                }
            }
        }
        return result
    }
}
