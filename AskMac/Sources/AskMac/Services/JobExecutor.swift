import Foundation
import Security

/// Executes a registered agent script for a given job.
/// Streams stdout/stderr back to CloudKit as OutputChunk records.
final class JobExecutor {
    private let cloudKit: CloudKitService
    private let settings: AppSettings

    init(cloudKit: CloudKitService, settings: AppSettings) {
        self.cloudKit = cloudKit
        self.settings = settings
    }

    /// Runs the agent script for the given job.
    /// Updates job status throughout and streams output chunks.
    func execute(job: JobRecord, agent: AgentConfig) async {
        // TODO: Verify job.signature against paired iOS public key before executing.
        // This is the cryptographic gate that ensures only the paired iPhone can trigger execution.

        guard let scriptURL = settings.scriptURL(for: agent) else {
            await failJob(job, message: "Script '\(agent.scriptName)' not found in vault.")
            return
        }

        guard isWithinVault(scriptURL) else {
            await failJob(job, message: "Security error: script is outside the registered vault directory.")
            return
        }

        let resolvedEnv = resolveEnvironment(for: agent)

        do {
            try await cloudKit.updateJob(jobID: job.jobID, status: .acknowledged)
            try await cloudKit.updateJob(jobID: job.jobID, status: .running, startedAt: Date())
        } catch {
            await failJob(job, message: "Failed to update job status: \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = scriptURL
        // Prompt is passed as the sole argument — never shell-interpolated.
        process.arguments = [job.prompt]
        process.environment = resolvedEnv
        process.currentDirectoryURL = settings.vaultPath

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            await failJob(job, message: "Failed to launch script: \(error.localizedDescription)")
            return
        }

        // Stream output concurrently from stdout and stderr
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.streamPipe(
                    stdoutPipe,
                    jobID: job.jobID,
                    isError: false,
                    sequenceBase: 0
                )
            }
            group.addTask {
                await self.streamPipe(
                    stderrPipe,
                    jobID: job.jobID,
                    isError: true,
                    sequenceBase: 500_000
                )
            }
            group.addTask {
                await self.watchTimeout(process: process, timeout: agent.timeout, jobID: job.jobID)
            }
        }

        process.waitUntilExit()
        let exitCode = Int(process.terminationStatus)

        do {
            let finalStatus: JobStatus = exitCode == 0 ? .completed : .failed
            try await cloudKit.updateJob(
                jobID: job.jobID,
                status: finalStatus,
                completedAt: Date(),
                exitCode: exitCode
            )
        } catch {
            // Best-effort — log locally but don't re-fail
            print("[JobExecutor] Failed to update final job status: \(error)")
        }
    }

    // MARK: - Private

    private func streamPipe(_ pipe: Pipe, jobID: String, isError: Bool, sequenceBase: Int) async {
        var sequence = sequenceBase
        let handle = pipe.fileHandleForReading

        let dataStream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }

        for await data in dataStream {
            guard !data.isEmpty else { continue }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }

            let chunk = OutputChunkRecord(
                jobID: jobID,
                sequence: sequence,
                text: text,
                isError: isError,
                timestamp: Date()
            )
            try? await cloudKit.saveOutputChunk(chunk)
            sequence += 1
        }
    }

    private func watchTimeout(process: Process, timeout: Int, jobID: String) async {
        try? await Task.sleep(for: .seconds(timeout))
        guard process.isRunning else { return }
        process.terminate()
        let chunk = OutputChunkRecord(
            jobID: jobID,
            sequence: 999_999,
            text: "\n[Ask] Job timed out after \(timeout) seconds and was terminated.\n",
            isError: true,
            timestamp: Date()
        )
        try? await cloudKit.saveOutputChunk(chunk)
    }

    /// Resolves the environment dictionary for the script.
    /// Only injects keys declared in the agent's capability config — sourced from Keychain.
    private func resolveEnvironment(for agent: AgentConfig) -> [String: String] {
        var env: [String: String] = [:]
        for key in agent.capabilityEnvKeys {
            if let value = keychainSecret(named: key) {
                env[key] = value
            }
        }
        return env
    }

    /// Reads a generic password from the macOS Keychain by service name.
    private func keychainSecret(named name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.simple.ask.\(name)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Verifies that the script URL is within the registered vault directory.
    private func isWithinVault(_ scriptURL: URL) -> Bool {
        guard let vault = settings.vaultPath else { return false }
        let vaultPath = vault.standardizedFileURL.path
        let scriptPath = scriptURL.standardizedFileURL.path
        return scriptPath.hasPrefix(vaultPath + "/") || scriptPath == vaultPath
    }

    private func failJob(_ job: JobRecord, message: String) async {
        let chunk = OutputChunkRecord(
            jobID: job.jobID,
            sequence: 0,
            text: "[Ask Error] \(message)\n",
            isError: true,
            timestamp: Date()
        )
        try? await cloudKit.saveOutputChunk(chunk)
        try? await cloudKit.updateJob(
            jobID: job.jobID,
            status: .failed,
            completedAt: Date(),
            exitCode: -1
        )
    }
}
