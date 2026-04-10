import SwiftData
import Foundation
import CloudKit

// MARK: - TaskRecord

/// Locally persisted AskTask — the top-level unit of A2A task history.
/// One record per (machineID, scriptID, taskID) triple.
@Model
final class TaskRecord {
    @Attribute(.unique) var recordName: String   // "\(machineID)-\(scriptID)-\(taskID)"
    var taskID: String
    var machineID: String
    var scriptID: String
    var scriptName: String
    var scriptIcon: String?
    var scriptIconData: String?
    var title: String
    var status: String   // working | completed | failed | cancelled
    var lastActivityAt: Date
    var messageCount: Int
    var artifactCount: Int

    init(
        recordName: String,
        taskID: String,
        machineID: String,
        scriptID: String,
        scriptName: String,
        scriptIcon: String?,
        scriptIconData: String?,
        title: String,
        status: String,
        lastActivityAt: Date,
        messageCount: Int,
        artifactCount: Int
    ) {
        self.recordName = recordName
        self.taskID = taskID
        self.machineID = machineID
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.scriptIcon = scriptIcon
        self.scriptIconData = scriptIconData
        self.title = title
        self.status = status
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.artifactCount = artifactCount
    }

    convenience init?(ckRecord: CKRecord) {
        guard
            let taskID     = ckRecord[CKSchema.AskTask.taskID]    as? String,
            let machineID  = ckRecord[CKSchema.AskTask.machineID] as? String,
            let scriptID   = ckRecord[CKSchema.AskTask.scriptID]  as? String,
            let scriptName = ckRecord[CKSchema.AskTask.scriptName] as? String,
            let title      = ckRecord[CKSchema.AskTask.title]     as? String,
            let status     = ckRecord[CKSchema.AskTask.status]    as? String,
            let lastActivityAt = ckRecord[CKSchema.AskTask.lastActivityAt] as? Date
        else { return nil }

        self.init(
            recordName: ckRecord.recordID.recordName,
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: scriptName,
            scriptIcon: ckRecord[CKSchema.AskTask.scriptIcon] as? String,
            scriptIconData: ckRecord[CKSchema.AskTask.scriptIconData] as? String,
            title: title,
            status: status,
            lastActivityAt: lastActivityAt,
            messageCount: (ckRecord[CKSchema.AskTask.messageCount] as? Int64).map(Int.init) ?? 0,
            artifactCount: (ckRecord[CKSchema.AskTask.artifactCount] as? Int64).map(Int.init) ?? 0
        )
    }

    var statusEnum: TaskStatus { TaskStatus(rawValue: status) ?? .working }
}

// MARK: - TaskStatus

enum TaskStatus: String {
    case working, completed, failed, cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .working: false
        }
    }

    var displayName: String {
        switch self {
        case .working: "Working"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .working: "gearshape.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        }
    }
}

// MARK: - TaskMessage

/// Locally persisted message in a task's conversation thread.
@Model
final class TaskMessage {
    @Attribute(.unique) var messageID: String
    var taskID: String
    var machineID: String
    var scriptID: String
    var role: String           // "assistant" | "user"
    var partsJSON: String      // JSON array of Part objects
    var timestamp: Date
    var sequenceNumber: Int

    init(
        messageID: String,
        taskID: String,
        machineID: String,
        scriptID: String,
        role: String,
        partsJSON: String,
        timestamp: Date,
        sequenceNumber: Int
    ) {
        self.messageID = messageID
        self.taskID = taskID
        self.machineID = machineID
        self.scriptID = scriptID
        self.role = role
        self.partsJSON = partsJSON
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }

    convenience init?(ckRecord: CKRecord) {
        guard
            let messageID      = ckRecord[CKSchema.AskTaskMessage.messageID]      as? String,
            let taskID         = ckRecord[CKSchema.AskTaskMessage.taskID]         as? String,
            let machineID      = ckRecord[CKSchema.AskTaskMessage.machineID]      as? String,
            let scriptID       = ckRecord[CKSchema.AskTaskMessage.scriptID]       as? String,
            let role           = ckRecord[CKSchema.AskTaskMessage.role]           as? String,
            let partsJSON      = ckRecord[CKSchema.AskTaskMessage.partsJSON]      as? String,
            let timestamp      = ckRecord[CKSchema.AskTaskMessage.timestamp]      as? Date,
            let sequenceNumber = ckRecord[CKSchema.AskTaskMessage.sequenceNumber] as? Int64
        else { return nil }

        self.init(
            messageID: messageID,
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            role: role,
            partsJSON: partsJSON,
            timestamp: timestamp,
            sequenceNumber: Int(sequenceNumber)
        )
    }

