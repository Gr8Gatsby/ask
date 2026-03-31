import Foundation
import CloudKit

// MARK: - Schema constants

enum CKSchema {
    static let containerID = "iCloud.simple.ask"

    enum RecordType {
        static let machine = "Machine"
        static let event = "AskEvent"
        static let response = "AskResponse"
        static let message = "AskMessage"
        static let typing = "AskTyping"
        static let session = "AskSession"
        static let rkBlock = "RKBlock"
        static let rkResponse = "RKResponse"
        static let device = "AskDevice"
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

    enum Typing {
        static let machineID = "machineID"
        static let fromDevice = "fromDevice"
        static let timestamp = "timestamp"
    }

    enum Message {
        static let messageID = "messageID"
        static let machineID = "machineID"
        static let text = "text"
        static let fromDevice = "fromDevice"
        static let timestamp = "timestamp"
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
        return record
    }
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
