import Foundation
import CloudKit

// MARK: - Block type

enum RKBlockType: String, Codable {
    case confirmation
    case alert
    case status
    case prompt
    case infoCard = "info_card"
    case chatPrompt = "chat_prompt"
}

// MARK: - Block payloads

struct RKConfirmationPayload: Codable {
    let title: String
    let body: String
    let options: [String]
}

struct RKAlertPayload: Codable {
    let title: String
    let body: String
    let icon: String?
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
}

struct RKChatPromptPayload: Codable {
    let title: String
    let context: String?       // Claude's last message shown above the input
    let placeholder: String?
}

struct RKInfoCardPayload: Codable {
    struct Pair: Codable {
        let key: String
        let value: String
    }
    let title: String
    let pairs: [Pair]
}

// MARK: - RKBlock model

struct RKBlock: Identifiable {
    let id: String          // blockID (also CKRecord name)
    let machineID: String
    let scriptID: String
    let blockType: RKBlockType
    let payloadJSON: String
    let createdAt: Date
    let expiresAt: Date?

    var requiresResponse: Bool {
        switch blockType {
        case .confirmation, .prompt, .chatPrompt: return true
        case .alert, .status, .infoCard: return false
        }
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

    /// payloadJSON with UTF-16 surrogate pairs decoded to real Unicode scalars, as UTF-8 Data.
    /// `JSONSerialization` on macOS escapes emoji (U+10000…) as `\uD800\uDC00`-style pairs;
    /// iOS 26 `JSONDecoder` doesn't reassemble them. Pre-decoding here fixes rendering.
    private var payloadData: Data {
        Data(payloadJSON.decodingSurrogatePairs.utf8)
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
        self.blockType = blockType
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.expiresAt = record[CKSchema.RKBlock.expiresAt] as? Date
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
