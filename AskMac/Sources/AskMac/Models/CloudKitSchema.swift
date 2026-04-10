import Foundation
import CloudKit

// MARK: - Schema constants

enum CKSchema {
    static let containerID = "iCloud.simple.ask"

    enum RecordType {
        static let machine      = "Machine"
        static let rkBlock      = "RKBlock"
        static let rkResponse   = "RKResponse"
        static let message      = "AskMessage"
        static let device       = "AskDevice"
        static let feedSchedule = "FeedSchedule"
        // Task history (A2A protocol)
        static let askTask        = "AskTask"
        static let askTaskMessage = "AskTaskMessage"
        static let askArtifact    = "AskArtifact"
        // Deprecated — dead code, no longer written or read.
        // CloudKit record types cannot be deleted from production containers;
        // these constants are kept only so purgeOldRecords can clean up stale records.
        static let event    = "AskEvent"
        static let response = "AskResponse"
        static let session  = "AskSession"
    }

    // MARK: - AskTask

    enum AskTask {
        static let taskID        = "taskID"
        static let machineID     = "machineID"
        static let scriptID      = "scriptID"
        static let scriptName    = "scriptName"
        static let scriptIcon    = "scriptIcon"
        static let scriptIconData = "scriptIconData"
        static let title         = "title"
        static let status        = "status"
        static let lastActivityAt = "lastActivityAt"
        static let messageCount  = "messageCount"
        static let artifactCount = "artifactCount"
    }

    // MARK: - AskTaskMessage

    enum AskTaskMessage {
        static let messageID      = "messageID"
        static let taskID         = "taskID"
        static let machineID      = "machineID"
        static let scriptID       = "scriptID"
        static let role           = "role"
        static let partsJSON      = "partsJSON"
        static let timestamp      = "timestamp"
        static let sequenceNumber = "sequenceNumber"
    }

    // MARK: - AskArtifact

    enum AskArtifact {
        static let artifactID   = "artifactID"
        static let taskID       = "taskID"
        static let machineID    = "machineID"
        static let scriptID     = "scriptID"
        static let filename     = "filename"
        static let mimeType     = "mimeType"
        static let description  = "description"
        static let sizeBytes    = "sizeBytes"
        static let content      = "content"
        static let updatedAt    = "updatedAt"
    }

    enum Device {
        static let deviceID = "deviceID"
        static let deviceName = "deviceName"
        static let machineID = "machineID"
        static let lastSeen = "lastSeen"
        static let enabled = "enabled"
    }

    enum RKBlock {
        static let blockID = "blockID"
        static let machineID = "machineID"
        static let scriptID = "scriptID"
        static let scriptName = "scriptName"
        static let scriptIcon = "scriptIcon"
        static let scriptIconData = "scriptIconData"
        static let scriptIconSVG = "scriptIconSVG"
        static let blockType = "blockType"
        static let payload = "payload"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
        static let scriptType = "scriptType"  // "tile" (default) or "feed"
        static let requiresResponse = "requiresResponse"  // 1 if the block needs user input, 0 otherwise
        static let showsInInbox = "showsInInbox"  // 1 if the block should appear in the in-app inbox
    }

    enum FeedSchedule {
        static let machineID = "machineID"
        static let scriptID = "scriptID"
        static let schedule = "schedule"
        static let updatedAt = "updatedAt"
    }

    enum RKResponse {
        static let blockID = "blockID"
        static let machineID = "machineID"
        static let scriptID = "scriptID"
        static let value = "value"
        static let timestamp = "timestamp"
    }

    enum Session {
        static let sessionID = "sessionID"
        static let machineID = "machineID"
        static let title = "title"
        static let status = "status"
        static let startedAt = "startedAt"
        static let lastActivityAt = "lastActivityAt"
    }


    enum Message {
        static let messageID = "messageID"
        static let machineID = "machineID"
        static let text = "text"
        static let fromDevice = "fromDevice"
        static let timestamp = "timestamp"
        static let sessionID = "sessionID"
        static let scriptID = "scriptID"
        static let readAt = "readAt"
    }

    enum Response {
        static let eventID = "eventID"
        static let machineID = "machineID"
        static let choice = "choice"
        static let timestamp = "timestamp"
    }

    enum Machine {
        static let machineID = "machineID"
        static let name = "name"
        static let platform = "platform"
        static let lastHeartbeat = "lastHeartbeat"
        static let status = "status"
    }

