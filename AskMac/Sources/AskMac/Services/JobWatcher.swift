import Foundation
import Observation

/// Polls CloudKit for queued jobs assigned to this machine and dispatches them to JobExecutor.
/// One job runs at a time. Additional queued jobs are picked up after the current one finishes.
@Observable
final class JobWatcher {
    private let cloudKit: CloudKitService
    private let executor: JobExecutor
    private let heartbeat: HeartbeatService
    private let settings: AppSettings

    private var pollTask: Task<Void, Never>?
    private var currentJobTask: Task<Void, Never>?

    private(set) var currentJob: JobRecord?
    private(set) var isExecuting = false
    private(set) var lastError: Error?

    static let pollInterval: TimeInterval = 10

    init(cloudKit: CloudKitService, executor: JobExecutor, heartbeat: HeartbeatService, settings: AppSettings) {
        self.cloudKit = cloudKit
        self.executor = executor
        self.heartbeat = heartbeat
        self.settings = settings
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            // Check immediately on start (catches queued jobs from when Mac was offline)
            await poll()
            for await _ in AsyncTimerSequence(interval: Self.pollInterval) {
                guard !Task.isCancelled else { return }
                await poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentJobTask?.cancel()
        currentJobTask = nil
    }

    // MARK: - Private

    private func poll() async {
        guard !isExecuting else { return }

        do {
            let jobs = try await cloudKit.fetchQueuedJobs(machineID: settings.machineID)
            guard let job = jobs.first else { return }
            guard let agentConfig = settings.agents.first(where: { $0.id == job.agentID }) else {
                // Agent not found on this machine — mark failed with explanation
                try? await cloudKit.updateJob(
                    jobID: job.jobID,
                    status: .failed,
                    completedAt: Date(),
                    exitCode: -1
                )
                return
            }
            await dispatch(job: job, agent: agentConfig)
        } catch {
            lastError = error
        }
    }

    private func dispatch(job: JobRecord, agent: AgentConfig) async {
        isExecuting = true
        currentJob = job

        await heartbeat.markBusy(jobID: job.jobID)

        currentJobTask = Task {
            await executor.execute(job: job, agent: agent)
            await MainActor.run {
                self.isExecuting = false
                self.currentJob = nil
            }
            await heartbeat.markIdle()
        }

        await currentJobTask?.value
    }
}
