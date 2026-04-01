import Foundation

// MARK: - TerminalSession

public struct TerminalSession: Sendable {
    public let pid: Int
    public let name: String
    public let tty: String
    public let cwd: String
    public let tabTitle: String?

    // nonisolated overrides the project-wide @MainActor default so this struct
    // can be constructed and read from any actor context (e.g. TerminalMonitorService).
    public nonisolated init(pid: Int, name: String, tty: String, cwd: String, tabTitle: String? = nil) {
        self.pid = pid
        self.name = name
        self.tty = tty
        self.cwd = cwd
        self.tabTitle = tabTitle
    }

    /// JSON-serialisable dictionary matching the MCP response schema.
    public nonisolated var asDictionary: [String: Any] {
        var d: [String: Any] = ["pid": pid, "name": name, "tty": tty, "cwd": cwd]
        if let t = tabTitle { d["tab_title"] = t }
        return d
    }
}

// MARK: - TerminalMonitorService

/// Scans for interactive terminal sessions (processes with a controlling TTY),
/// enriches them with tab titles from Terminal.app / iTerm2, and caches results
/// for 5 seconds.  Exposed to scripts via the `list_terminal_sessions` MCP tool.
///
/// The `shellRunner` and `appleScriptRunner` closures are injectable for testing.
public actor TerminalMonitorService {

    public typealias Runner = @Sendable (String, [String]) async -> String

    private let shellRunner: Runner
    private let appleScriptRunner: Runner
    private let cacheDuration: TimeInterval

    private var cachedSessions: [TerminalSession] = []
    private var cacheExpiry: Date = .distantPast

    public init(
        shell: Runner? = nil,
        appleScript: Runner? = nil,
        cacheDuration: TimeInterval = 5
    ) {
        self.shellRunner = shell ?? TerminalMonitorService.defaultShell
        self.appleScriptRunner = appleScript ?? TerminalMonitorService.defaultShell
        self.cacheDuration = cacheDuration
    }

    // MARK: - Public API

    /// Returns all known terminal sessions, optionally filtered by process name (case-insensitive substring).
    public func listSessions(filter: String? = nil) async -> [TerminalSession] {
        if Date() < cacheExpiry {
            return apply(filter, to: cachedSessions)
        }
        let sessions = await scan()
        cachedSessions = sessions
        cacheExpiry = Date().addingTimeInterval(cacheDuration)
        return apply(filter, to: sessions)
    }

    // MARK: - Private

    private func apply(_ filter: String?, to sessions: [TerminalSession]) -> [TerminalSession] {
        guard let f = filter, !f.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    private func scan() async -> [TerminalSession] {
        // Run ps and tab-title fetch concurrently.
        async let tabTitlesTask = fetchTabTitles()

        // ps -axo pid=,tty=,comm= : suppresses header, gives pid / tty / comm columns
        let psOut = await shellRunner("/bin/ps", ["-axo", "pid=,tty=,comm="])

        // Collect candidates that have a real TTY (not "??")
        var candidates: [(pid: Int, tty: String, name: String)] = []
        for line in psOut.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                           .components(separatedBy: .whitespaces)
                           .filter { !$0.isEmpty }
            guard parts.count >= 3,
                  let pid = Int(parts[0]),
                  parts[1] != "??" else { continue }
            let tty  = parts[1]
            // comm is everything after the tty column (handles spaces in paths)
            let comm = parts[2...].joined(separator: " ")
            let name = URL(fileURLWithPath: comm).lastPathComponent
            candidates.append((pid: pid, tty: tty, name: name))
        }

        guard !candidates.isEmpty else { return [] }

        // Batch lsof call: p<pid> / n<cwd> pairs
        let pidArg = candidates.map { String($0.pid) }.joined(separator: ",")
        let lsofOut = await shellRunner("/usr/sbin/lsof", ["-a", "-p", pidArg, "-d", "cwd", "-Fn"])

        var pidToCWD: [Int: String] = [:]
        var currentPID: Int? = nil
        for line in lsofOut.components(separatedBy: "\n") {
            if line.hasPrefix("p"), let pid = Int(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), let pid = currentPID {
                pidToCWD[pid] = String(line.dropFirst())
            }
        }

        let tabTitles = await tabTitlesTask

        var sessions: [TerminalSession] = []
        for c in candidates {
            guard let cwd = pidToCWD[c.pid],
                  cwd != "/", cwd != "/private" else { continue }
            sessions.append(TerminalSession(
                pid:      c.pid,
                name:     c.name,
                tty:      c.tty,
                cwd:      cwd,
                tabTitle: tabTitles[c.tty]
            ))
        }
        return sessions
    }

    /// Returns a map of tty (short form, e.g. "s003") → tab/session title.
    private func fetchTabTitles() async -> [String: String] {
        var result: [String: String] = [:]

        // Terminal.app — tty of tab returns "/dev/ttys003"
        let termScript = """
set output to ""
if application "Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            set tList to tabs of w
            repeat with t in tList
                try
                    set tTTY to tty of t
                    set tName to name of t
                    set output to output & tTTY & "||" & tName & "\n"
                end try
            end repeat
        end repeat
    end tell
end if
return output
"""
        let termOut = await appleScriptRunner("/usr/bin/osascript", ["-e", termScript])
        merge(appleScriptOutput: termOut, into: &result)

        // iTerm2 — tty of session also returns "/dev/ttys003"
        let itermScript = """
set output to ""
if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            set tList to tabs of w
            repeat with t in tList
                set sList to sessions of t
                repeat with s in sList
                    try
                        set sTTY to tty of s
                        set sName to name of s
                        set output to output & sTTY & "||" & sName & "\n"
                    end try
                end repeat
            end repeat
        end repeat
    end tell
end if
return output
"""
        let itermOut = await appleScriptRunner("/usr/bin/osascript", ["-e", itermScript])
        merge(appleScriptOutput: itermOut, into: &result)

        return result
    }

    /// Parse "||"-delimited lines from AppleScript output into tty → title entries.
    /// AppleScript returns "/dev/ttys003"; we strip "/dev/tty" → "s003" to match ps output.
    private func merge(appleScriptOutput output: String, into map: inout [String: String]) {
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "||")
            guard parts.count >= 2 else { continue }
            let rawTTY = parts[0].trimmingCharacters(in: .whitespaces)
            // "/dev/ttys003" → strip "/dev/tty" → "s003"
            let tty = rawTTY.hasPrefix("/dev/tty")
                ? String(rawTTY.dropFirst("/dev/tty".count))
                : rawTTY
            let title = parts[1...].joined(separator: "||")
                                   .trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty, !title.isEmpty else { continue }
            map[tty] = title
        }
    }

    // MARK: - Default shell runner

    private static let defaultShell: Runner = { path, args in
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
