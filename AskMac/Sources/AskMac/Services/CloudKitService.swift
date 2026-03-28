import Foundation
import CloudKit
import Observation

@Observable
final class CloudKitService {
    private let container: CKContainer
    private let database: CKDatabase

    // Cached CKRecord objects keyed by recordName — used to update in place without refetching
    private var cachedRecords: [String: CKRecord] = [:]

    private(set) var accountStatus: CKAccountStatus = .couldNotDetermine

    init() {
        self.container = CKContainer(identifier: CKSchema.containerID)
        self.database = container.privateCloudDatabase
    }

    // MARK: - Account

    func checkAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
        }
    }

    // MARK: - Machine

    /// Creates or updates the Machine record for this installation.
    func saveMachine(_ machine: MachineRecord) async throws {
        let record = existingRecord(named: machine.machineID, type: CKSchema.RecordType.machine)
        let updated = machine.applying(to: record)
        let saved = try await save(updated)
        cachedRecords[machine.machineID] = saved
    }

    // MARK: - Agents

    /// Publishes all configured agents for this machine to CloudKit so the iOS app can discover them.
    func saveAgent(_ agent: AgentRecord) async throws {
        let record = existingRecord(named: agent.recordName, type: CKSchema.RecordType.agent)
        let updated = agent.applying(to: record)
        let saved = try await save(updated)
        cachedRecords[agent.recordName] = saved
    }

    /// Removes an agent record from CloudKit.
    func deleteAgent(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        try await database.deleteRecord(withID: recordID)
        cachedRecords.removeValue(forKey: recordName)
    }

    // MARK: - Events

    func saveEvent(title: String, body: String, source: String) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.event)
        record[CKSchema.Event.title] = title
        record[CKSchema.Event.body] = body
        record[CKSchema.Event.source] = source
        record[CKSchema.Event.timestamp] = Date()
        _ = try await save(record)
    }

    // MARK: - Jobs

    /// Fetches all jobs assigned to this machine with status "queued", oldest first.
    func fetchQueuedJobs(machineID: String) async throws -> [JobRecord] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.Job.machineID, machineID,
            CKSchema.Job.status, JobStatus.queued.rawValue
        )
        let query = CKQuery(recordType: CKSchema.RecordType.job, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Job.createdAt, ascending: true)]

        let (results, _) = try await database.records(matching: query, resultsLimit: 10)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            cachedRecords[record.recordID.recordName] = record
            return JobRecord(record: record)
        }
    }

    /// Updates a job's status fields. Fetches from cache or CloudKit, then saves.
    func updateJob(jobID: String, status: JobStatus, startedAt: Date? = nil, completedAt: Date? = nil, exitCode: Int? = nil) async throws {
        let record = try await fetchOrCachedRecord(named: jobID, type: CKSchema.RecordType.job)
        record[CKSchema.Job.status] = status.rawValue
        if let startedAt { record[CKSchema.Job.startedAt] = startedAt }
        if let completedAt { record[CKSchema.Job.completedAt] = completedAt }
        if let exitCode { record[CKSchema.Job.exitCode] = Int64(exitCode) }

        let saved = try await save(record)
        cachedRecords[jobID] = saved
    }

    // MARK: - Output chunks

    /// Saves a single output chunk. Fire-and-forget friendly — caller can use Task { try? await }.
    func saveOutputChunk(_ chunk: OutputChunkRecord) async throws {
        let record = chunk.toCKRecord()
        _ = try await save(record)
    }

    // MARK: - Private helpers

    /// Returns the cached CKRecord for this name/type, or creates a fresh one.
    private func existingRecord(named name: String, type: String) -> CKRecord {
        if let cached = cachedRecords[name] { return cached }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
    }

    /// Returns the cached CKRecord, or fetches from CloudKit if not cached.
    private func fetchOrCachedRecord(named name: String, type: String) async throws -> CKRecord {
        if let cached = cachedRecords[name] { return cached }
        let recordID = CKRecord.ID(recordName: name)
        let record = try await database.record(for: recordID)
        cachedRecords[name] = record
        return record
    }

    /// Saves a record using allKeys policy (always overwrites server state).
    @discardableResult
    private func save(_ record: CKRecord) async throws -> CKRecord {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .allKeys,
            atomically: true
        )
        guard let saved = try result.saveResults[record.recordID]?.get() else {
            throw CloudKitServiceError.saveFailed(record.recordID.recordName)
        }
        return saved
    }
}

enum CloudKitServiceError: LocalizedError {
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let name): "Failed to save CloudKit record: \(name)"
        }
    }
}
