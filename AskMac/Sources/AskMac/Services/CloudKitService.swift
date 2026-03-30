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

    /// Saves an outbound message from this Mac to the iOS app.
    /// `messageID` must be pre-generated by the caller so the optimistic local message
    /// and the CloudKit record share the same ID.
    func saveMessage(machineID: String, text: String, messageID: String) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.message,
                              recordID: CKRecord.ID(recordName: messageID))
        record[CKSchema.Message.messageID] = messageID
        record[CKSchema.Message.machineID] = machineID
        record[CKSchema.Message.text] = text
        record[CKSchema.Message.fromDevice] = "mac"
        record[CKSchema.Message.timestamp] = Date()
        _ = try await save(record)
    }

    /// Deletes all AskMessage records for this machine. Used to clear history during development.
    func deleteAllMessages(machineID: String) async throws {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Message.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.message, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        let ids = results.compactMap { _, result in try? result.get() }.map(\.recordID)
        guard !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
    }

    /// Fetches all messages for this machine (both directions), sorted oldest first.
    func fetchAllMessages(machineID: String) async throws -> [(messageID: String, text: String, fromDevice: String, timestamp: Date)] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Message.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.message, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.timestamp, ascending: true)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        return results.compactMap { _, result in
            guard let record = try? result.get(),
                  let messageID = record[CKSchema.Message.messageID] as? String,
                  let text = record[CKSchema.Message.text] as? String,
                  let fromDevice = record[CKSchema.Message.fromDevice] as? String,
                  let timestamp = record[CKSchema.Message.timestamp] as? Date
            else { return nil }
            return (messageID: messageID, text: text, fromDevice: fromDevice, timestamp: timestamp)
        }
    }

    /// Upserts a typing indicator for this device. Record name is deterministic for upsert.
    func updateTyping(machineID: String, fromDevice: String) async throws {
        let recordName = "typing-\(machineID)-\(fromDevice)"
        let record = existingRecord(named: recordName, type: CKSchema.RecordType.typing)
        record[CKSchema.Typing.machineID] = machineID
        record[CKSchema.Typing.fromDevice] = fromDevice
        record[CKSchema.Typing.timestamp] = Date()
        let saved = try await save(record)
        cachedRecords[recordName] = saved
    }

    /// Deletes a typing indicator record so the other side sees dots disappear immediately.
    func clearTyping(machineID: String, fromDevice: String) async {
        let recordName = "typing-\(machineID)-\(fromDevice)"
        cachedRecords.removeValue(forKey: recordName)
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try? await database.deleteRecord(withID: recordID)
    }

    /// Returns the timestamp of the other side's most recent typing update, or nil if none.
    func fetchTypingTimestamp(machineID: String, fromDevice: String) async -> Date? {
        let recordName = "typing-\(machineID)-\(fromDevice)"
        let recordID = CKRecord.ID(recordName: recordName)
        guard let record = try? await database.record(for: recordID),
              let timestamp = record[CKSchema.Typing.timestamp] as? Date
        else { return nil }
        return timestamp
    }

    /// Fetches messages from the iPhone (fromDevice="iphone") newer than `since`.
    func fetchNewMessages(machineID: String, since: Date) async throws -> [(messageID: String, text: String, timestamp: Date)] {
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
            return (messageID: messageID, text: text, timestamp: timestamp)
        }
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

    // MARK: - Startup cleanup

    /// Deletes all legacy event/session/response/job records for this machine from CloudKit.
    /// RKBlock records are intentionally excluded — scripts manage their own block lifecycle
    /// via TTLs and explicit clear_block calls. Purging blocks on startup races with scripts
    /// re-emitting after launch and causes a blank iOS UI.
    /// Safe to call on every launch — runs atomically=false so partial success is fine.
    func purgeOldRecords(machineID: String) async {
        let types: [(recordType: String, field: String)] = [
            (CKSchema.RecordType.event,    CKSchema.Event.machineID),
            (CKSchema.RecordType.session,  CKSchema.Session.machineID),
            (CKSchema.RecordType.response, CKSchema.Response.machineID),
            (CKSchema.RecordType.job,      CKSchema.Job.machineID),
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

    // MARK: - RKBlocks

    /// Saves (creates or replaces) an RKBlock record. The blockID is used as the record name.
    func saveBlock(_ block: RKBlockRecord) async throws {
        let record = block.toCKRecord()
        let saved = try await save(record)
        cachedRecords[block.blockID] = saved
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
