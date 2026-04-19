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
private let blockTile     = "brew-monitor-tile"

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
            await emitStatus(label: "Homebrew check failed", detail: String(describing: error), color: "red", ttl: 10 * 60)
        }
    }

    // MARK: - Check

    private func check() async throws {
        fputs("[brew-monitor] checking for outdated packages…\n", stderr)

        await mcp.clearBlock(blockStatus)
        await emitStatus(label: "Checking Homebrew…", detail: "Looking for outdated packages", color: "blue")

        guard findBrew() != nil else {
            throw BrewMonitorError.brewNotFound
        }

        let outdated = getOutdated()
        await mcp.clearBlock(blockStatus)

        let now = Date()
        let nowStr = ISO8601DateFormatter.localShort.string(from: now)

        if outdated.isEmpty {
            fputs("[brew-monitor] all packages up to date\n", stderr)
            await mcp.clearBlock(blockUpdates)

            // Brief result status (visible for 2 minutes)
            await emitStatus(label: "Homebrew up to date", color: "green", ttl: 2 * 60)

            // Persistent tile
            await emitTile(label: "Up to date", statusColor: "green")

            // Feed item — simpler than a full A2A task for a routine all-clear
            try? await mcp.emitBlock(
                "brew-check-\(ISO8601DateFormatter.localDate.string(from: Date()))",
                type: "feed_item",
                payload: [
                    "title": "Homebrew up to date",
                    "body":  "Checked at \(nowStr) — all packages current.",
                    "icon":  "checkmark.circle.fill",
                ]
            )
            return
        }

        let count = outdated.count
        let noun     = count == 1 ? "update" : "updates"
        let headline = "\(count) Homebrew \(count == 1 ? "package" : "packages") need updating"
        let body     = outdated.map { "\($0.name)  \($0.installed) → \($0.available)" }.joined(separator: "\n")

        fputs("[brew-monitor] \(headline)\n", stderr)

        // Tile shows pending count so user can see it from home screen
        await emitTile(
            label: "\(count) \(noun) available",
            statusColor: "orange",
            actionRequired: true
        )
        await emitStatus(
            label: "Homebrew updates available",
            detail: "\(count) package\(count == 1 ? "" : "s") waiting",
            color: "orange"
        )

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
            await mcp.clearBlock(blockStatus)
            // Tile keeps showing "N updates available" until the next scheduled check
            return
        }

        await mcp.clearBlock(blockUpdates)

        try await runUpgradeTask(packages: outdated, nowStr: nowStr)
    }

    // MARK: - A2A: upgrade task

    private func runUpgradeTask(packages: [BrewPackage], nowStr: String) async throws {
        let taskID = "brew-upgrade-\(UUID().uuidString.prefix(8).lowercased())"
        let count  = packages.count
        let noun   = count == 1 ? "package" : "packages"
        let pkgTable = packages.map { "- **\($0.name)** \($0.installed) → \($0.available)" }.joined(separator: "\n")

        try await mcp.openTask(taskID, title: "Homebrew upgrade · \(nowStr)")
        try await mcp.appendMessage(taskID, role: "user", text: "Upgrade all outdated Homebrew packages.")
        try await mcp.appendMessage(taskID, role: "assistant", text: "Upgrading \(count) \(noun):\n\n\(pkgTable)")

        var outputLines: [String] = []
        var upgradeError: Error?

        do {
            outputLines = try await upgrade()
        } catch {
            upgradeError = error
        }

        let fullOutput = outputLines.joined(separator: "\n")
        let tableRows  = packages.map { "| \($0.name) | \($0.installed) | \($0.available) |" }.joined(separator: "\n")
        let succeeded  = upgradeError == nil

        let resultLine = succeeded
            ? "\(count) \(noun) upgraded successfully."
            : "Upgrade finished with errors: \(upgradeError!)"

        try await mcp.appendMessage(taskID, role: "assistant", text: resultLine)

        let report = """
        # Homebrew Upgrade Report — \(nowStr)

        ## \(succeeded ? "\(count) \(noun) upgraded" : "Upgrade failed (\(count) \(noun) attempted)")

        | Package | From | To |
        |---------|------|----|
        \(tableRows)

        ## Output
        ```
        \(fullOutput)
        ```

        ---
        Generated by brew-monitor at \(nowStr)
        """

        try await withTempFile(contents: report, extension: "md") { path in
            let filename = "brew-upgrade-\(nowStr.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "-")).md"
            try await mcp.putArtifact(
                taskID,
                artifactID: "brew-report-\(UUID().uuidString.prefix(8).lowercased())",
                filename: filename,
                mimeType: "text/markdown",
                description: "Homebrew upgrade log — \(count) \(noun)",
                filePath: path
            )
        }

        try await mcp.openTask(taskID, title: "Homebrew upgrade · \(nowStr)", status: succeeded ? "completed" : "failed")
        fputs("[brew-monitor] upgrade task written (\(taskID)) succeeded=\(succeeded)\n", stderr)

        // Update tile to reflect completed state
        if succeeded {
            await emitTile(label: "Upgraded \(count) \(noun)", statusColor: "green")
        } else {
            await emitTile(label: "Upgrade failed", statusColor: "red")
        }

        if let err = upgradeError { throw err }
    }

    // MARK: - Upgrade (returns captured output lines)

    @discardableResult
    private func upgrade() async throws -> [String] {
        fputs("[brew-monitor] running brew upgrade…\n", stderr)

        guard let brew = findBrew() else {
            fputs("[brew-monitor] brew not found\n", stderr)
            throw BrewMonitorError.brewNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["upgrade"]

        let pipe = Pipe()
        proc.standardInput  = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        try proc.run()

        var lastUpdate   = Date()
        var currentPkg   = ""
        var outputLines: [String] = []

        await emitStatus(label: "Upgrading Homebrew packages…", detail: "Starting brew upgrade", color: "blue")

        for await line in BrewMonitor.pipeLines(pipe.fileHandleForReading) {
            fputs("[brew-upgrade] \(line)\n", stderr)
            if !line.isEmpty { outputLines.append(line) }

            if line.hasPrefix("==> Upgrading ") {
                currentPkg = String(line.dropFirst("==> Upgrading ".count)).components(separatedBy: " ").first ?? currentPkg
            } else if line.hasPrefix("==> Installing ") {
                currentPkg = String(line.dropFirst("==> Installing ".count)).components(separatedBy: " ").first ?? currentPkg
            }

            let now = Date()
            guard !currentPkg.isEmpty, now.timeIntervalSince(lastUpdate) >= 3 else { continue }
            lastUpdate = now
            await emitStatus(label: "Upgrading Homebrew packages…", detail: "Installing \(currentPkg)", color: "blue")
        }

        proc.waitUntilExit()
        let rc = proc.terminationStatus
        fputs("[brew-monitor] brew upgrade exited \(rc)\n", stderr)
        await mcp.clearBlock(blockStatus)

        if rc != 0 {
            throw BrewMonitorError.upgradeFailed(code: Int(rc), detail: outputLines.last?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return outputLines
    }

    private func emitTile(
        label: String,
        statusColor: String,
        actionRequired: Bool = false
    ) async {
        var payload: [String: Any] = [
            "label":           label,
            "status_color":    statusColor,
            "action_required": actionRequired,
        ]
        try? await mcp.emitBlock(blockTile, type: "tile", payload: payload, ttl: 5 * 60 * 60)
    }

    private func emitStatus(
        label: String,
        detail: String? = nil,
        color: String,
        ttl: TimeInterval = 3 * 60 * 60
    ) async {
        var payload: [String: Any] = [
            "label": label,
            "icon": color == "green" ? "checkmark.circle" : color == "red" ? "exclamationmark.triangle" : "arrow.down.circle",
            "color": color
        ]
        if let detail { payload["detail"] = detail }
        try? await mcp.emitBlock(blockStatus, type: "status", payload: payload, ttl: ttl)
    }

    // MARK: - Temp file helper

    /// Writes `contents` to a temp file, calls `body(path)`, then deletes the file.
    private func withTempFile(contents: String, extension ext: String, body: (String) async throws -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-monitor-\(UUID().uuidString).\(ext)")
        try contents.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await body(tmp.path)
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

// MARK: - Date helpers

private extension ISO8601DateFormatter {
    /// "2026-04-10 17:05" — compact local-time string for task titles and report headers.
    static let localShort: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        fmt.timeZone = .current
        return fmt
    }()

    /// "2026-04-10" — date-only string used as stable daily task/artifact IDs.
    static let localDate: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = .current
        return fmt
    }()
}

enum BrewMonitorError: Error, CustomStringConvertible {
    case brewNotFound
    case upgradeFailed(code: Int, detail: String?)

    var description: String {
        switch self {
        case .brewNotFound:
            return "Homebrew is not installed or not available on PATH."
        case .upgradeFailed(let code, let detail):
            if let detail, !detail.isEmpty {
                return "brew upgrade exited \(code): \(detail)"
            }
            return "brew upgrade exited \(code)"
        }
    }
}
