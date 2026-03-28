import Foundation
import CloudKit

// MARK: - Schema constants (mirrors AskMac CloudKitSchema.swift)

enum CKSchema {
    static let containerID = "iCloud.simple.ask"

    enum RecordType {
        static let machine = "Machine"
        static let agent = "Agent"
        static let job = "Job"
        static let outputChunk = "OutputChunk"
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
    let lastHeartbeat: Date
    let status: MachineStatus
    let activeJobID: String?

    var connectionStatus: ConnectionStatus {
        let age = Date().timeIntervalSince(lastHeartbeat)
        if age < 60 { return status == .busy ? .busy : .online }
        if age < 300 { return .sleeping }
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
    case queued, acknowledged, running, completed, failed, cancelled

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
