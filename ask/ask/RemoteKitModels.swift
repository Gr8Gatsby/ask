import Foundation
import CloudKit
import SwiftUI

// MARK: - Block type

enum RKBlockType: String, Codable {
    case confirmation
    case alert
    case status
    case prompt
    case infoCard = "info_card"
    case chatPrompt = "chat_prompt"
    case claudeMessage = "claude_message"
    case agentSession = "agent_session"
    case iconCard = "icon_card"
    case tile   // drives home-screen tile display; not shown in detail view
    case countdown
    case picker
    case list
    case detail
    case feedItem = "feed_item"
    case startSession = "start_session"
    case activityFeed = "activity_feed"
    case compactSummary = "compact_summary"
    case sessionEvent = "session_event"
    case diagnostics
    case quickReply = "quick_reply"
    case image
}

// MARK: - Urgency

enum RKUrgency: String, Codable {
    case urgent
    case warning
    case info

    /// Sort rank — lower value sorts first.
    var sortRank: Int {
        switch self {
        case .urgent:  return 0
        case .warning: return 1
        case .info:    return 2
        }
    }
}

// MARK: - Block payloads

struct RKConfirmationPayload: Codable {
    let title: String
    let body: String
    let options: [String]
    let sessionId: String?
    let urgency: RKUrgency?
    /// When "list", always render as a vertical radio-button list regardless of option count.
    let style: String?

    private enum CodingKeys: String, CodingKey {
        case title, body, options, urgency, style
        case sessionId = "session_id"
    }
}

struct RKAlertPayload: Codable {
    let title: String
    let body: String
    let icon: String?
    let urgency: RKUrgency?
}

struct RKStatusPayload: Codable {
    let label: String
    let detail: String?
    let icon: String?
    let color: String?
}

struct RKPromptPayload: Codable {
    let title: String
    let placeholder: String?
    let multiline: Bool?
    let urgency: RKUrgency?
}

struct RKChatPromptPayload: Codable {
    let title: String
    let context: String?       // Claude's last message shown above the input — rendered as markdown
    let placeholder: String?
    let urgency: RKUrgency?
}

struct RKQuickReplyPayload: Codable {
    let title: String
    let description: String?
    let options: [String]
    let allowCustom: Bool?
    let urgency: RKUrgency?

    enum CodingKeys: String, CodingKey {
        case title, description, options, urgency
        case allowCustom = "allow_custom"
    }
}

struct RKClaudeMessagePayload: Codable {
    let text: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case text
        case sessionId = "session_id"
    }
}

struct RKPendingConfirmation: Codable, Equatable {
    let title: String
    let body: String?
    let options: [String]
}

struct ToolHistoryEntry: Codable {
    let tool: String
    let preview: String
    let ts: Double
}

struct RKAgentSessionPayload: Codable {
    let sessionId: String
    let project: String
    let cwd: String?
    let lastMessage: String?
    let placeholder: String?
    let isWorking: Bool?
    let agentName: String?
    let brandColor: String?
    let currentTool: String?
    let currentPreview: String?
    let toolHistory: [ToolHistoryEntry]?
    let permissionMode: String?
    let isHeadless: Bool?
    let tty: String?
    let pendingConfirmation: RKPendingConfirmation?
    let taskId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case project
        case cwd
        case lastMessage = "last_message"
        case placeholder
        case isWorking = "is_working"
        case agentName = "agent_name"
        case brandColor = "brand_color"
        case currentTool = "current_tool"
        case currentPreview = "current_preview"
        case toolHistory = "tool_history"
        case permissionMode = "permission_mode"
        case isHeadless = "is_headless"
        case tty
        case pendingConfirmation = "pending_confirmation"
        case taskId = "task_id"
    }

    /// Parses `brandColor` hex string (e.g. `#74AA9C`) into a SwiftUI Color.
    var brandColorValue: Color {
        guard let hex = brandColor else { return .accentColor }
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return .accentColor }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Tool activity helpers