    enum Event {
        static let eventID = "eventID"
        static let machineID = "machineID"
        static let title = "title"
        static let body = "body"
        static let source = "source"
        static let options = "options"
        static let timestamp = "timestamp"
        static let sessionID = "sessionID"
    }
}

// MARK: - Machine

enum MachineStatus: String, Sendable {
    case idle, busy
}

struct MachineRecord: Sendable {
    let machineID: String
    var name: String
    let platform: String
    var lastHeartbeat: Date
    var status: MachineStatus

    init(machineID: String, name: String, status: MachineStatus = .idle) {
        self.machineID = machineID
        self.name = name
        self.platform = "macOS"
        self.lastHeartbeat = Date()
        self.status = status
    }

    init?(record: CKRecord) {
        guard
            let machineID = record[CKSchema.Machine.machineID] as? String,
            let name = record[CKSchema.Machine.name] as? String,
            let lastHeartbeat = record[CKSchema.Machine.lastHeartbeat] as? Date,
            let statusRaw = record[CKSchema.Machine.status] as? String,
            let status = MachineStatus(rawValue: statusRaw)
        else { return nil }

        self.machineID = machineID
        self.name = name
        self.platform = record[CKSchema.Machine.platform] as? String ?? "macOS"
        self.lastHeartbeat = lastHeartbeat
        self.status = status
    }

    func applying(to record: CKRecord) -> CKRecord {
        record[CKSchema.Machine.machineID] = machineID
        record[CKSchema.Machine.name] = name
        record[CKSchema.Machine.platform] = platform
        record[CKSchema.Machine.lastHeartbeat] = lastHeartbeat
        record[CKSchema.Machine.status] = status.rawValue
        return record
    }
}

// MARK: - RKBlock

struct RKBlockRecord: Sendable {
    let blockID: String
    let machineID: String
    let scriptID: String
    let scriptName: String
    let scriptIcon: String?
    let scriptIconData: String?  // base64-encoded PNG (32×32) of the script's icon
    let scriptIconSVG: String?   // raw SVG markup from the script's icon_file
    let blockType: String
    let payload: String     // JSON blob
    let createdAt: Date
    let expiresAt: Date?
    let scriptType: String  // "tile" (default) or "feed"
    let requiresResponse: Int  // 1 if user input needed, 0 otherwise
    let showsInInbox: Int  // 1 if the block should surface in the in-app inbox

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: CKSchema.RecordType.rkBlock,
                              recordID: CKRecord.ID(recordName: blockID))
        record[CKSchema.RKBlock.blockID] = blockID
        record[CKSchema.RKBlock.machineID] = machineID
        record[CKSchema.RKBlock.scriptID] = scriptID
        record[CKSchema.RKBlock.scriptName] = scriptName
        record[CKSchema.RKBlock.scriptIcon] = scriptIcon as CKRecordValueProtocol?
        record[CKSchema.RKBlock.scriptIconData] = scriptIconData as CKRecordValueProtocol?
        record[CKSchema.RKBlock.scriptIconSVG] = scriptIconSVG as CKRecordValueProtocol?
        record[CKSchema.RKBlock.blockType] = blockType
        record[CKSchema.RKBlock.payload] = payload
        record[CKSchema.RKBlock.createdAt] = createdAt
        record[CKSchema.RKBlock.expiresAt] = expiresAt as CKRecordValueProtocol?
        record[CKSchema.RKBlock.scriptType] = scriptType
        record[CKSchema.RKBlock.requiresResponse] = requiresResponse as CKRecordValue
        record[CKSchema.RKBlock.showsInInbox] = showsInInbox as CKRecordValue
        return record
    }
}

// MARK: - FeedSchedule

struct FeedScheduleRecord: Sendable {
    let machineID: String
    let scriptID: String
    let schedule: String   // cron expression override
    let updatedAt: Date

    var recordName: String { "feedschedule-\(machineID)-\(scriptID)" }

