import Testing
import Foundation
@testable import AskMacCore

// MARK: - Helpers

/// Builds a mock shell runner that returns preset output for specific (path, args) pairs
/// and returns "" for anything else.
private func mockShell(_ responses: [String: String]) -> TerminalMonitorService.Runner {
    let captured = responses
    return { path, _ in
        if let r = captured[path] { return r }
        return ""
    }
}

/// Minimal `ps -axo pid=,tty=,comm=` output with one process entry.
private func psLine(pid: Int, tty: String, comm: String) -> String {
    "\(pid) \(tty) \(comm)"
}

/// lsof -Fn output for a single process.
private func lsofOutput(pid: Int, cwd: String) -> String {
    "p\(pid)\nn\(cwd)"
}

// MARK: - Tests

@Suite("TerminalMonitorService")
struct TerminalMonitorServiceTests {

    // MARK: Basic filtering

    @Test("Returns empty array when no processes match filter")
    func emptyWhenNoMatch() async {
        let ps = psLine(pid: 100, tty: "s001", comm: "bash")
        let lsof = lsofOutput(pid: 100, cwd: "/tmp")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let result = await svc.listSessions(filter: "claude")
        #expect(result.isEmpty)
    }

    @Test("Returns session when process name matches filter")
    func returnsMatchingSession() async {
        let ps = psLine(pid: 1234, tty: "s003", comm: "/usr/local/bin/claude")
        let lsof = lsofOutput(pid: 1234, cwd: "/Users/kevin/project")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let result = await svc.listSessions(filter: "claude")
        #expect(result.count == 1)
        #expect(result[0].pid == 1234)
        #expect(result[0].name == "claude")
        #expect(result[0].tty == "s003")
        #expect(result[0].cwd == "/Users/kevin/project")
    }

    @Test("Filter is case-insensitive")
    func filterCaseInsensitive() async {
        let ps = psLine(pid: 5678, tty: "s005", comm: "Claude")
        let lsof = lsofOutput(pid: 5678, cwd: "/tmp/work")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let upper = await svc.listSessions(filter: "CLAUDE")
        #expect(upper.count == 1)
    }

    @Test("No filter returns all sessions")
    func noFilterReturnsAll() async {
        let ps = [
            psLine(pid: 1, tty: "s001", comm: "bash"),
            psLine(pid: 2, tty: "s002", comm: "claude"),
            psLine(pid: 3, tty: "s003", comm: "codex"),
        ].joined(separator: "\n")
        let lsof = [
            lsofOutput(pid: 1, cwd: "/tmp/a"),
            lsofOutput(pid: 2, cwd: "/tmp/b"),
            lsofOutput(pid: 3, cwd: "/tmp/c"),
        ].joined(separator: "\n")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let result = await svc.listSessions()
        #expect(result.count == 3)
    }

    // MARK: TTY filtering

    @Test("Skips processes with no TTY (background daemons)")
    func skipsDaemonProcesses() async {
        let ps = [
            psLine(pid: 100, tty: "??", comm: "launchd"),
            psLine(pid: 200, tty: "s002", comm: "claude"),
        ].joined(separator: "\n")
        let lsof = lsofOutput(pid: 200, cwd: "/home/project")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let result = await svc.listSessions()
        #expect(result.count == 1)
        #expect(result[0].pid == 200)
    }

    @Test("Skips processes with cwd of / or /private")
    func skipsSystemCWDs() async {
        let ps = [
            psLine(pid: 1, tty: "s001", comm: "systemd"),
            psLine(pid: 2, tty: "s002", comm: "process"),
            psLine(pid: 3, tty: "s003", comm: "claude"),
        ].joined(separator: "\n")
        let lsof = [
            lsofOutput(pid: 1, cwd: "/"),
            lsofOutput(pid: 2, cwd: "/private"),
            lsofOutput(pid: 3, cwd: "/Users/kevin/work"),
        ].joined(separator: "\n")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },
            cacheDuration: 60
        )
        let result = await svc.listSessions()
        #expect(result.count == 1)
        #expect(result[0].cwd == "/Users/kevin/work")
    }

    // MARK: Tab title enrichment

    @Test("Tab title included when Terminal.app AppleScript succeeds")
    func tabTitleIncluded() async {
        let ps = psLine(pid: 999, tty: "s004", comm: "claude")
        let lsof = lsofOutput(pid: 999, cwd: "/Users/kevin/code")
        // AppleScript output: "/dev/ttys004||ask — claude"
        let appleScriptOut = "/dev/ttys004||ask — claude\n"
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in appleScriptOut },
            cacheDuration: 60
        )
        let result = await svc.listSessions()
        #expect(result.count == 1)
        #expect(result[0].tabTitle == "ask — claude")
    }

    @Test("tab_title omitted when AppleScript fails")
    func tabTitleOmittedOnFailure() async {
        let ps = psLine(pid: 777, tty: "s006", comm: "codex")
        let lsof = lsofOutput(pid: 777, cwd: "/tmp/proj")
        let svc = TerminalMonitorService(
            shell: mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof]),
            appleScript: { _, _ in "" },   // simulate AppleScript returning nothing
            cacheDuration: 60
        )
        let result = await svc.listSessions()
        #expect(result.count == 1)
        #expect(result[0].tabTitle == nil)
    }

    @Test("asDictionary omits tab_title key when nil")
    func asDictionaryOmitsNilTitle() async {
        let session = TerminalSession(pid: 1, name: "claude", tty: "s001", cwd: "/tmp")
        let dict = session.asDictionary
        #expect(dict["tab_title"] == nil)
        #expect(dict["pid"] as? Int == 1)
    }

    @Test("asDictionary includes tab_title when present")
    func asDictionaryIncludesTitle() async {
        let session = TerminalSession(pid: 1, name: "claude", tty: "s001", cwd: "/tmp", tabTitle: "my tab")
        let dict = session.asDictionary
        #expect(dict["tab_title"] as? String == "my tab")
    }

    // MARK: Caching

    @Test("Cache returns same result within TTL without re-scanning")
    func cacheHitWithinTTL() async {
        // Use an actor-isolated counter to avoid concurrent mutation.
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter()
        let ps = psLine(pid: 100, tty: "s001", comm: "claude")
        let lsof = lsofOutput(pid: 100, cwd: "/tmp")
        let svc = TerminalMonitorService(
            shell: { path, args in
                if path == "/bin/ps" { await counter.increment() }
                return await mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof])(path, args)
            },
            appleScript: { _, _ in "" },
            cacheDuration: 60  // 60 second TTL — won't expire during test
        )
        _ = await svc.listSessions()
        _ = await svc.listSessions()
        let count = await counter.value
        #expect(count == 1, "ps should only be called once within TTL")
    }

    @Test("Cache is invalidated after TTL expires")
    func cacheExpires() async {
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter()
        let ps = psLine(pid: 100, tty: "s001", comm: "claude")
        let lsof = lsofOutput(pid: 100, cwd: "/tmp")
        let svc = TerminalMonitorService(
            shell: { path, args in
                if path == "/bin/ps" { await counter.increment() }
                return await mockShell(["/bin/ps": ps, "/usr/sbin/lsof": lsof])(path, args)
            },
            appleScript: { _, _ in "" },
            cacheDuration: 0  // zero TTL — expires immediately
        )
        _ = await svc.listSessions()
        _ = await svc.listSessions()
        let count = await counter.value
        #expect(count == 2, "ps should be called twice when TTL is zero")
    }
}