func toolIcon(_ tool: String) -> String {
    switch tool {
    case "Edit":   return "pencil"
    case "Write":  return "doc.badge.plus"
    case "Read":   return "doc.text"
    case "Bash":   return "terminal"
    case "Glob":   return "folder.badge.questionmark"
    case "Grep":   return "magnifyingglass"
    case "Agent":  return "sparkles"
    default:       return "wrench"
    }
}

func toolActivityText(_ tool: String, _ preview: String?) -> String {
    let p = preview.map { $0.isEmpty ? nil : $0 } ?? nil
    switch tool {
    case "Compact": return p.map { "Summarizing \($0)" } ?? "Summarizing context"
    case "Edit":  return p.map { "Editing \($0)" }  ?? "Editing file"
    case "Write": return p.map { "Writing \($0)" }  ?? "Writing file"
    case "Read":  return p.map { "Reading \($0)" }  ?? "Reading file"
    case "Bash":  return p.map { "Running: \($0)" } ?? "Running command"
    case "Glob":  return p.map { "Searching \($0)" } ?? "Searching files"
    case "Grep":  return p.map { "Searching for \($0)" } ?? "Searching content"
    case "Agent": return p.map { "Agent: \($0)" }   ?? "Running agent"
    default:      return p ?? tool
    }
}

struct RKTilePayload: Codable {
    let label: String           // short status text, < 50 chars
    let statusColor: String?    // green / blue / orange / red / yellow
    let body: String?           // optional multi-line update text
    let actionRequired: Bool?   // explicit opt-in: show toast + orange border

    enum CodingKeys: String, CodingKey {
        case label
        case statusColor   = "status_color"
        case body
        case actionRequired = "action_required"
    }
}

struct RKIconCardPayload: Codable {
    let title: String
    let subtitle: String?
}

struct RKCountdownPayload: Codable {
    let label: String
    let time: String    // ISO 8601 UTC timestamp
}

struct RKPickerPayload: Codable {
    let title: String
    let options: [String]
    let selected: String?   // pre-selected value, if any
}

struct RKListPayload: Codable {
    struct Item: Codable, Identifiable {
        let id: String
        let label: String
        let subtitle: String?
    }
    let title: String?
    let items: [Item]
    let actions: [String]?
}

struct RKDetailPayload: Codable {
    let title: String
    let body: String
    let actions: [String]?
}

struct RKImagePayload: Codable {
    let title: String
    let data: String    // base64-encoded image bytes
    let format: String  // "png"
}

struct RKFeedItemPayload: Codable {
    let headline: String
    let body: String?
    let statusColor: String?

    enum CodingKeys: String, CodingKey {
        case headline
        case body
        case statusColor = "status_color"
    }
}

struct RKInfoCardPayload: Codable {
    struct Pair: Codable {
        let key: String
        let value: String
    }
    let title: String
    let pairs: [Pair]
}

struct RKRepo: Codable, Identifiable {
    let name: String
    let path: String
    let value: String?
    var id: String { value ?? path }
}

struct RKStartSessionPayload: Codable {
    let repos: [RKRepo]
}

struct RKActivityFeedPayload: Codable {
    let sessionId: String
    let project: String
    let entries: [ToolHistoryEntry]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case project
        case entries
    }
}

struct RKCompactSummaryPayload: Codable {
    let sessionId: String
    let project: String
    let trigger: String
    let summary: String
    let ts: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case project
        case trigger
        case summary
        case ts
    }
}

struct RKSessionEventPayload: Codable {
    let event: String   // "started" | "stopped"
    let project: String
    let cwd: String?
    let ts: Double?

    enum CodingKeys: String, CodingKey {
        case event
        case project
        case cwd
        case ts
    }
}

struct RKDiagnosticsHook: Codable, Identifiable {
    let event: String
    let path: String
    let ok: Bool
    var id: String { event + path }
}

