import Foundation
import CloudKit
import SwiftUI

// MARK: - Schema constants (mirrors AskMac CloudKitSchema.swift)

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
        static let session = "AskSession"
        static let rkBlock = "RKBlock"
        static let rkResponse = "RKResponse"
        static let device = "AskDevice"
        static let feedSchedule = "FeedSchedule"
        static let askInvokeRequest = "AskInvokeRequest"
        static let askScript        = "AskScript"
        // Task history (A2A protocol)
        static let askTask        = "AskTask"
        static let askTaskMessage = "AskTaskMessage"
        static let askArtifact    = "AskArtifact"
    }

    // MARK: - AskTask

    enum AskTask {
        static let taskID         = "taskID"
        static let machineID      = "machineID"
        static let scriptID       = "scriptID"
        static let scriptName     = "scriptName"
        static let scriptIcon     = "scriptIcon"
        static let scriptIconData = "scriptIconData"
        static let title          = "title"
        static let status         = "status"
        static let lastActivityAt = "lastActivityAt"
        static let messageCount   = "messageCount"
        static let artifactCount  = "artifactCount"
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
        static let scriptType = "scriptType"
        static let showsInInbox = "showsInInbox"
    }

    enum AskInvokeRequest {
        static let machineID   = "machineID"
        static let scriptID    = "scriptID"
        static let requestedAt = "requestedAt"
    }

    enum AskScript {
        static let machineID  = "machineID"
        static let scriptID   = "scriptID"
        static let scriptName = "scriptName"
        static let scriptType = "scriptType"
        static let scriptIcon = "scriptIcon"
        static let version    = "version"
        static let status     = "status"
        static let lastRunAt  = "lastRunAt"
        static let nextRunAt  = "nextRunAt"
        static let updatedAt  = "updatedAt"
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

    enum Response {
        static let eventID = "eventID"
        static let machineID = "machineID"
        static let choice = "choice"
        static let timestamp = "timestamp"
    }

    enum Machine {
        static let machineID = "machineID"
        static let name = "name"
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

    enum OutputChunk {
        static let jobID = "jobID"
        static let sequence = "sequence"
        static let text = "text"
        static let isError = "isError"
    }
}

// MARK: - Date formatting

extension Date {
    /// Compact relative time: "now", "5m", "2h", "3d", "Apr 3". Does not live-tick.
    var briefRelative: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: self)
    }
}

// MARK: - Script registry

struct AskScript: Identifiable {
    var id: String { "\(machineID)/\(scriptID)" }
    let machineID:  String
    let scriptID:   String
    let scriptName: String
    let scriptType: String   // "feed", "tile", "system"
    let scriptIcon: String?
    let version:    String?
    let status:     String   // "running", "idle", "disabled", "crashed"
    let lastRunAt:  Date?
    let nextRunAt:  Date?
    let updatedAt:  Date
    var machineName: String  // joined from AskMachine, not stored in record

    var isFeed: Bool { scriptType == "feed" }
    var statusColor: Color {
        switch status {
        case "running":  return .blue
        case "idle":     return .secondary
        case "crashed":  return .red
        case "disabled": return .secondary
        default:         return .secondary
        }
    }
    var statusIcon: String {
        switch status {
        case "running":  return "circle.fill"
        case "idle":     return "circle"
        case "crashed":  return "exclamationmark.circle.fill"
        case "disabled": return "minus.circle"
        default:         return "circle"
        }
    }

    init?(record: CKRecord, machineName: String) {
        guard
            let machineID  = record[CKSchema.AskScript.machineID]  as? String,
            let scriptID   = record[CKSchema.AskScript.scriptID]   as? String,
            let scriptName = record[CKSchema.AskScript.scriptName] as? String,
            let scriptType = record[CKSchema.AskScript.scriptType] as? String,
            let status     = record[CKSchema.AskScript.status]     as? String,
            let updatedAt  = record[CKSchema.AskScript.updatedAt]  as? Date
        else { return nil }
        self.machineID  = machineID
        self.scriptID   = scriptID
        self.scriptName = scriptName
        self.scriptType = scriptType
        self.scriptIcon = record[CKSchema.AskScript.scriptIcon] as? String
        self.version    = record[CKSchema.AskScript.version]    as? String
        self.status     = status
        self.lastRunAt  = record[CKSchema.AskScript.lastRunAt]  as? Date
        self.nextRunAt  = record[CKSchema.AskScript.nextRunAt]  as? Date
        self.updatedAt  = updatedAt
        self.machineName = machineName
    }
}

