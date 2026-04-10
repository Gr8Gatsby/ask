import Foundation
import CloudKit
import Observation
import UIKit

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
        if UITestingSupport.isUITesting { accountStatus = .available; return }
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
        }
    }

    // MARK: - Machines

    func fetchMachines() async throws -> [AskMachine] {
        if UITestingSupport.isUITesting { return UITestingSupport.machines }
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

    /// Deletes a machine record and all of its RKBlocks from CloudKit.
    /// The Mac will re-register itself within ~30 s if it is still running.
    func deleteMachine(machineID: String) async {
        // Delete machine record (best-effort)
        let machineRecordID = CKRecord.ID(recordName: machineID)
        _ = try? await database.deleteRecord(withID: machineRecordID)

        // Batch-delete all RKBlocks owned by this machine
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKBlock.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkBlock, predicate: predicate)
        if let (results, _) = try? await database.records(matching: query, resultsLimit: 200) {
            let ids = results.compactMap { _, r in try? r.get().recordID }
            if !ids.isEmpty {
                _ = try? await database.modifyRecords(
                    saving: [], deleting: ids, savePolicy: .allKeys, atomically: false
                )
            }
        }
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

    /// Fetches all output chunks for a job, sorted by sequence number.
    func fetchOutputChunks(jobID: String) async throws -> [AskOutputChunk] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.OutputChunk.jobID, jobID)
        let query = CKQuery(recordType: CKSchema.RecordType.outputChunk, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 500)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskOutputChunk(record: record)
        }.sorted { $0.sequence < $1.sequence }
    }

    // MARK: - Messages

    /// Sends a message from the iPhone to the Mac.
    /// `messageID` must be pre-generated by the caller so the optimistic local message
    /// and the CloudKit record share the same ID.
    func sendMessage(
        machineID: String,
        text: String,
        messageID: String,
        sessionID: String? = nil,
        scriptID: String? = nil
    ) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.message,
                              recordID: CKRecord.ID(recordName: messageID))
        record[CKSchema.Message.messageID] = messageID
        record[CKSchema.Message.machineID] = machineID
        record[CKSchema.Message.text] = text
        record[CKSchema.Message.fromDevice] = "iphone"
        record[CKSchema.Message.timestamp] = Date()
        if let sessionID { record[CKSchema.Message.sessionID] = sessionID }
        if let scriptID { record[CKSchema.Message.scriptID] = scriptID }
        _ = try await database.save(record)
    }

    /// Polls a specific AskMessage record for the `readAt` field written by the Mac when it delivers the message.
    func fetchMessageReadAt(messageID: String) async -> Date? {
        guard let record = try? await database.record(for: CKRecord.ID(recordName: messageID)) else { return nil }
        return record[CKSchema.Message.readAt] as? Date
    }

    /// Deletes an AskMessage record after delivery confirmation is observed.
    func deleteMessage(messageID: String) async {
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: messageID))
    }

    // MARK: - RKBlocks

    /// Fetches all active RKBlock records for a machine, sorted by type priority then createdAt.
    func fetchBlocks(machineID: String) async throws -> [RKBlock] {
        if UITestingSupport.isUITesting {
            return UITestingSupport.blocks(for: UITestingSupport.scenario ?? "empty")
                .filter { $0.machineID == machineID || machineID.isEmpty }
        }
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKBlock.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkBlock, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.RKBlock.createdAt, ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        let now = Date()
        var blocks: [RKBlock] = []

        for (_, result) in results {
            guard let record = try? result.get() else { continue }
            guard let block = RKBlock(record: record) else { continue }
            // Skip expired blocks — Mac's HeartbeatService owns cleanup
            if let exp = block.expiresAt, exp < now { continue }
            blocks.append(block)
        }

        return blocks.sorted {
            // Confirmation and prompt blocks (require response) sort before informational ones
            if $0.requiresResponse != $1.requiresResponse { return $0.requiresResponse }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Posts an RKResponse so the Mac daemon can route it back to the script.
    func postResponse(blockID: String, machineID: String, scriptID: String, value: String) async throws {
        if UITestingSupport.isUITesting { UITestingSupport.markResponded(blockID); return }
        let record = CKRecord(recordType: CKSchema.RecordType.rkResponse)
        record[CKSchema.RKResponse.blockID] = blockID
        record[CKSchema.RKResponse.machineID] = machineID
        record[CKSchema.RKResponse.scriptID] = scriptID
        record[CKSchema.RKResponse.value] = value
        record[CKSchema.RKResponse.timestamp] = Date()
        _ = try await database.save(record)
    }

    // MARK: - Task history (A2A protocol)

    /// Fetches all AskTask records for a machine, most recently active first.
    func fetchTasks(machineID: String) async throws -> [TaskRecord] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.AskTask.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.askTask, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskTask.lastActivityAt, ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 100)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return TaskRecord(ckRecord: record)
        }
    }

    /// Fetches all AskTaskMessage records for a task, sorted by sequence number.
    func fetchMessages(taskID: String, machineID: String) async throws -> [TaskMessage] {
        // Query by machineID (guaranteed queryable) and filter taskID in memory
        // to avoid compound-predicate failures if taskID isn't indexed.
        let predicate = NSPredicate(format: "%K == %@", CKSchema.AskTaskMessage.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.askTaskMessage, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 500)
        return results.compactMap { _, result in
            guard let record = try? result.get(),
                  record[CKSchema.AskTaskMessage.taskID] as? String == taskID
            else { return nil }
            return TaskMessage(ckRecord: record)
        }.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    /// Fetches all AskArtifact metadata records for a task (no content download).
    func fetchArtifacts(taskID: String, machineID: String) async throws -> [ArtifactRecord] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.AskArtifact.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.askArtifact, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        return results.compactMap { _, result in
            guard let record = try? result.get(),
                  record[CKSchema.AskArtifact.taskID] as? String == taskID
            else { return nil }
            return ArtifactRecord(ckRecord: record)
        }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Downloads a single artifact's CKAsset content and writes it to the local cache directory.
    /// Returns the local URL on success.
    func downloadArtifactContent(recordName: String, destinationURL: URL) async throws -> URL {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await database.record(for: recordID)
        guard let asset = record[CKSchema.AskArtifact.content] as? CKAsset,
              let assetURL = asset.fileURL
        else { throw iOSCloudKitError.invalidRecord }

        let dir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: assetURL, to: destinationURL)
        return destinationURL
    }

    // MARK: - Device heartbeat

    /// Writes or updates a device presence record for each machine so the Mac companion
    /// can display which iPhones have recently connected.
    func saveDeviceHeartbeat(machineIDs: [String]) async {
        guard !machineIDs.isEmpty else { return }
        let deviceID = Self.stableDeviceID
        let deviceName = UIDevice.current.name
        for machineID in machineIDs {
            let recordName = "device-\(deviceID)-\(machineID)"
            let recordID = CKRecord.ID(recordName: recordName)
            let record: CKRecord
            if let existing = try? await database.record(for: recordID) {
                record = existing
            } else {
                record = CKRecord(recordType: CKSchema.RecordType.device, recordID: recordID)
                record[CKSchema.Device.deviceID] = deviceID
                record[CKSchema.Device.machineID] = machineID
            }
            record[CKSchema.Device.deviceName] = deviceName
            record[CKSchema.Device.lastSeen] = Date()
            _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    /// Returns false if the Mac has disabled this device. Defaults to true (enabled) if record is absent.
    func checkDeviceEnabled(machineID: String) async -> Bool {
        if UITestingSupport.isUITesting { return true }
        let recordName = "device-\(Self.stableDeviceID)-\(machineID)"
        let recordID = CKRecord.ID(recordName: recordName)
        guard let record = try? await database.record(for: recordID) else { return true }
        guard let enabledInt = record[CKSchema.Device.enabled] as? Int64 else { return true }
        return enabledInt != 0
    }

    // MARK: - Feed script invoke

    /// Writes an AskInvokeRequest record so AskMac triggers the given feed script immediately.
    func writeInvokeRequest(machineID: String, scriptID: String) async throws {
        let recordName = "invoke-\(machineID)-\(scriptID)-\(UUID().uuidString)"
        let record = CKRecord(recordType: CKSchema.RecordType.askInvokeRequest,
                              recordID: CKRecord.ID(recordName: recordName))
        record[CKSchema.AskInvokeRequest.machineID]   = machineID
        record[CKSchema.AskInvokeRequest.scriptID]    = scriptID
        record[CKSchema.AskInvokeRequest.requestedAt] = Date()
        _ = try await database.save(record)
    }

    /// Fetches all AskScript records for the given machines from CloudKit.
    func fetchScripts(machines: [AskMachine]) async -> [AskScript] {
        var result: [AskScript] = []
        for machine in machines {
            let predicate = NSPredicate(format: "%K == %@", CKSchema.AskScript.machineID, machine.id)
            let query = CKQuery(recordType: CKSchema.RecordType.askScript, predicate: predicate)
            guard let (records, _) = try? await database.records(matching: query, resultsLimit: 100)
            else { continue }
            for (_, r) in records {
                guard let record = try? r.get(),
                      let script = AskScript(record: record, machineName: machine.name)
                else { continue }
                result.append(script)
            }
        }
        return result.sorted { $0.scriptName < $1.scriptName }
    }

    private static var stableDeviceID: String {
        let key = "askDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

}

enum iOSCloudKitError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "CloudKit returned an unexpected record format." }
}
