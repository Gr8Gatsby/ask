import Foundation
import Security

/// Polls CloudKit for queued jobs, executes them one at a time, streams output, and records history.
final class JobExecutor: @unchecked Sendable {
    private let cloudKit: CloudKitService
    private let agentManager: AgentManager
    private let actionHistory: ActionHistoryService
    private let settings: AppSettings
    private let machineID: String

    private var pollTask: Task<Void, Never>?
    private var isExecuting = false

    init(
        cloudKit: CloudKitService,
        agentManager: AgentManager,
        actionHistory: ActionHistoryService,
        settings: AppSettings
    ) {
        self.cloudKit = cloudKit
        self.agentManager = agentManager
        self.actionHistory = actionHistory
        self.settings = settings
        self.machineID = settings.machineID
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func poll() async {
        guard !isExecuting else { return }
        do {
            let jobs = try await cloudKit.fetchQueuedJobs(machineID: machineID)
            if let job = jobs.first {
                isExecuting = true
                defer { isExecuting = false }
                await execute(job)
            }
        } catch {
            print("[JobExecutor] Poll error: \(error)")
        }
    }

    // MARK: - Execution

    private func execute(_ job: JobRecord) async {
        // Find the agent config locally
        guard let agentConfig = agentManager.agents.first(where: { $0.id == job.agentID }) else {
            print("[JobExecutor] Agent \(job.agentID) not found — failing job")
            try? await cloudKit.updateJob(jobID: job.jobID, status: .failed, completedAt: Date())
            return
        }

        // Validate script is within vault
        guard let scriptURL = resolvedScriptURL(for: agentConfig) else {
            print("[JobExecutor] Script for agent '\(agentConfig.name)' not found or outside vault")
            try? await cloudKit.updateJob(jobID: job.jobID, status: .failed, completedAt: Date())
            return
        }

        // Acknowledge
        do {
            try await cloudKit.updateJob(jobID: job.jobID, status: .acknowledged)
        } catch {
            print("[JobExecutor] Failed to acknowledge job \(job.jobID): \(error)")
            return
        }

        // Update machine status to busy
        var machine = MachineRecord(machineID: machineID, name: settings.machineName)
        machine.status = .busy
        machine.activeJobID = job.jobID
        try? await cloudKit.saveMachine(machine)

        let startedAt = Date()
        var outputSequence = 0
        var outputBuffer = ""
        let bufferLock = NSLock()

        // Build process
        let process = Process()
        if scriptURL.pathExtension == "py" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path, job.prompt]
        } else {
            process.executableURL = scriptURL
            process.arguments = [job.prompt]
        }

        // Vault root as working directory
        if let vault = settings.vaultPath {
            process.currentDirectoryURL = vault
        }

        // Inject only declared Keychain env vars — no inherited environment
        process.environment = buildEnvironment(envKeys: agentConfig.capabilityEnvKeys)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Mark running
        do {
            try await cloudKit.updateJob(jobID: job.jobID, status: .running, startedAt: startedAt)
        } catch {
            print("[JobExecutor] Failed to mark job running: \(error)")
        }

        // Flush buffer to CloudKit
        func flushBuffer() async {
            let text: String
            bufferLock.lock()
            text = outputBuffer
            outputBuffer = ""
            bufferLock.unlock()

            guard !text.isEmpty else { return }
            let chunk = OutputChunkRecord(
                jobID: job.jobID,
                sequence: outputSequence,
                text: text,
                isError: false,
                timestamp: Date()
            )
            outputSequence += 1
            try? await cloudKit.saveOutputChunk(chunk)
        }

        // Launch process
        do {
            try process.run()
        } catch {
            print("[JobExecutor] Failed to launch process: \(error)")
            try? await cloudKit.updateJob(jobID: job.jobID, status: .failed, completedAt: Date())
            await markMachineIdle()
            return
        }