struct RKDiagnosticsPayload: Codable {
    let version: String
    let hooks: [RKDiagnosticsHook]
    let hooksOk: Bool
    let socketOk: Bool
    let logLines: [String]

    enum CodingKeys: String, CodingKey {
        case version, hooks
        case hooksOk = "hooks_ok"
        case socketOk = "socket_ok"
        case logLines = "log_lines"
    }
}

// MARK: - RKBlock model

struct RKBlock: Identifiable {
    let id: String          // blockID (also CKRecord name)
    let machineID: String
    let scriptID: String
    let scriptName: String?
    let scriptIcon: String?
    let scriptIconData: String?  // base64-encoded 32×32 PNG of the script's icon
    let scriptIconSVG: String?   // raw SVG markup from the script's icon_file
    let blockType: RKBlockType
    let payloadJSON: String
    let createdAt: Date
    let expiresAt: Date?
    let scriptType: String      // "tile" (default) or "feed"
    let showsInInbox: Bool

    var isFeedBlock: Bool { scriptType == "feed" }

    var requiresResponse: Bool {
        switch blockType {
        case .confirmation, .prompt, .chatPrompt, .picker, .list, .detail, .agentSession, .startSession, .quickReply: return true
        case .alert, .status, .infoCard, .iconCard, .claudeMessage, .tile, .countdown, .feedItem,
             .activityFeed, .compactSummary, .sessionEvent, .diagnostics, .image: return false
        }
    }

    /// The urgency declared in the block's payload, if supported.
    var urgency: RKUrgency? {
        switch blockType {
        case .confirmation: return confirmationPayload?.urgency
        case .alert:        return alertPayload?.urgency
        case .prompt:       return promptPayload?.urgency
        case .chatPrompt:   return chatPromptPayload?.urgency
        case .quickReply:   return quickReplyPayload?.urgency
        default:            return nil
        }
    }

    /// Urgency with default applied: requiresResponse blocks without an explicit urgency default to .warning.
    var effectiveUrgency: RKUrgency? {
        urgency ?? (requiresResponse ? .warning : nil)
    }

    /// Decoded confirmation payload, or nil if wrong type / bad JSON.
    var confirmationPayload: RKConfirmationPayload? {
        guard blockType == .confirmation else { return nil }
        return try? JSONDecoder().decode(RKConfirmationPayload.self, from: payloadData)
    }

    var alertPayload: RKAlertPayload? {
        guard blockType == .alert else { return nil }
        return try? JSONDecoder().decode(RKAlertPayload.self, from: payloadData)
    }

    var statusPayload: RKStatusPayload? {
        guard blockType == .status else { return nil }
        return try? JSONDecoder().decode(RKStatusPayload.self, from: payloadData)
    }

    var promptPayload: RKPromptPayload? {
        guard blockType == .prompt else { return nil }
        return try? JSONDecoder().decode(RKPromptPayload.self, from: payloadData)
    }

    var infoCardPayload: RKInfoCardPayload? {
        guard blockType == .infoCard else { return nil }
        return try? JSONDecoder().decode(RKInfoCardPayload.self, from: payloadData)
    }

    var chatPromptPayload: RKChatPromptPayload? {
        guard blockType == .chatPrompt else { return nil }
        return try? JSONDecoder().decode(RKChatPromptPayload.self, from: payloadData)
    }

    var quickReplyPayload: RKQuickReplyPayload? {
        guard blockType == .quickReply else { return nil }
        return try? JSONDecoder().decode(RKQuickReplyPayload.self, from: payloadData)
    }

    var claudeMessagePayload: RKClaudeMessagePayload? {
        guard blockType == .claudeMessage else { return nil }
        return try? JSONDecoder().decode(RKClaudeMessagePayload.self, from: payloadData)
    }

    var agentSessionPayload: RKAgentSessionPayload? {
        guard blockType == .agentSession else { return nil }
        return try? JSONDecoder().decode(RKAgentSessionPayload.self, from: payloadData)
    }

