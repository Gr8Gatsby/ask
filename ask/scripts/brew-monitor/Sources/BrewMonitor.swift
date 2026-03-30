import Foundation

// MARK: - Package model

struct BrewPackage {
    let name: String
    let installed: String
    let available: String
}

// MARK: - Block IDs

private let blockUpdates  = "brew-monitor-updates"
private let blockStatus   = "brew-monitor-status"
private let blockUpToDate = "brew-monitor-uptodate"
private let blockNextSync = "brew-monitor-next-sync"
private let blockSyncNow  = "brew-monitor-sync-now"

// MARK: - BrewMonitor

actor BrewMonitor {
    private let mcp: MCPClient
    private let checkInterval: TimeInterval = 4 * 60 * 60
    private var sleepTask: Task<Void, Error>?

    init(mcp: MCPClient) {
        self.mcp = mcp
    }

    // MARK: - Run loop

    func run() async {
        while true {
            do {
                try await check()
            } catch is CancellationError {
                return
            } catch {
                fputs("[brew-monitor] check error: \(error)\n", stderr)
            }
            sleepTask = Task {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            }
            // Await the sleep; CancellationError means Sync Now was tapped — that's fine.
            try? await sleepTask?.value
            sleepTask = nil
            fputs("[brew-monitor] starting next check\n", stderr)
        }
    }

    // MARK: - Check

    private func check() async throws {
        fputs("[brew-monitor] checking for outdated packages…\n", stderr)

        // Clear countdown while checking so the status block takes its place.
        await mcp.clearBlock(blockNextSync)

        try await mcp.emitBlock(blockStatus, type: "status", payload: [
            "label": "Checking for Homebrew updates…",
            "icon":  "arrow.clockwise",
            "color": "blue"
        ], ttl: 60)

        let outdated = getOutdated()
        await mcp.clearBlock(blockStatus)

        if outdated.isEmpty {
            fputs("[brew-monitor] all packages up to date\n", stderr)
            await mcp.clearBlock(blockUpdates)
            let nextSyncHours = Int(checkInterval / 3600)
            try await mcp.emitBlock(blockUpToDate, type: "status", payload: [
                "label": "Up to date, next sync in \(nextSyncHours) hours",
                "icon":  "checkmark.circle",
                "color": "green"
            ], ttl: checkInterval)
        } else {
            await mcp.clearBlock(blockUpToDate)

            let count = outdated.count
            let title = "\(count) Homebrew \(count == 1 ? "update" : "updates") available"
            let body  = outdated.map { "\($0.name)  \($0.installed) → \($0.available)" }.joined(separator: "\n")

            fputs("[brew-monitor] \(title)\n", stderr)

            // Register callback BEFORE emitting so a slow CloudKit write can't orphan it.
            await mcp.setCallback(blockID: blockUpdates) { [self] value in
                await onResponse(value)
            }

            try await mcp.emitBlock(blockUpdates, type: "confirmation", payload: [
                "title":   title,
                "body":    body,
                "options": ["Upgrade All", "Later"]
            ], ttl: 86400)
        }

        // Emit countdown to next scheduled check.
        let nextSync = Date(timeIntervalSinceNow: checkInterval)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nextSyncStr = iso.string(from: nextSync)
        try await mcp.emitBlock(blockNextSync, type: "countdown", payload: [
            "label": "Next sync",
            "time":  nextSyncStr
        ], ttl: checkInterval + 300)
        fputs("[brew-monitor] next sync at \(nextSyncStr)\n", stderr)

        // Emit persistent Sync Now button.
        await emitSyncNow()
    }

    // MARK: - Sync Now

    private func emitSyncNow() async {
        await mcp.setCallback(blockID: blockSyncNow) { [self] _ in
            await onSyncNow()
        }
        try? await mcp.emitBlock(blockSyncNow, type: "confirmation", payload: [
            "title":   "Homebrew",
            "body":    "Trigger an immediate package check.",
            "options": ["Sync Now"]
        ], ttl: checkInterval + 300)
    }

    private func onSyncNow() async {
        fputs("[brew-monitor] manual sync triggered\n", stderr)
        sleepTask?.cancel()
    }

    // MARK: - Response handler

    private func onResponse(_ value: String) async {
        await mcp.clearBlock(blockUpdates)
        guard value == "Upgrade All" else { return }

        do {
            try await upgrade()
        } catch {
            fputs("[brew-monitor] upgrade error: \(error)\n", stderr)
        }

        // Re-check after upgrade so UI shows new state immediately.
        do {
            try await check()
        } catch {
            fputs("[brew-monitor] post-upgrade check error: \(error)\n", stderr)
        }
    }

    // MARK: - Upgrade

    private func upgrade() async throws {
        fputs("[brew-monitor] running brew upgrade…\n", stderr)

        // TTL covers even the longest possible upgrade (3 h).
        try await mcp.emitBlock(blockStatus, type: "status", payload: [
            "label":  "Upgrading Homebrew packages…",
            "detail": "Starting…",
            "icon":   "arrow.down.circle",
            "color":  "blue"
        ], ttl: 3 * 60 * 60)

        defer {
            Task { await mcp.clearBlock(blockStatus) }
        }

        guard let brew = findBrew() else {
            fputs("[brew-monitor] brew not found\n", stderr)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["upgrade"]

        let pipe = Pipe()
        proc.standardInput  = Pipe()  // prevent brew from reading the MCP stdin pipe
        proc.standardOutput = pipe
        proc.standardError  = pipe   // merge so we capture all output

        try proc.run()

        var lastUpdate  = Date()
        var currentPkg  = ""

        for await line in BrewMonitor.pipeLines(pipe.fileHandleForReading) {
            fputs("[brew-upgrade] \(line)\n", stderr)

            if line.hasPrefix("==> Upgrading ") {
                currentPkg = String(line.dropFirst("==> Upgrading ".count))
                    .components(separatedBy: " ").first ?? currentPkg
            } else if line.hasPrefix("==> Installing ") {
                currentPkg = String(line.dropFirst("==> Installing ".count))
                    .components(separatedBy: " ").first ?? currentPkg
            }

            let now = Date()
            guard !currentPkg.isEmpty, now.timeIntervalSince(lastUpdate) >= 3 else { continue }
            lastUpdate = now
            // Best-effort status update — ignore CloudKit errors mid-stream.
            try? await mcp.emitBlock(blockStatus, type: "status", payload: [
                "label":  "Upgrading Homebrew packages…",
                "detail": "Installing \(currentPkg)",
                "icon":   "arrow.down.circle",
                "color":  "blue"
            ], ttl: 3 * 60 * 60)
        }

        proc.waitUntilExit()
        fputs("[brew-monitor] brew upgrade exited \(proc.terminationStatus)\n", stderr)

        if proc.terminationStatus == 0 {
            try? await mcp.emitBlock(blockStatus, type: "status", payload: [
                "label": "Upgrades complete",
                "icon":  "checkmark.circle",
                "color": "green"
            ], ttl: 30)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        } else {
            try? await mcp.emitBlock(blockStatus, type: "status", payload: [
                "label": "Upgrade finished with errors",
                "icon":  "exclamationmark.triangle",
                "color": "orange"
            ], ttl: 60)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    // MARK: - Pipe helpers

    /// Reads newline-delimited lines from a FileHandle using GCD readabilityHandler
    /// so cooperative threads are never blocked waiting for subprocess output.
    private static func pipeLines(_ fh: FileHandle) -> AsyncStream<String> {
        final class State: @unchecked Sendable { var buffer = Data() }
        let state = State()
        return AsyncStream { continuation in
            fh.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                state.buffer.append(chunk)
                while let range = state.buffer.range(of: Data([0x0A])) {
                    if let line = String(data: state.buffer[state.buffer.startIndex..<range.lowerBound], encoding: .utf8) {
                        continuation.yield(line)
                    }
                    state.buffer.removeSubrange(state.buffer.startIndex...range.lowerBound)
                }
            }
            continuation.onTermination = { _ in fh.readabilityHandler = nil }
        }
    }

    // MARK: - Brew helpers

    private func getOutdated() -> [BrewPackage] {
        guard let brew = findBrew() else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["outdated", "--json=v2"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput  = Pipe()  // prevent brew from reading the MCP stdin pipe
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var items: [BrewPackage] = []

        for entry in (json["formulae"] as? [[String: Any]]) ?? [] {
            guard let name = entry["name"] as? String else { continue }
            items.append(BrewPackage(
                name:      name,
                installed: cleanVersion(entry["installed_versions"]),
                available: cleanVersion(entry["current_version"])
            ))
        }

        for entry in (json["casks"] as? [[String: Any]]) ?? [] {
            guard let name = entry["name"] as? String else { continue }
            items.append(BrewPackage(
                name:      name,
                installed: cleanVersion(entry["installed_versions"]),
                available: cleanVersion(entry["current_version"])
            ))
        }

        return items.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func cleanVersion(_ value: Any?) -> String {
        let raw: String
        if let arr = value as? [Any], let first = arr.first {
            raw = String(describing: first)
        } else {
            raw = String(describing: value ?? "?")
        }
        // Strip cask build suffixes like ",1"
        return String(raw.split(separator: ",", maxSplits: 1).first ?? Substring(raw))
    }

    private func findBrew() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
