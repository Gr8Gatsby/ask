import Foundation
import CloudKit

// MARK: - Schema constants

enum CKSchema {
    static let containerID = "iCloud.simple.ask"

    enum RecordType {
        static let machine = "Machine"
        static let agent = "Agent"
        static let job = "Job"
        static let outputChunk = "OutputChunk"
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
        static let activeJobID = "activeJobID"
    }

    enum Agent {
        static let agentID = "agentID"
        static let machineID = "machineID"
        static let name = "name"
        static let scriptName = "scriptName"
        static let timeout = "timeout"
        static let capabilityNetwork = "capabilityNetwork"
        static let capabilitySubprocess = "capabilitySubprocess"
        static let capabilityReadPaths = "capabilityReadPaths"
        static let capabilityWritePaths = "capabilityWritePaths"
        static let capabilityEnvKeys = "capabilityEnvKeys"
        static let icon = "icon"
    }

    enum Job {
        static let jobID = "jobID"
        static let machineID = "machineID"
        static let agentID = "agentID"
        static let prompt = "prompt"
        static let status = "status"
        static let createdAt = "createdAt"
        static let startedAt = "startedAt"
        static let completedAt = "completedAt"
        static let exitCode = "exitCode"
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

    enum OutputChunk {
        static let jobID = "jobID"
        static let sequence = "sequence"
        static let text = "text"
        static let isError = "isError"
        static let timestamp = "timestamp"
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
    var activeJobID: String?

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
        self.activeJobID = record[CKSchema.Machine.activeJobID] as? String
    }

    func applying(to record: CKRecord) -> CKRecord {
        record[CKSchema.Machine.machineID] = machineID
        record[CKSchema.Machine.name] = name
        record[CKSchema.Machine.platform] = platform
        record[CKSchema.Machine.lastHeartbeat] = lastHeartbeat
        record[CKSchema.Machine.status] = status.rawValue
        record[CKSchema.Machine.activeJobID] = activeJobID as CKRecordValueProtocol?
        return record
    }
}

// MARK: - Agent

struct AgentCapabilities: Sendable {
    var network: Bool
    var subprocess: Bool
    var readPaths: [String]
    var writePaths: [String]
    var envKeys: [String]
    var timeout: Int

    init(
        network: Bool = false,
        subprocess: Bool = false,
        readPaths: [String] = [],
        writePaths: [String] = [],
        envKeys: [String] = [],
        timeout: Int = 60
    ) {
        self.network = network
        self.subprocess = subprocess
        self.readPaths = readPaths
        self.writePaths = writePaths
        self.envKeys = envKeys
        self.timeout = timeout
    }
}

struct AgentRecord: Sendable {
    let agentID: String
    let machineID: String
    var name: String
    var scriptName: String
    var capabilities: AgentCapabilities
    var icon: String?

    var recordName: String { "\(machineID)-\(agentID)" }

    init(agentID: String = UUID().uuidString, machineID: String, name: String, scriptName: String, capabilities: AgentCapabilities = AgentCapabilities()) {
        self.agentID = agentID
        self.machineID = machineID
        self.name = name
        self.scriptName = scriptName
        self.capabilities = capabilities
    }

    init?(record: CKRecord) {
        guard
            let agentID = record[CKSchema.Agent.agentID] as? String,
            let machineID = record[CKSchema.Agent.machineID] as? String,
            let name = record[CKSchema.Agent.name] as? String,
            let scriptName = record[CKSchema.Agent.scriptName] as? String
        else { return nil }

        self.agentID = agentID
        self.machineID = machineID
        self.name = name
        self.scriptName = scriptName
        self.icon = record[CKSchema.Agent.icon] as? String
        self.capabilities = AgentCapabilities(
            network: (record[CKSchema.Agent.capabilityNetwork] as? Int64 ?? 0) != 0,
            subprocess: (record[CKSchema.Agent.capabilitySubprocess] as? Int64 ?? 0) != 0,
            readPaths: record[CKSchema.Agent.capabilityReadPaths] as? [String] ?? [],
            writePaths: record[CKSchema.Agent.capabilityWritePaths] as? [String] ?? [],
            envKeys: record[CKSchema.Agent.capabilityEnvKeys] as? [String] ?? [],
            timeout: Int(record[CKSchema.Agent.timeout] as? Int64 ?? 60)
        )
    }