// MARK: - Machine

enum MachineStatus: String {
    case idle, busy

    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .busy: "Busy"
        }
    }
}

struct AskMachine: Identifiable {
    let id: String          // machineID
    let name: String
    /// Effective last-seen time — max of the CloudKit heartbeat and the most recent block createdAt.
    /// Mutable so HomeView can update it when blocks arrive without a matching heartbeat.
    var lastHeartbeat: Date
    let status: MachineStatus
    let activeJobID: String?

    var systemImage: String {
        let lower = name.lowercased()
        if lower.contains("macbook") { return "laptopcomputer" }
        if lower.contains("mac mini") { return "macmini" }
        if lower.contains("mac studio") { return "macstudio" }
        if lower.contains("mac pro") { return "macpro.gen3" }
        return "desktopcomputer"
    }

    var connectionStatus: ConnectionStatus {
        let age = Date().timeIntervalSince(lastHeartbeat)
        // 3 min: allows for 6 missed heartbeats or a post-sleep CloudKit delay.
        // 20 min: sleeping (Mac likely closed lid or network unavailable).
        // 20 min+: offline for our purposes (blocks can't be acted on).
        if age < 180 { return status == .busy ? .busy : .online }
        if age < 1200 { return .sleeping }
        return .offline
    }

    enum ConnectionStatus {
        case online, busy, sleeping, offline

        var label: String {
            switch self {
            case .online: "Online"
            case .busy: "Busy"
            case .sleeping: "Sleeping"
            case .offline: "Offline"
            }
        }

        var color: String {          // SwiftUI color name
            switch self {
            case .online: "green"
            case .busy: "blue"
            case .sleeping: "yellow"
            case .offline: "gray"
            }
        }

        var systemImage: String {
            switch self {
            case .online: "checkmark.circle.fill"
            case .busy: "gearshape.fill"
            case .sleeping: "moon.fill"
            case .offline: "circle.slash"
            }
        }
    }

    init?(record: CKRecord) {
        guard
            let machineID = record[CKSchema.Machine.machineID] as? String,
            let name = record[CKSchema.Machine.name] as? String,
            let lastHeartbeat = record[CKSchema.Machine.lastHeartbeat] as? Date,
            let statusRaw = record[CKSchema.Machine.status] as? String
        else { return nil }

        self.id = machineID
        self.name = name
        self.lastHeartbeat = lastHeartbeat
        self.status = MachineStatus(rawValue: statusRaw) ?? .idle
        self.activeJobID = record[CKSchema.Machine.activeJobID] as? String
    }
}

// MARK: - Agent

struct AskAgent: Identifiable {
    let id: String          // agentID
    let machineID: String
    let name: String
    let scriptName: String
    let icon: String?

    // Capabilities for display
    let capabilityNetwork: Bool
    let capabilitySubprocess: Bool
    let capabilityReadPaths: [String]
    let capabilityWritePaths: [String]
    let capabilityEnvKeys: [String]
    let timeout: Int

    init?(record: CKRecord) {
        guard
            let agentID = record[CKSchema.Agent.agentID] as? String,
            let machineID = record[CKSchema.Agent.machineID] as? String,
            let name = record[CKSchema.Agent.name] as? String,
            let scriptName = record[CKSchema.Agent.scriptName] as? String
        else { return nil }

        self.id = agentID
        self.machineID = machineID
        self.name = name
        self.scriptName = scriptName
        self.icon = record[CKSchema.Agent.icon] as? String
        self.capabilityNetwork = (record[CKSchema.Agent.capabilityNetwork] as? Int64 ?? 0) != 0
        self.capabilitySubprocess = (record[CKSchema.Agent.capabilitySubprocess] as? Int64 ?? 0) != 0
        self.capabilityReadPaths = record[CKSchema.Agent.capabilityReadPaths] as? [String] ?? []
        self.capabilityWritePaths = record[CKSchema.Agent.capabilityWritePaths] as? [String] ?? []
        self.capabilityEnvKeys = record[CKSchema.Agent.capabilityEnvKeys] as? [String] ?? []
        self.timeout = Int(record[CKSchema.Agent.timeout] as? Int64 ?? 60)
    }
}

// MARK: - Job

enum JobStatus: String {
    case queued, acknowledged, running, waiting, completed, failed, cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    var displayName: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .acknowledged: "arrow.down.circle"
        case .running: "gearshape.fill"
        case .waiting: "person.fill.questionmark"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        }
    }
}