    var iconCardPayload: RKIconCardPayload? {
        guard blockType == .iconCard else { return nil }
        return try? JSONDecoder().decode(RKIconCardPayload.self, from: payloadData)
    }

    var tilePayload: RKTilePayload? {
        guard blockType == .tile else { return nil }
        return try? JSONDecoder().decode(RKTilePayload.self, from: payloadData)
    }

    var countdownPayload: RKCountdownPayload? {
        guard blockType == .countdown else { return nil }
        return try? JSONDecoder().decode(RKCountdownPayload.self, from: payloadData)
    }

    var pickerPayload: RKPickerPayload? {
        guard blockType == .picker else { return nil }
        return try? JSONDecoder().decode(RKPickerPayload.self, from: payloadData)
    }

    var listPayload: RKListPayload? {
        guard blockType == .list else { return nil }
        return try? JSONDecoder().decode(RKListPayload.self, from: payloadData)
    }

    var detailPayload: RKDetailPayload? {
        guard blockType == .detail else { return nil }
        return try? JSONDecoder().decode(RKDetailPayload.self, from: payloadData)
    }

    var imagePayload: RKImagePayload? {
        guard blockType == .image else { return nil }
        return try? JSONDecoder().decode(RKImagePayload.self, from: payloadData)
    }

    var feedItemPayload: RKFeedItemPayload? {
        guard blockType == .feedItem else { return nil }
        return try? JSONDecoder().decode(RKFeedItemPayload.self, from: payloadData)
    }

    var startSessionPayload: RKStartSessionPayload? {
        guard blockType == .startSession else { return nil }
        return try? JSONDecoder().decode(RKStartSessionPayload.self, from: payloadData)
    }

    var activityFeedPayload: RKActivityFeedPayload? {
        guard blockType == .activityFeed else { return nil }
        return try? JSONDecoder().decode(RKActivityFeedPayload.self, from: payloadData)
    }

    var compactSummaryPayload: RKCompactSummaryPayload? {
        guard blockType == .compactSummary else { return nil }
        return try? JSONDecoder().decode(RKCompactSummaryPayload.self, from: payloadData)
    }

    var sessionEventPayload: RKSessionEventPayload? {
        guard blockType == .sessionEvent else { return nil }
        return try? JSONDecoder().decode(RKSessionEventPayload.self, from: payloadData)
    }

    var diagnosticsPayload: RKDiagnosticsPayload? {
        guard blockType == .diagnostics else { return nil }
        return try? JSONDecoder().decode(RKDiagnosticsPayload.self, from: payloadData)
    }

    /// payloadJSON with UTF-16 surrogate pairs decoded to real Unicode scalars, as UTF-8 Data.
    /// `JSONSerialization` on macOS escapes emoji (U+10000…) as `\uD800\uDC00`-style pairs;
    /// iOS 26 `JSONDecoder` doesn't reassemble them. Pre-decoding here fixes rendering.
    private var payloadData: Data {
        Data(payloadJSON.decodingSurrogatePairs.utf8)
    }

    /// Memberwise initialiser used by unit tests and previews.
    init(id: String, machineID: String, scriptID: String, scriptName: String?,
         scriptIcon: String?, scriptIconData: String?, scriptIconSVG: String?,
         blockType: RKBlockType, payloadJSON: String, createdAt: Date, expiresAt: Date?,
         scriptType: String, showsInInbox: Bool) {
        self.id = id
        self.machineID = machineID
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.scriptIcon = scriptIcon
        self.scriptIconData = scriptIconData
        self.scriptIconSVG = scriptIconSVG
        self.blockType = blockType
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.scriptType = scriptType
        self.showsInInbox = showsInInbox
    }