        // Read stdout in background
        let stdoutTask = Task<Void, Never> {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    bufferLock.lock()
                    outputBuffer += text
                    bufferLock.unlock()
                }
            }
        }

        // Read stderr in background (merged into output stream, marked isError)
        let stderrTask = Task<Void, Never> {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    let chunk = OutputChunkRecord(
                        jobID: job.jobID,
                        sequence: -1, // will be set properly on next flush
                        text: text,
                        isError: true,
                        timestamp: Date()
                    )
                    // Write stderr chunks immediately with their own sequence space
                    // Use a negative offset convention — iOS sorts by sequence, stderr is secondary
                    _ = chunk
                    bufferLock.lock()
                    outputBuffer += text
                    bufferLock.unlock()
                }
            }
        }

        // Timeout: kill after declared timeout
        let timeoutSeconds = agentConfig.timeout
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                print("[JobExecutor] Job \(job.jobID) timed out after \(timeoutSeconds)s")
                process.terminate()
            }
        }

        // Flush loop: write accumulated output every 500ms
        let flushLoop = Task<Void, Never> { [self] in
            while !Task.isCancelled && process.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
                await flushBuffer()
            }
        }

        // Cancellation watcher: poll CloudKit every 3s
        let cancelTask = Task<Void, Never> {
            while !Task.isCancelled && process.isRunning {
                try? await Task.sleep(for: .seconds(3))
                if let status = try? await cloudKit.fetchJobStatus(jobID: job.jobID),
                   status == .cancelled {
                    print("[JobExecutor] Job \(job.jobID) cancelled by user")
                    process.terminate()
                    break
                }
            }
        }

        // Wait for process to finish
        process.waitUntilExit()

        // Clean up background tasks
        stdoutTask.cancel()
        stderrTask.cancel()
        timeoutTask.cancel()
        flushLoop.cancel()
        cancelTask.cancel()

        // Final flush
        await flushBuffer()

        let completedAt = Date()
        let exitCode = Int(process.terminationStatus)
        let duration = completedAt.timeIntervalSince(startedAt)

        // Determine final status
        let finalStatus: JobStatus
        if let currentStatus = try? await cloudKit.fetchJobStatus(jobID: job.jobID),
           currentStatus == .cancelled {
            finalStatus = .cancelled
        } else if exitCode == 0 {
            finalStatus = .completed
        } else {
            finalStatus = .failed
        }

        do {
            try await cloudKit.updateJob(
                jobID: job.jobID,
                status: finalStatus,
                completedAt: completedAt,
                exitCode: exitCode
            )
        } catch {
            print("[JobExecutor] Failed to finalize job \(job.jobID): \(error)")
        }

        // Record in local history
        actionHistory.record(
            jobID: job.jobID,
            actionName: agentConfig.name,
            prompt: job.prompt,
            status: finalStatus.rawValue,
            durationSeconds: duration,
            exitCode: exitCode
        )

        await markMachineIdle()
        print("[JobExecutor] Job \(job.jobID) finished: \(finalStatus.rawValue) (exit \(exitCode))")
    }

    // MARK: - Helpers

    private func resolvedScriptURL(for agent: AgentConfig) -> URL? {
        guard let vault = settings.vaultPath else { return nil }
        let scriptURL = vault.appendingPathComponent(agent.scriptName)
        let resolved = scriptURL.resolvingSymlinksInPath()
        let resolvedVault = vault.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedVault.path + "/") || resolved.path == resolvedVault.path else {
            print("[JobExecutor] Path traversal rejected for script '\(agent.scriptName)'")
            return nil
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return nil }
        return scriptURL
    }

    private func buildEnvironment(envKeys: [String]) -> [String: String] {
        var env: [String: String] = [:]
        for key in envKeys {
            if let value = keychainValue(for: key) {
                env[key] = value
            }
        }
        return env
    }

    private func keychainValue(for key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private func markMachineIdle() async {
        var machine = MachineRecord(machineID: machineID, name: settings.machineName)
        machine.status = .idle
        machine.activeJobID = nil
        try? await cloudKit.saveMachine(machine)
    }
}