    func applying(to record: CKRecord) -> CKRecord {
        record[CKSchema.Agent.agentID] = agentID
        record[CKSchema.Agent.machineID] = machineID
        record[CKSchema.Agent.name] = name
        record[CKSchema.Agent.scriptName] = scriptName
        record[CKSchema.Agent.icon] = icon as CKRecordValueProtocol?
        record[CKSchema.Agent.capabilityNetwork] = Int64(capabilities.network ? 1 : 0)
        record[CKSchema.Agent.capabilitySubprocess] = Int64(capabilities.subprocess ? 1 : 0)
        record[CKSchema.Agent.capabilityReadPaths] = capabilities.readPaths as CKRecordValueProtocol
        record[CKSchema.Agent.capabilityWritePaths] = capabilities.writePaths as CKRecordValueProtocol
        record[CKSchema.Agent.capabilityEnvKeys] = capabilities.envKeys as CKRecordValueProtocol
        record[CKSchema.Agent.timeout] = Int64(capabilities.timeout)
        return record
    }
}

// MARK: - Job

enum JobStatus: String, Sendable {
    case queued, acknowledged, running, waiting, completed, failed, cancelled
}

struct JobRecord: Sendable {
    let jobID: String
    let machineID: String
    let agentID: String
    let prompt: String
    var status: JobStatus
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var exitCode: Int?

    var recordName: String { jobID }

    init?(record: CKRecord) {
        guard
            let jobID = record[CKSchema.Job.jobID] as? String,
            let machineID = record[CKSchema.Job.machineID] as? String,
            let agentID = record[CKSchema.Job.agentID] as? String,
            let prompt = record[CKSchema.Job.prompt] as? String,
            let statusRaw = record[CKSchema.Job.status] as? String,
            let status = JobStatus(rawValue: statusRaw),
            let createdAt = record[CKSchema.Job.createdAt] as? Date
        else { return nil }

        self.jobID = jobID
        self.machineID = machineID
        self.agentID = agentID
        self.prompt = prompt
        self.status = status
        self.createdAt = createdAt
        self.startedAt = record[CKSchema.Job.startedAt] as? Date
        self.completedAt = record[CKSchema.Job.completedAt] as? Date
        if let code = record[CKSchema.Job.exitCode] as? Int64 {
            self.exitCode = Int(code)
        }
    }

    func applying(to record: CKRecord) -> CKRecord {
        record[CKSchema.Job.jobID] = jobID
        record[CKSchema.Job.machineID] = machineID
        record[CKSchema.Job.agentID] = agentID
        record[CKSchema.Job.prompt] = prompt
        record[CKSchema.Job.status] = status.rawValue
        record[CKSchema.Job.createdAt] = createdAt
        record[CKSchema.Job.startedAt] = startedAt as CKRecordValueProtocol?
        record[CKSchema.Job.completedAt] = completedAt as CKRecordValueProtocol?
        if let code = exitCode {
            record[CKSchema.Job.exitCode] = Int64(code)
        }
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
    }
}

// MARK: - OutputChunk

struct OutputChunkRecord: Sendable {
    let jobID: String
    let sequence: Int
    let text: String
    let isError: Bool
    let timestamp: Date

    var recordName: String { String(format: "%@-%08d", jobID, sequence) }

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: CKSchema.RecordType.outputChunk,
                              recordID: CKRecord.ID(recordName: recordName))
        record[CKSchema.OutputChunk.jobID] = jobID
        record[CKSchema.OutputChunk.sequence] = Int64(sequence)
        record[CKSchema.OutputChunk.text] = text
        record[CKSchema.OutputChunk.isError] = Int64(isError ? 1 : 0)
        record[CKSchema.OutputChunk.timestamp] = timestamp
        return record
    }
}
