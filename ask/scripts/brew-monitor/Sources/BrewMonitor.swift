import Foundation

// MARK: - Package model

struct BrewPackage {
    let name: String
    let installed: String
    let available: String
}

// MARK: - Block IDs

private let blockFeed     = "brew-monitor-feed"
private let blockUpdates  = "brew-monitor-updates"
private let blockStatus   = "brew-monitor-status"

// MARK: - BrewMonitor

/// One-shot feed script: checks for outdated Homebrew packages once, emits results,
/// optionally waits for an "Upgrade All" response, then exits.
actor BrewMonitor {
    private let mcp: MCPClient

    init(mcp: MCPClient) {
        self.mcp = mcp
    }

    // MARK: - Run (one-shot)

    func run() async {
        do {
            try await check()
        } catch {
            fputs("[brew-monitor] check error: \(error)\n", stderr)
        }
    }

    // MARK: - Check

    private func check() async throws {
        fputs("[brew-monitor] checking for outdated packages…\n", stderr)

        // Clear any stale blocks from previous runs
        await mcp.clearBlock(blockStatus)

        let outdated = getOutdated()
        let ttl30Days: TimeInterval = 30 * 24 * 3600

        if outdated.isEmpty {
            fputs("[brew-monitor] all packages up to date\n", stderr)
            await mcp.clearBlock(blockUpdates)
            try await mcp.emitBlock(blockFeed, type: "feed_item", payload: [
                "headline":     "Homebrew up to date",
                "status_color": "green"
            ], ttl: ttl30Days)
            return
        }

        let count = outdated.count
        let headline = "\(count) Homebrew \(count == 1 ? "package" : "packages") need updating"
        let body  = outdated.map { "\($0.name)  \($0.installed) → \($0.available)" }.joined(separator: "\n")

        fputs("[brew-monitor] \(headline)\n", stderr)

        // Post feed item (persistent, 30-day TTL)
        try await mcp.emitBlock(blockFeed, type: "feed_item", payload: [
            "headline":     headline,
            "body":         body,
            "status_color": "orange"
        ], ttl: ttl30Days)

        // Also post confirmation so user can act from the home screen
        let stream = await mcp.responseStream(blockID: blockUpdates)
        try await mcp.emitBlock(blockUpdates, type: "confirmation", payload: [
            "title":   headline,
            "body":    body,
            "options": ["Upgrade All", "Later"]
        ], ttl: 86400)

        // Wait up to 24 hours for a user response
        let response = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(86400))
                return nil
            }
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            return first
        }

        guard response == "Upgrade All" else {
            fputs("[brew-monitor] response: \(response ?? "timeout") — exiting\n", stderr)
            return
        }

        await mcp.clearBlock(blockUpdates)

        do {
            try await upgrade()
        } catch {
            fputs("[brew-monitor] upgrade error: \(error)\n", stderr)
        }

        // Post result feed item after upgrade
        let remaining = getOutdated()
        if remaining.isEmpty {
            try await mcp.emitBlock(blockFeed, type: "feed_item", payload: [
                "headline":     "Homebrew upgraded successfully",
                "body":         body,
                "status_color": "green"
            ], ttl: ttl30Days)
        } else {
            let remCount = remaining.count
            try await mcp.emitBlock(blockFeed, type: "feed_item", payload: [
                "headline":     "\(remCount) packages still need attention",
                "body":         remaining.map { "\($0.name)  \($0.installed) → \($0.available)" }.joined(separator: "\n"),
                "status_color": "orange"
            ], ttl: ttl30Days)
        }
    }

    // MARK: - Upgrade

    private func upgrade() async throws {
        fputs("[brew-monitor] running brew upgrade…\n", stderr)

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
        proc.standardInput  = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

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

    // MARK: - Pipe helper

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
        proc.standardInput  = Pipe()
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
