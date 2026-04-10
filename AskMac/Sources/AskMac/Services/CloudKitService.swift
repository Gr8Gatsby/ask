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
        } catch {
            accountStatus = .couldNotDetermine
            logger.error("iCloud account status check failed: \(error)")
        }
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

    // MARK: - Events

    func saveEvent(eventID: String, machineID: String, title: String, body: String, source: String, options: [String] = [], sessionID: String? = nil) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.event)
        record[CKSchema.Event.eventID] = eventID
        record[CKSchema.Event.machineID] = machineID
        record[CKSchema.Event.title] = title
        record[CKSchema.Event.body] = body
        record[CKSchema.Event.source] = source
        record[CKSchema.Event.options] = options as NSArray
        record[CKSchema.Event.timestamp] = Date()
        if let sessionID = sessionID, !sessionID.isEmpty {
            record[CKSchema.Event.sessionID] = sessionID
        }
        let saved = try await save(record)
        // Notification-only events (no options) are just for push — delete after saving
        // so they don't accumulate in the iOS app's list.
        if options.isEmpty {
            _ = try? await database.deleteRecord(withID: saved.recordID)
        }
    }

    /// Creates or updates a session record. Preserves startedAt if the record already exists.
    func upsertSession(sessionID: String, machineID: String, title: String?, status: String) async throws {
        let record: CKRecord
        if let cached = cachedRecords[sessionID] {
            record = cached
        } else if let existing = try? await database.record(for: CKRecord.ID(recordName: sessionID)) {
            record = existing
            cachedRecords[sessionID] = existing
        } else {
            record = CKRecord(recordType: CKSchema.RecordType.session,
                              recordID: CKRecord.ID(recordName: sessionID))
            record[CKSchema.Session.startedAt] = Date()
        }
        record[CKSchema.Session.sessionID] = sessionID
        record[CKSchema.Session.machineID] = machineID
        if let title { record[CKSchema.Session.title] = title }
        record[CKSchema.Session.status] = status
        record[CKSchema.Session.lastActivityAt] = Date()
        let saved = try await save(record)
        cachedRecords[sessionID] = saved
    }

    // MARK: - Responses

    /// Fetches any AskResponse records addressed to this machine, then deletes them.
    func drainResponses(machineID: String) async throws -> [(eventID: String, choice: String)] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Response.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.response, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        var found: [(eventID: String, choice: String)] = []
        var toDelete: [CKRecord.ID] = []

        for (recordID, result) in results {
            guard let record = try? result.get(),
                  let eventID = record[CKSchema.Response.eventID] as? String,
                  let choice = record[CKSchema.Response.choice] as? String
            else { continue }
            found.append((eventID: eventID, choice: choice))
            toDelete.append(recordID)
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete, savePolicy: .allKeys, atomically: false)
        }
        return found
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

    // MARK: - Startup cleanup

    /// Deletes all legacy event/session/response/job records for this machine from CloudKit.
    /// RKBlock records are intentionally excluded — scripts manage their own block lifecycle
    /// via TTLs and explicit clear_block calls. Purging blocks on startup races with scripts
    /// re-emitting after launch and causes a blank iOS UI.
    /// Safe to call on every launch — runs atomically=false so partial success is fine.
    func purgeOldRecords(machineID: String) async {
        // Jobs are intentionally excluded — they persist for iOS history.
        let types: [(recordType: String, field: String)] = [
            (CKSchema.RecordType.event,    CKSchema.Event.machineID),
            (CKSchema.RecordType.session,  CKSchema.Session.machineID),
            (CKSchema.RecordType.response, CKSchema.Response.machineID),
        ]
        let predicate = NSPredicate(format: "%K == %@", "machineID", machineID)

        for (recordType, _) in types {
            let query = CKQuery(recordType: recordType, predicate: predicate)
            guard let results = try? await database.records(matching: query, resultsLimit: 200) else { continue }
            let ids = results.matchResults.compactMap { _, result in try? result.get() }.map(\.recordID)
            guard !ids.isEmpty else { continue }
            _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            print("[CloudKitService] Purged \(ids.count) \(recordType) records")
        }
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

    /// Deletes a Device record by its record name.
    func deleteDevice(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        try await database.deleteRecord(withID: recordID)
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
        print("[CloudKitService] Cleared \(ids.count) blocks for script \(scriptID)")
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

    // MARK: - Task history (A2A protocol)

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
