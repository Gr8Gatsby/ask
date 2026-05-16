import Foundation
import CloudKit
import Observation
import OSLog

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "CloudKit")

@Observable
final class CloudKitService {
    private let container: CKContainer
    private let database: CKDatabase

    // Cached CKRecord objects keyed by recordName — used to update in place without refetching
    private var cachedRecords: [String: CKRecord] = [:]

    private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    /// Last 6 chars of the CloudKit user record ID — same value on every device on the same Apple ID.
    private(set) var userRecordFingerprint: String?

    init() {
        self.container = CKContainer(identifier: CKSchema.containerID)
        self.database = container.privateCloudDatabase
        logger.info("CloudKitService init — container: \(CKSchema.containerID)")
    }

    // MARK: - Account

    func checkAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
            logger.info("iCloud account status: \(self.accountStatus.rawValue)")
            if accountStatus == .available { await fetchUserFingerprint() }
        } catch {
            accountStatus = .couldNotDetermine
            logger.error("iCloud account status check failed: \(error)")
        }
    }

    private func fetchUserFingerprint() async {
        guard let recordID = try? await container.userRecordID() else { return }
        userRecordFingerprint = "…" + String(recordID.recordName.suffix(6))
        logger.info("CloudKit user record fingerprint: \(self.userRecordFingerprint ?? "nil")")
    }

    // MARK: - Machine

    /// Creates or updates the Machine record for this installation.
    func saveMachine(_ machine: MachineRecord) async throws {
        logger.info("saveMachine — machineID: \(machine.machineID) name: \(machine.name)")
        let record = existingRecord(named: machine.machineID, type: CKSchema.RecordType.machine)
        let updated = machine.applying(to: record)
        let saved = try await save(updated)
        cachedRecords[machine.machineID] = saved
        logger.info("saveMachine — saved OK, recordName: \(saved.recordID.recordName) zone: \(saved.recordID.zoneID.zoneName)")
    }

    // MARK: - Messages

    /// Fetches messages from the iPhone (fromDevice="iphone") newer than `since`, excluding already-read ones.
    func fetchNewMessages(machineID: String, since: Date) async throws -> [(messageID: String, text: String, timestamp: Date, sessionID: String?, scriptID: String?)] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K > %@",
            CKSchema.Message.machineID, machineID,
            CKSchema.Message.fromDevice, "iphone",
            CKSchema.Message.timestamp, since as NSDate
        )
        let query = CKQuery(recordType: CKSchema.RecordType.message, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.timestamp, ascending: true)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get(),
                  let messageID = record[CKSchema.Message.messageID] as? String,
                  let text = record[CKSchema.Message.text] as? String,
                  let timestamp = record[CKSchema.Message.timestamp] as? Date
            else { return nil }
            // Skip messages already marked as read by a previous daemon run
            if record[CKSchema.Message.readAt] as? Date != nil { return nil }
            let sessionID = record[CKSchema.Message.sessionID] as? String
            let scriptID = record[CKSchema.Message.scriptID] as? String
            return (messageID: messageID, text: text, timestamp: timestamp, sessionID: sessionID, scriptID: scriptID)
        }
    }

    /// Writes `readAt` to an AskMessage record so the iOS app can confirm delivery.
    func markMessageRead(messageID: String) async {
        let recordID = CKRecord.ID(recordName: messageID)
        guard let record = try? await database.record(for: recordID) else { return }
        record[CKSchema.Message.readAt] = Date()
        _ = try? await database.save(record)
    }

    // MARK: - Devices

    /// Fetches all Device records for this machine.
    func fetchDevices(machineID: String) async throws -> [DeviceRecord] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Device.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.device, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return DeviceRecord(record: record)
        }
    }

    /// Sets the enabled flag on a Device record. Does nothing if the record doesn't exist yet.
    func setDeviceEnabled(recordName: String, enabled: Bool) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        guard let record = try? await database.record(for: recordID) else { return }
        record[CKSchema.Device.enabled] = Int64(enabled ? 1 : 0)
        _ = try await database.save(record)
    }

    // MARK: - RKBlocks

    /// Saves (creates or replaces) an RKBlock record. The blockID is used as the record name.
    func saveBlock(_ block: RKBlockRecord) async throws {
        let record = block.toCKRecord()
        let saved = try await save(record)
        cachedRecords[block.blockID] = saved
    }

    /// Fetches all non-expired RKBlock records for a machine. Used to seed activeBlocks on startup.
    func fetchActiveBlocks(machineID: String) async -> [CKRecord] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKBlock.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkBlock, predicate: predicate)
        guard let (results, _) = try? await database.records(matching: query, resultsLimit: 500) else { return [] }
        let now = Date()
        return results.compactMap { _, result -> CKRecord? in
            guard let record = try? result.get() else { return nil }
            if let expiresAt = record[CKSchema.RKBlock.expiresAt] as? Date, expiresAt < now { return nil }
            return record
        }
    }

    /// Deletes all expired RKBlock records for a machine. Called by HeartbeatService on each cycle.
    func deleteExpiredBlocks(machineID: String) async {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKBlock.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkBlock, predicate: predicate)
        guard let (results, _) = try? await database.records(matching: query, resultsLimit: 200) else { return }
        let now = Date()
        let expiredIDs = results.compactMap { recordID, result -> CKRecord.ID? in
            guard let record = try? result.get(),
                  let expiresAt = record[CKSchema.RKBlock.expiresAt] as? Date,
                  expiresAt < now
            else { return nil }
            return recordID
        }
        guard !expiredIDs.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: expiredIDs, savePolicy: .allKeys, atomically: false)
        expiredIDs.forEach { cachedRecords.removeValue(forKey: $0.recordName) }
        logger.info("deleteExpiredBlocks — removed \(expiredIDs.count) expired blocks for \(machineID)")
    }

    /// Deletes all RKBlock records for a given script. Called on script reconnect for a clean slate.
    func clearBlocksForScript(scriptID: String, machineID: String) async throws {
        // Query by machineID only — it's guaranteed queryable (iOS fetch uses it).
        // Filter scriptID in memory to avoid compound-predicate failures if scriptID
        // isn't indexed in the CloudKit schema.
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKBlock.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkBlock, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        let ids = results.compactMap { _, result -> CKRecord.ID? in
            guard let record = try? result.get(),
                  record[CKSchema.RKBlock.scriptID] as? String == scriptID
            else { return nil }
            return record.recordID
        }
        guard !ids.isEmpty else { return }
        _ = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
        ids.forEach { cachedRecords.removeValue(forKey: $0.recordName) }
        logger.debug("Cleared \(ids.count) blocks for script \(scriptID)")
    }

    /// Deletes an RKBlock record by blockID.
    func clearBlock(blockID: String) async throws {
        let recordID = CKRecord.ID(recordName: blockID)
        try await database.deleteRecord(withID: recordID)
        cachedRecords.removeValue(forKey: blockID)
    }

    /// Fetches and deletes all RKResponse records addressed to this machine.
    func drainRKResponses(machineID: String) async throws -> [(blockID: String, scriptID: String, value: String)] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.RKResponse.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.rkResponse, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        var found: [(blockID: String, scriptID: String, value: String)] = []
        var toDelete: [CKRecord.ID] = []

        for (recordID, result) in results {
            guard let record = try? result.get(),
                  let blockID = record[CKSchema.RKResponse.blockID] as? String,
                  let scriptID = record[CKSchema.RKResponse.scriptID] as? String,
                  let value = record[CKSchema.RKResponse.value] as? String
            else { continue }
            found.append((blockID: blockID, scriptID: scriptID, value: value))
            toDelete.append(recordID)
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete, savePolicy: .allKeys, atomically: false)
        }
        return found
    }

    /// Upserts an AskScript record representing the current state of one script on this machine.
    func upsertScript(_ script: AskScriptRecord) async throws {
        let record = existingRecord(named: script.recordName, type: CKSchema.RecordType.askScript)
        record[CKSchema.AskScript.machineID]  = script.machineID
        record[CKSchema.AskScript.scriptID]   = script.scriptID
        record[CKSchema.AskScript.scriptName] = script.scriptName
        record[CKSchema.AskScript.scriptType] = script.scriptType
        record[CKSchema.AskScript.scriptIcon] = script.scriptIcon as CKRecordValueProtocol?
        record[CKSchema.AskScript.version]    = script.version as CKRecordValueProtocol?
        record[CKSchema.AskScript.status]     = script.status
        record[CKSchema.AskScript.lastRunAt]  = script.lastRunAt as CKRecordValueProtocol?
        record[CKSchema.AskScript.nextRunAt]  = script.nextRunAt as CKRecordValueProtocol?
        record[CKSchema.AskScript.updatedAt]  = script.updatedAt
        let saved = try await database.save(record)
        cachedRecords[script.recordName] = saved
    }

    /// Deletes the AskScript record for a script that has been uninstalled or permanently disabled.
    func deleteScript(machineID: String, scriptID: String) async {
        let recordName = "script-\(machineID)-\(scriptID)"
        cachedRecords.removeValue(forKey: recordName)
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
    }

    /// Fetches and deletes all AskInvokeRequest records addressed to this machine.
    /// Returns the list of scriptIDs to invoke.
    func drainInvokeRequests(machineID: String) async throws -> [String] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.AskInvokeRequest.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.askInvokeRequest, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        var scriptIDs: [String] = []
        var toDelete: [CKRecord.ID] = []

        for (recordID, result) in results {
            guard let record = try? result.get(),
                  let scriptID = record[CKSchema.AskInvokeRequest.scriptID] as? String
            else { continue }
            scriptIDs.append(scriptID)
            toDelete.append(recordID)
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete, savePolicy: .allKeys, atomically: false)
        }
        return scriptIDs
    }

    /// Fetches all Machine records (one per machine signed in to the same iCloud account).
    func fetchAllMachines() async throws -> [MachineRecord] {
        // Predicate `TRUEPREDICATE` returns all records of the type.
        let query = CKQuery(recordType: CKSchema.RecordType.machine, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Machine.lastHeartbeat, ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return MachineRecord(record: record)
        }
    }

    // MARK: - Task history (A2A protocol)

    /// Fetches all AskTask records for this machine, sorted newest-first.
    func fetchTasks(machineID: String) async throws -> [AskTaskRecord] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.AskTask.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.askTask, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskTask.lastActivityAt, ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 100)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return AskTaskRecord(from: record)
        }
    }

    /// Creates or updates an AskTask record. Uses the task's recordName as the CloudKit record ID
    /// so re-opening the same task is an upsert, not a duplicate insert.
    func saveTask(_ task: AskTaskRecord) async throws {
        let record = existingRecord(named: task.recordName, type: CKSchema.RecordType.askTask)
        // Apply all fields from the struct
        record[CKSchema.AskTask.taskID]        = task.taskID
        record[CKSchema.AskTask.machineID]     = task.machineID
        record[CKSchema.AskTask.scriptID]      = task.scriptID
        record[CKSchema.AskTask.scriptName]    = task.scriptName
        record[CKSchema.AskTask.scriptIcon]    = task.scriptIcon as CKRecordValueProtocol?
        record[CKSchema.AskTask.scriptIconData] = task.scriptIconData as CKRecordValueProtocol?
        record[CKSchema.AskTask.title]         = task.title
        record[CKSchema.AskTask.status]        = task.status
        record[CKSchema.AskTask.lastActivityAt] = task.lastActivityAt
        record[CKSchema.AskTask.messageCount]  = task.messageCount as CKRecordValue
        record[CKSchema.AskTask.artifactCount] = task.artifactCount as CKRecordValue
        let saved = try await save(record)
        cachedRecords[task.recordName] = saved
        logger.info("saveTask — \(task.recordName) status: \(task.status)")
    }

    /// Creates a new AskTaskMessage record. Message IDs are UUIDs; always a fresh insert.
    func saveTaskMessage(_ message: AskTaskMessageRecord) async throws {
        let record = message.toCKRecord()
        let saved = try await save(record)
        cachedRecords[message.messageID] = saved
        logger.info("saveTaskMessage — taskID: \(message.taskID) seq: \(message.sequenceNumber)")
    }

    /// Fetches all messages for a task, sorted by sequence number.
    func fetchTaskMessages(taskID: String, machineID: String) async throws -> [TaskMessageDisplay] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.AskTaskMessage.taskID, taskID,
            CKSchema.AskTaskMessage.machineID, machineID
        )
        let query = CKQuery(recordType: CKSchema.RecordType.askTaskMessage, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskTaskMessage.sequenceNumber, ascending: true)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return TaskMessageDisplay(from: record)
        }
    }

    /// Fetches messages for a task as JSON-serializable dicts.
    /// `partsJSON` is stored as a raw string, matching the web client's TaskMessage interface.
    func fetchTaskMessagesAsJSON(taskID: String, machineID: String) async -> [[String: Any]] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.AskTaskMessage.taskID, taskID,
            CKSchema.AskTaskMessage.machineID, machineID
        )
        let query = CKQuery(recordType: CKSchema.RecordType.askTaskMessage, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskTaskMessage.sequenceNumber, ascending: true)]
        guard let (results, _) = try? await database.records(matching: query, resultsLimit: 200) else { return [] }
        let fmt = ISO8601DateFormatter()
        return results.compactMap { _, result in
            guard let record    = try? result.get(),
                  let messageID = record[CKSchema.AskTaskMessage.messageID] as? String,
                  let taskID    = record[CKSchema.AskTaskMessage.taskID]    as? String,
                  let role      = record[CKSchema.AskTaskMessage.role]      as? String,
                  let partsJSON = record[CKSchema.AskTaskMessage.partsJSON] as? String,
                  let timestamp = record[CKSchema.AskTaskMessage.timestamp] as? Date
            else { return nil }
            return [
                "messageID":      messageID,
                "taskID":         taskID,
                "role":           role,
                "partsJSON":      partsJSON,
                "timestamp":      fmt.string(from: timestamp),
                "sequenceNumber": record[CKSchema.AskTaskMessage.sequenceNumber] as? Int ?? 0,
            ] as [String: Any]
        }
    }

    /// Fetches artifacts for a task as JSON-serializable dicts plus a URL map for content serving.
    func fetchTaskArtifactsAsJSON(taskID: String, machineID: String) async -> (dicts: [[String: Any]], fileURLs: [String: URL]) {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.AskArtifact.taskID, taskID,
            CKSchema.AskArtifact.machineID, machineID
        )
        let query = CKQuery(recordType: CKSchema.RecordType.askArtifact, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskArtifact.updatedAt, ascending: true)]
        guard let (results, _) = try? await database.records(matching: query, resultsLimit: 50) else { return ([], [:]) }
        let fmt = ISO8601DateFormatter()
        var dicts: [[String: Any]] = []
        var fileURLs: [String: URL] = [:]
        for (_, result) in results {
            guard let record     = try? result.get(),
                  let artifactID = record[CKSchema.AskArtifact.artifactID] as? String,
                  let filename   = record[CKSchema.AskArtifact.filename]   as? String,
                  let mimeType   = record[CKSchema.AskArtifact.mimeType]   as? String,
                  let updatedAt  = record[CKSchema.AskArtifact.updatedAt]  as? Date
            else { continue }
            var dict: [String: Any] = [
                "artifactID": artifactID,
                "taskID":     taskID,
                "machineID":  machineID,
                "filename":   filename,
                "mimeType":   mimeType,
                "sizeBytes":  record[CKSchema.AskArtifact.sizeBytes] as? Int ?? 0,
                "updatedAt":  fmt.string(from: updatedAt),
            ]
            if let desc = record[CKSchema.AskArtifact.description] as? String {
                dict["description"] = desc
            }
            dicts.append(dict)
            if let asset = record[CKSchema.AskArtifact.content] as? CKAsset,
               let url = asset.fileURL {
                fileURLs[artifactID] = url
            }
        }
        return (dicts, fileURLs)
    }

    /// Fetches all artifacts for a task.
    func fetchTaskArtifacts(taskID: String, machineID: String) async throws -> [TaskArtifactDisplay] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.AskArtifact.taskID, taskID,
            CKSchema.AskArtifact.machineID, machineID
        )
        let query = CKQuery(recordType: CKSchema.RecordType.askArtifact, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.AskArtifact.updatedAt, ascending: true)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return TaskArtifactDisplay(from: record)
        }
    }

    /// Creates or updates an AskArtifact record, attaching the local file as a CKAsset.
    func saveArtifact(_ artifact: AskArtifactRecord) async throws {
        let record = existingRecord(named: artifact.recordName, type: CKSchema.RecordType.askArtifact)
        record[CKSchema.AskArtifact.artifactID]  = artifact.artifactID
        record[CKSchema.AskArtifact.taskID]      = artifact.taskID
        record[CKSchema.AskArtifact.machineID]   = artifact.machineID
        record[CKSchema.AskArtifact.scriptID]    = artifact.scriptID
        record[CKSchema.AskArtifact.filename]    = artifact.filename
        record[CKSchema.AskArtifact.mimeType]    = artifact.mimeType
        record[CKSchema.AskArtifact.description] = artifact.artifactDescription as CKRecordValueProtocol?
        record[CKSchema.AskArtifact.sizeBytes]   = artifact.sizeBytes as CKRecordValue
        record[CKSchema.AskArtifact.content]     = CKAsset(fileURL: artifact.contentURL)
        record[CKSchema.AskArtifact.updatedAt]   = artifact.updatedAt
        let saved = try await save(record)
        cachedRecords[artifact.recordName] = saved
        logger.info("saveArtifact — \(artifact.recordName) filename: \(artifact.filename) size: \(artifact.sizeBytes)")
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
        logger.debug("Saving \(record.recordType)/\(record.recordID.recordName)")
        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            guard let saved = try result.saveResults[record.recordID]?.get() else {
                let err = CloudKitServiceError.saveFailed(record.recordID.recordName)
                logger.error("Save returned no result for \(record.recordType)/\(record.recordID.recordName)")
                throw err
            }
            logger.debug("Save OK — \(record.recordType)/\(saved.recordID.recordName)")
            return saved
        } catch {
            logger.error("CloudKit save failed [\(record.recordType)/\(record.recordID.recordName)]: \(error)")
            throw error
        }
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