    init?(record: CKRecord) {
        guard
            let machineID = record[CKSchema.FeedSchedule.machineID] as? String,
            let scriptID  = record[CKSchema.FeedSchedule.scriptID]  as? String,
            let schedule  = record[CKSchema.FeedSchedule.schedule]  as? String,
            let updatedAt = record[CKSchema.FeedSchedule.updatedAt] as? Date
        else { return nil }
        self.machineID = machineID
        self.scriptID  = scriptID
        self.schedule  = schedule
        self.updatedAt = updatedAt
    }

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: CKSchema.RecordType.feedSchedule,
                              recordID: CKRecord.ID(recordName: recordName))
        record[CKSchema.FeedSchedule.machineID] = machineID
        record[CKSchema.FeedSchedule.scriptID]  = scriptID
        record[CKSchema.FeedSchedule.schedule]  = schedule
        record[CKSchema.FeedSchedule.updatedAt] = updatedAt
        return record
    }
}

// MARK: - AskTask record

struct AskTaskRecord: Sendable {
    let taskID: String
    let machineID: String
    let scriptID: String
    let scriptName: String
    let scriptIcon: String?
    let scriptIconData: String?
    let title: String
    var status: String
    var lastActivityAt: Date
    var messageCount: Int
    var artifactCount: Int

    /// Record name includes machineID+scriptID so different machines/scripts don't collide.
    var recordName: String { "\(machineID)-\(scriptID)-\(taskID)" }

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: CKSchema.RecordType.askTask,
                              recordID: CKRecord.ID(recordName: recordName))
        record[CKSchema.AskTask.taskID]         = taskID
        record[CKSchema.AskTask.machineID]       = machineID
        record[CKSchema.AskTask.scriptID]        = scriptID
        record[CKSchema.AskTask.scriptName]      = scriptName
        record[CKSchema.AskTask.scriptIcon]      = scriptIcon as CKRecordValueProtocol?
        record[CKSchema.AskTask.scriptIconData]  = scriptIconData as CKRecordValueProtocol?
        record[CKSchema.AskTask.title]           = title
        record[CKSchema.AskTask.status]          = status
        record[CKSchema.AskTask.lastActivityAt]  = lastActivityAt
        record[CKSchema.AskTask.messageCount]    = messageCount as CKRecordValue
        record[CKSchema.AskTask.artifactCount]   = artifactCount as CKRecordValue
        return record
    }
}

// MARK: - AskTaskMessage record

struct AskTaskMessageRecord: Sendable {
    let messageID: String
    let taskID: String
    let machineID: String
    let scriptID: String
    let role: String
    let partsJSON: String
    let timestamp: Date
    let sequenceNumber: Int

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: CKSchema.RecordType.askTaskMessage,
                              recordID: CKRecord.ID(recordName: messageID))
        record[CKSchema.AskTaskMessage.messageID]      = messageID
        record[CKSchema.AskTaskMessage.taskID]         = taskID
        record[CKSchema.AskTaskMessage.machineID]      = machineID
        record[CKSchema.AskTaskMessage.scriptID]       = scriptID
        record[CKSchema.AskTaskMessage.role]           = role
        record[CKSchema.AskTaskMessage.partsJSON]      = partsJSON
        record[CKSchema.AskTaskMessage.timestamp]      = timestamp
        record[CKSchema.AskTaskMessage.sequenceNumber] = sequenceNumber as CKRecordValue
        return record
    }
}

// MARK: - AskArtifact record

struct AskArtifactRecord: Sendable {
    let artifactID: String
    let taskID: String
    let machineID: String
    let scriptID: String
    let filename: String
    let mimeType: String
    let artifactDescription: String?
    let sizeBytes: Int
    let contentURL: URL   // local temp file — used to build CKAsset
    let updatedAt: Date

    var recordName: String { "\(machineID)-\(scriptID)-\(artifactID)" }
}

// MARK: - Device

struct DeviceRecord: Sendable {
    let deviceID: String
    let deviceName: String
    let machineID: String
    let lastSeen: Date
    var enabled: Bool

    var recordName: String { "device-\(deviceID)-\(machineID)" }

    init?(record: CKRecord) {
        guard
            let deviceID = record[CKSchema.Device.deviceID] as? String,
            let deviceName = record[CKSchema.Device.deviceName] as? String,
            let machineID = record[CKSchema.Device.machineID] as? String,
            let lastSeen = record[CKSchema.Device.lastSeen] as? Date
        else { return nil }
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.machineID = machineID
        self.lastSeen = lastSeen
        // Default true when field is absent (new records from iOS don't set it)
        let enabledInt = record[CKSchema.Device.enabled] as? Int64 ?? 1
        self.enabled = enabledInt != 0
    }
}
