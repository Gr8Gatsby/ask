import SwiftData
import Foundation

// MARK: - ChatSession

/// Represents one active agent session. Deleted (with all its entries) when the session ends.
@Model
final class ChatSession {
    @Attribute(.unique) var sessionId: String
    var scriptID: String
    var machineID: String
    var project: String
    var startedAt: Date
    var lastActivityAt: Date

    init(sessionId: String, scriptID: String, machineID: String, project: String) {
        self.sessionId = sessionId
        self.scriptID = scriptID
        self.machineID = machineID
        self.project = project
        self.startedAt = Date()
        self.lastActivityAt = Date()
    }
}

// MARK: - ChatEntry

/// One item in a session's chat thread — a message, an inline block, a block response, or a system event.
@Model
final class ChatEntry {
    var entryID: String
    /// Foreign key: matches ChatSession.sessionId and RKAgentSessionPayload.sessionId.
    var sessionId: String
    /// "user" | "assistant" | "system"
    var role: String
    /// "message" | "inlineBlock" | "blockResponse" | "event"
    var entryKind: String
    /// Display text or message content.
    var text: String
    /// For inlineBlock entries: the CloudKit block ID (used to match live block state).
    var blockID: String?
    /// For inlineBlock entries: the full payloadJSON from the RKBlock at capture time.
    var blockJSON: String?
    /// For inlineBlock / blockResponse entries: the value the user chose.
    var resolvedValue: String?
    var timestamp: Date

    init(
        entryID: String = UUID().uuidString,
        sessionId: String,
        role: String,
        entryKind: String,
        text: String,
        blockID: String? = nil,
        blockJSON: String? = nil,
        resolvedValue: String? = nil,
        timestamp: Date = Date()
    ) {
        self.entryID = entryID
        self.sessionId = sessionId
        self.role = role
        self.entryKind = entryKind
        self.text = text
        self.blockID = blockID
        self.blockJSON = blockJSON
        self.resolvedValue = resolvedValue
        self.timestamp = timestamp
    }
}