    /// Decoded message parts. Returns an empty array if partsJSON is malformed.
    var parts: [TaskPart] {
        guard let data = partsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { TaskPart(dict: $0) }
    }
}

// MARK: - TaskPart

/// A single part of a task message, following the A2A Part model.
enum TaskPart {
    case text(String)
    case file(mimeType: String, uri: String)
    case data(mimeType: String, base64: String)

    init?(dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let text = dict["text"] as? String else { return nil }
            self = .text(text)
        case "file":
            guard let mimeType = dict["mimeType"] as? String,
                  let uri = dict["uri"] as? String else { return nil }
            self = .file(mimeType: mimeType, uri: uri)
        case "data":
            guard let mimeType = dict["mimeType"] as? String,
                  let data = dict["data"] as? String else { return nil }
            self = .data(mimeType: mimeType, base64: data)
        default:
            return nil
        }
    }

    var displayText: String {
        switch self {
        case .text(let t): return t
        case .file(_, let uri): return uri
        case .data(let mime, _): return "[\(mime)]"
        }
    }
}

// MARK: - ArtifactRecord

/// Locally persisted artifact metadata. The file content is cached separately in
/// the Caches directory (keyed by recordName) by TaskHistoryStore.
@Model
final class ArtifactRecord {
    @Attribute(.unique) var recordName: String   // "\(machineID)-\(scriptID)-\(artifactID)"
    var artifactID: String
    var taskID: String
    var machineID: String
    var scriptID: String
    var filename: String
    var mimeType: String
    var artifactDescription: String?
    var sizeBytes: Int
    var updatedAt: Date
    /// True once the file content has been downloaded and written to the local cache.
    var isDownloaded: Bool

    init(
        recordName: String,
        artifactID: String,
        taskID: String,
        machineID: String,
        scriptID: String,
        filename: String,
        mimeType: String,
        artifactDescription: String?,
        sizeBytes: Int,
        updatedAt: Date,
        isDownloaded: Bool = false
    ) {
        self.recordName = recordName
        self.artifactID = artifactID
        self.taskID = taskID
        self.machineID = machineID
        self.scriptID = scriptID
        self.filename = filename
        self.mimeType = mimeType
        self.artifactDescription = artifactDescription
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.isDownloaded = isDownloaded
    }

    convenience init?(ckRecord: CKRecord) {
        guard
            let artifactID = ckRecord[CKSchema.AskArtifact.artifactID] as? String,
            let taskID     = ckRecord[CKSchema.AskArtifact.taskID]     as? String,
            let machineID  = ckRecord[CKSchema.AskArtifact.machineID]  as? String,
            let scriptID   = ckRecord[CKSchema.AskArtifact.scriptID]   as? String,
            let filename   = ckRecord[CKSchema.AskArtifact.filename]   as? String,
            let mimeType   = ckRecord[CKSchema.AskArtifact.mimeType]   as? String,
            let sizeBytes  = ckRecord[CKSchema.AskArtifact.sizeBytes]  as? Int64,
            let updatedAt  = ckRecord[CKSchema.AskArtifact.updatedAt]  as? Date
        else { return nil }

        self.init(
            recordName: ckRecord.recordID.recordName,
            artifactID: artifactID,
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            filename: filename,
            mimeType: mimeType,
            artifactDescription: ckRecord[CKSchema.AskArtifact.description] as? String,
            sizeBytes: Int(sizeBytes),
            updatedAt: updatedAt,
            isDownloaded: false
        )
    }

    /// Local cache path for this artifact's file content.
    var localCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ask-artifacts")
            .appendingPathComponent(recordName)
            .appendingPathExtension(fileExtension)
    }

    private var fileExtension: String {
        switch mimeType {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "application/json": return "json"
        default:
            let ext = filename.split(separator: ".").last.map(String.init) ?? ""
            return ext.isEmpty ? "bin" : ext
        }
    }
}
