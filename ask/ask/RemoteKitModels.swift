import Foundation
import CloudKit

// MARK: - Block type

enum RKBlockType: String, Codable {
    case confirmation
    case alert
    case status
    case prompt
    case infoCard = "info_card"
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
        case .confirmation, .prompt: return true
        case .alert, .status, .infoCard: return false
        }
    }

    /// Decoded confirmation payload, or nil if wrong type / bad JSON.
    var confirmationPayload: RKConfirmationPayload? {
        guard blockType == .confirmation else { return nil }
        return try? JSONDecoder().decode(RKConfirmationPayload.self,
                                        from: Data(payloadJSON.utf8))
    }

    var alertPayload: RKAlertPayload? {
        guard blockType == .alert else { return nil }
        return try? JSONDecoder().decode(RKAlertPayload.self,
                                        from: Data(payloadJSON.utf8))
    }

    var statusPayload: RKStatusPayload? {
        guard blockType == .status else { return nil }
        return try? JSONDecoder().decode(RKStatusPayload.self,
                                        from: Data(payloadJSON.utf8))
    }

    var promptPayload: RKPromptPayload? {
        guard blockType == .prompt else { return nil }
        return try? JSONDecoder().decode(RKPromptPayload.self,
                                        from: Data(payloadJSON.utf8))
    }

    var infoCardPayload: RKInfoCardPayload? {
        guard blockType == .infoCard else { return nil }
        return try? JSONDecoder().decode(RKInfoCardPayload.self,
                                        from: Data(payloadJSON.utf8))
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
