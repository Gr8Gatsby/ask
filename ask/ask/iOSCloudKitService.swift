import Foundation
import CloudKit
import Observation

@Observable
final class iOSCloudKitService {
    private let container: CKContainer
    private let database: CKDatabase

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

    // MARK: - Machines

    func fetchMachines() async throws -> [AskMachine] {
        let query = CKQuery(
            recordType: CKSchema.RecordType.machine,
            predicate: NSPredicate(value: true)
        )
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskMachine(record: record)
        }.sorted { $0.name < $1.name }
    }

    func fetchMachine(machineID: String) async throws -> AskMachine? {
        let recordID = CKRecord.ID(recordName: machineID)
        let record = try await database.record(for: recordID)
        return AskMachine(record: record)
    }

    // MARK: - Agents

    func fetchAgents(machineID: String) async throws -> [AskAgent] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Agent.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.agent, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskAgent(record: record)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Jobs

    /// Creates a new job record in CloudKit.
    @discardableResult
    func createJob(machineID: String, agentID: String, prompt: String) async throws -> AskJob {
        let jobID = UUID().uuidString
        let record = CKRecord(
            recordType: CKSchema.RecordType.job,
            recordID: CKRecord.ID(recordName: jobID)
        )
        record[CKSchema.Job.jobID] = jobID
        record[CKSchema.Job.machineID] = machineID
        record[CKSchema.Job.agentID] = agentID
        record[CKSchema.Job.prompt] = prompt
        record[CKSchema.Job.status] = JobStatus.queued.rawValue
        record[CKSchema.Job.createdAt] = Date()

        let saved = try await database.save(record)
        guard let job = AskJob(record: saved) else {
            throw iOSCloudKitError.invalidRecord
        }
        return job
    }

    /// Fetches the current state of a job.
    func fetchJob(jobID: String) async throws -> AskJob? {
        let recordID = CKRecord.ID(recordName: jobID)
        let record = try await database.record(for: recordID)
        return AskJob(record: record)
    }

    /// Fetches recent jobs for a machine (newest first).
    func fetchRecentJobs(machineID: String, limit: Int = 20) async throws -> [AskJob] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Job.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.job, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskJob(record: record)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Cancels a job by updating its status in CloudKit.
    func cancelJob(jobID: String) async throws {
        let recordID = CKRecord.ID(recordName: jobID)
        let record = try await database.record(for: recordID)
        record[CKSchema.Job.status] = JobStatus.cancelled.rawValue
        record[CKSchema.Job.completedAt] = Date()
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    // MARK: - Events

    /// Fetches pending AskEvent records for a machine, newest first.
    func fetchPendingEvents(machineID: String) async throws -> [AskEvent] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Event.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.event, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 20)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskEvent(record: record)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Writes an AskResponse to CloudKit so the Mac can pick it up.
    func saveResponse(eventID: String, machineID: String, choice: String) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.response)
        record[CKSchema.Response.eventID] = eventID
        record[CKSchema.Response.machineID] = machineID
        record[CKSchema.Response.choice] = choice
        record[CKSchema.Response.timestamp] = Date()
        _ = try await database.save(record)
    }

    /// Deletes an AskEvent record from CloudKit.
    func deleteEvent(_ event: AskEvent) async throws {
        try await database.deleteRecord(withID: event.ckRecordID)
    }

    // MARK: - Output

    /// Fetches all output chunks for a job, sorted by sequence.
    func fetchOutputChunks(jobID: String) async throws -> [AskOutputChunk] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.OutputChunk.jobID, jobID)
        let query = CKQuery(recordType: CKSchema.RecordType.outputChunk, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 1000)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskOutputChunk(record: record)
        }.sorted { $0.sequence < $1.sequence }
    }
}

enum iOSCloudKitError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "CloudKit returned an unexpected record format." }
}
