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

    // MARK: - Events

    /// Fetches pending AskEvent records for a machine, newest first.
    /// Stale notification-only events (no options, older than 1 hour) are deleted silently.
    func fetchPendingEvents(machineID: String) async throws -> [AskEvent] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Event.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.event, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        var events: [AskEvent] = []
        var toDelete: [CKRecord.ID] = []
        let notificationCutoff = Date().addingTimeInterval(-3600)  // 1 hr for notification-only
        let hookCutoff = Date().addingTimeInterval(-360)            // 6 min for permission requests (hook timeout is 5 min)

        for (recordID, result) in results {
            guard let record = try? result.get() else { continue }
            guard let event = AskEvent(record: record) else {
                toDelete.append(recordID)
                continue
            }
            if !event.requiresResponse && event.timestamp < notificationCutoff {
                toDelete.append(recordID)
            } else if event.requiresResponse && event.timestamp < hookCutoff {
                // Hook already timed out — response is impossible; clean up
                toDelete.append(recordID)
            } else {
                events.append(event)
            }
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete, savePolicy: .allKeys, atomically: false)
        }

        return events.sorted { $0.timestamp > $1.timestamp }
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

    // MARK: - Sessions

    /// Fetches all sessions for a machine, most recently active first.
    /// Waiting sessions whose hook already timed out are auto-resolved to "active".
    func fetchSessions(machineID: String) async throws -> [AskSession] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Session.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.session, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Session.lastActivityAt, ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 10)

        let hookCutoff = Date().addingTimeInterval(-360)
        // Only surface sessions active in the last 24 hours
        let displayCutoff = Date().addingTimeInterval(-86400)
        var sessions: [AskSession] = []

        var toDelete: [CKRecord.ID] = []

        for (recordID, result) in results {
            guard let record = try? result.get(),
                  let session = AskSession(record: record) else { continue }
            if session.lastActivityAt < displayCutoff || session.status == .completed {
                // Older than 24 h or completed — delete from CloudKit to prevent accumulation
                toDelete.append(recordID)
                continue
            }
            if session.status.isWaiting && session.lastActivityAt < hookCutoff {
                // Stale waiting session — correct status without touching lastActivityAt
                await fixSessionStatus(sessionID: session.id, status: "active")
                sessions.append(AskSession(correcting: session, status: .active))
            } else {
                sessions.append(session)
            }
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete)
        }

        return sessions
    }

    /// Updates session status AND bumps lastActivityAt (use after user interaction).
    func updateSessionStatus(sessionID: String, status: String) async {
        let recordID = CKRecord.ID(recordName: sessionID)
        guard let record = try? await database.record(for: recordID) else { return }
        record[CKSchema.Session.status] = status
        record[CKSchema.Session.lastActivityAt] = Date()
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// Deletes a session record from CloudKit.
    func deleteSession(_ session: AskSession) async throws {
        let recordID = CKRecord.ID(recordName: session.id)
        _ = try await database.modifyRecords(saving: [], deleting: [recordID])
    }

    /// Corrects a session's status without changing lastActivityAt (used for stale-session cleanup).
    private func fixSessionStatus(sessionID: String, status: String) async {
        let recordID = CKRecord.ID(recordName: sessionID)
        guard let record = try? await database.record(for: recordID) else { return }
        record[CKSchema.Session.status] = status
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// Fetches pending events for a specific session, cleaning up stale ones.
    func fetchEvents(sessionID: String, machineID: String) async throws -> [AskEvent] {
        let predicate = NSPredicate(format: "%K == %@ AND %K == %@",
                                    CKSchema.Event.sessionID, sessionID,
                                    CKSchema.Event.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.event, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 20)

        let hookCutoff = Date().addingTimeInterval(-360)
        var events: [AskEvent] = []
        var toDelete: [CKRecord.ID] = []

        for (recordID, result) in results {
            guard let record = try? result.get(),
                  let event = AskEvent(record: record) else {
                toDelete.append(recordID); continue
            }
            if event.requiresResponse && event.timestamp < hookCutoff {
                toDelete.append(recordID)
            } else {
                events.append(event)
            }
        }

        if !toDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: toDelete, savePolicy: .allKeys, atomically: false)
        }

        return events
    }

    // MARK: - RKBlocks

    /// Fetches all active RKBlock records for a machine, sorted by type priority then createdAt.
    func fetchBlocks(machineID: String) async throws -> [RKBlock] {
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

        let feedItems = blocks.filter { $0.blockType == .feedItem }
        if !feedItems.isEmpty {
            FeedStore.shared.upsert(feedItems)
        }

        return blocks.sorted {
            // Confirmation and prompt blocks (require response) sort before informational ones
            if $0.requiresResponse != $1.requiresResponse { return $0.requiresResponse }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Posts an RKResponse so the Mac daemon can route it back to the script.
    func postResponse(blockID: String, machineID: String, scriptID: String, value: String) async throws {
        let record = CKRecord(recordType: CKSchema.RecordType.rkResponse)
        record[CKSchema.RKResponse.blockID] = blockID
        record[CKSchema.RKResponse.machineID] = machineID
        record[CKSchema.RKResponse.scriptID] = scriptID
        record[CKSchema.RKResponse.value] = value
        record[CKSchema.RKResponse.timestamp] = Date()
        _ = try await database.save(record)
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
        let recordName = "device-\(Self.stableDeviceID)-\(machineID)"
        let recordID = CKRecord.ID(recordName: recordName)
        guard let record = try? await database.record(for: recordID) else { return true }
        guard let enabledInt = record[CKSchema.Device.enabled] as? Int64 else { return true }
        return enabledInt != 0
    }

    // MARK: - Feed schedules

    /// Upserts a schedule override for a feed script. The Mac polls these records
    /// and reschedules the script's cron task accordingly.
    func saveFeedSchedule(machineID: String, scriptID: String, schedule: String) async throws {
        let recordName = "feedschedule-\(machineID)-\(scriptID)"
        let recordID = CKRecord.ID(recordName: recordName)
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CKSchema.RecordType.feedSchedule, recordID: recordID)
            record[CKSchema.FeedSchedule.machineID] = machineID
            record[CKSchema.FeedSchedule.scriptID]  = scriptID
        }
        record[CKSchema.FeedSchedule.schedule]  = schedule
        record[CKSchema.FeedSchedule.updatedAt] = Date()
        _ = try await database.save(record)
    }

    /// Returns the current schedule override per script for a given machine.
    func fetchFeedSchedules(machineID: String) async throws -> [(scriptID: String, schedule: String)] {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.FeedSchedule.machineID, machineID)
        let query = CKQuery(recordType: CKSchema.RecordType.feedSchedule, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 100)
        return results.compactMap { _, result in
            guard let record = try? result.get(),
                  let scriptID = record[CKSchema.FeedSchedule.scriptID] as? String,
                  let schedule = record[CKSchema.FeedSchedule.schedule] as? String
            else { return nil }
            return (scriptID: scriptID, schedule: schedule)
        }
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