    init?(record: CKRecord) {
        guard
            let blockID = record[CKSchema.RKBlock.blockID] as? String,
            let machineID = record[CKSchema.RKBlock.machineID] as? String,
            let scriptID = record[CKSchema.RKBlock.scriptID] as? String,
            let blockTypeRaw = record[CKSchema.RKBlock.blockType] as? String,
            let blockType = RKBlockType(rawValue: blockTypeRaw),
            let payloadJSON = record[CKSchema.RKBlock.payload] as? String,
            let createdAt = record[CKSchema.RKBlock.createdAt] as? Date
        else { return nil }

        self.id = blockID
        self.machineID = machineID
        self.scriptID = scriptID
        self.scriptName = record[CKSchema.RKBlock.scriptName] as? String
        self.scriptIcon = record[CKSchema.RKBlock.scriptIcon] as? String
        self.scriptIconData = record[CKSchema.RKBlock.scriptIconData] as? String
        self.scriptIconSVG = record[CKSchema.RKBlock.scriptIconSVG] as? String
        self.blockType = blockType
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.expiresAt = record[CKSchema.RKBlock.expiresAt] as? Date
        self.scriptType = record[CKSchema.RKBlock.scriptType] as? String ?? "tile"
        self.showsInInbox = (record[CKSchema.RKBlock.showsInInbox] as? Int64 ?? 0) != 0
    }
}

// MARK: - RKBlock feed history helpers

extension RKBlock {
    /// A human-readable headline derived from the block's payload, used when saving to FeedHistoryEntry.
    var feedHeadline: String {
        switch blockType {
        case .feedItem:     return feedItemPayload?.headline ?? scriptName ?? scriptID
        case .status:       return statusPayload?.label ?? scriptName ?? scriptID
        case .detail:       return detailPayload?.title ?? scriptName ?? scriptID
        case .infoCard:     return infoCardPayload?.title ?? scriptName ?? scriptID
        case .iconCard:     return iconCardPayload?.title ?? scriptName ?? scriptID
        case .confirmation: return confirmationPayload?.title ?? scriptName ?? scriptID
        case .prompt:       return promptPayload?.title ?? scriptName ?? scriptID
        case .chatPrompt:   return chatPromptPayload?.title ?? scriptName ?? scriptID
        case .quickReply:   return quickReplyPayload?.title ?? scriptName ?? scriptID
        case .alert:        return alertPayload?.title ?? scriptName ?? scriptID
        default:            return scriptName ?? scriptID
        }
    }

    /// Optional status color string from the block's payload.
    var feedStatusColor: String? {
        switch blockType {
        case .feedItem: return feedItemPayload?.statusColor
        case .status:   return statusPayload?.color
        default:        return nil
        }
    }
}

// MARK: - Surrogate pair decoding

private extension String {
    /// Converts JSON-style UTF-16 surrogate pairs (e.g. `\uD83C\uDF55`) embedded as
    /// literal characters in a string back into proper Unicode scalars (e.g. 🍕).
    /// `JSONSerialization` on macOS emits surrogate pairs for emoji; iOS 26 `JSONDecoder`
    /// does not reassemble them, causing [?] tofu boxes in SwiftUI Text views.
    var decodingSurrogatePairs: String {
        // High surrogate: U+D800–U+DBFF  second nibble: 8 9 A B
        // Low  surrogate: U+DC00–U+DFFF  second nibble: C D E F
        let pattern = #"\\u([Dd][89AaBb][0-9A-Fa-f]{2})\\u([Dd][CcDdEeFf][0-9A-Fa-f]{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }

        var result = self
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let highRange = Range(match.range(at: 1), in: result),
                  let lowRange  = Range(match.range(at: 2), in: result),
                  let highCode  = UInt32(result[highRange], radix: 16),
                  let lowCode   = UInt32(result[lowRange],  radix: 16),
                  let fullRange = Range(match.range, in: result)
            else { continue }

            let codePoint = 0x10000 + (highCode - 0xD800) * 0x400 + (lowCode - 0xDC00)
            guard let scalar = Unicode.Scalar(codePoint) else { continue }
            result.replaceSubrange(fullRange, with: String(scalar))
        }

        return result
    }
}