struct AskJob: Identifiable {
    let id: String          // jobID
    let machineID: String
    let agentID: String
    let prompt: String
    let status: JobStatus
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let exitCode: Int?

    init?(record: CKRecord) {
        guard
            let jobID = record[CKSchema.Job.jobID] as? String,
            let machineID = record[CKSchema.Job.machineID] as? String,
            let agentID = record[CKSchema.Job.agentID] as? String,
            let prompt = record[CKSchema.Job.prompt] as? String,
            let statusRaw = record[CKSchema.Job.status] as? String,
            let createdAt = record[CKSchema.Job.createdAt] as? Date
        else { return nil }

        self.id = jobID
        self.machineID = machineID
        self.agentID = agentID
        self.prompt = prompt
        self.status = JobStatus(rawValue: statusRaw) ?? .queued
        self.createdAt = createdAt
        self.startedAt = record[CKSchema.Job.startedAt] as? Date
        self.completedAt = record[CKSchema.Job.completedAt] as? Date
        if let code = record[CKSchema.Job.exitCode] as? Int64 {
            self.exitCode = Int(code)
        } else {
            self.exitCode = nil
        }
    }
}

// MARK: - Event

struct AskEvent: Identifiable {
    let id: String          // eventID
    let ckRecordID: CKRecord.ID
    let machineID: String
    let title: String
    let body: String
    let source: String
    let options: [String]   // empty = notification only
    let timestamp: Date
    let sessionID: String?

    /// True for any ask-prompt event (has buttons or needs typed answer).
    var requiresResponse: Bool { !options.isEmpty || source == "ask-prompt" }

    init?(record: CKRecord) {
        guard
            let eventID = record[CKSchema.Event.eventID] as? String,
            let machineID = record[CKSchema.Event.machineID] as? String,
            let title = record[CKSchema.Event.title] as? String,
            let timestamp = record[CKSchema.Event.timestamp] as? Date
        else { return nil }

        self.id = eventID
        self.ckRecordID = record.recordID
        self.machineID = machineID
        self.title = title
        self.body = record[CKSchema.Event.body] as? String ?? ""
        self.source = record[CKSchema.Event.source] as? String ?? ""
        self.options = (record[CKSchema.Event.options] as? [Any])?.compactMap { $0 as? String } ?? []
        self.timestamp = timestamp
        self.sessionID = record[CKSchema.Event.sessionID] as? String
    }
}

// MARK: - Session

struct AskSession: Identifiable {
    let id: String          // sessionID
    let machineID: String
    let title: String
    let status: SessionStatus
    let startedAt: Date
    let lastActivityAt: Date

    enum SessionStatus: String {
        case waiting, active, completed

        var isWaiting: Bool { self == .waiting }
    }

    init?(record: CKRecord) {
        guard
            let sessionID = record[CKSchema.Session.sessionID] as? String,
            let machineID = record[CKSchema.Session.machineID] as? String,
            let title = record[CKSchema.Session.title] as? String,
            let lastActivityAt = record[CKSchema.Session.lastActivityAt] as? Date
        else { return nil }

        self.id = sessionID
        self.machineID = machineID
        self.title = title
        self.lastActivityAt = lastActivityAt
        self.startedAt = record[CKSchema.Session.startedAt] as? Date ?? lastActivityAt
        let statusRaw = record[CKSchema.Session.status] as? String ?? "active"
        self.status = SessionStatus(rawValue: statusRaw) ?? .active
    }

    /// Returns a copy with a corrected status (used to reflect server-side auto-resolution locally).
    init(correcting other: AskSession, status: SessionStatus) {
        self.id = other.id
        self.machineID = other.machineID
        self.title = other.title
        self.status = status
        self.startedAt = other.startedAt
        self.lastActivityAt = other.lastActivityAt
    }
}

// MARK: - Output chunk

struct AskOutputChunk: Identifiable {
    let id: String          // recordName
    let jobID: String
    let sequence: Int
    let text: String
    let isError: Bool

    init?(record: CKRecord) {
        guard
            let jobID = record[CKSchema.OutputChunk.jobID] as? String,
            let sequence = record[CKSchema.OutputChunk.sequence] as? Int64,
            let text = record[CKSchema.OutputChunk.text] as? String
        else { return nil }

        self.id = record.recordID.recordName
        self.jobID = jobID
        self.sequence = Int(sequence)
        self.text = text
        self.isError = (record[CKSchema.OutputChunk.isError] as? Int64 ?? 0) != 0
    }
}
