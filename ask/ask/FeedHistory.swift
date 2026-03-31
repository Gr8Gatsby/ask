import SwiftData
import Foundation

// MARK: - FeedHistoryEntry

/// Locally persisted record of a feed block — survives CloudKit TTL expiry.
@Model
final class FeedHistoryEntry {
    var blockID: String
    var scriptID: String
    var scriptName: String?
    var scriptIcon: String?
    var scriptIconData: String?
    var blockTypeRaw: String
    var headline: String
    var statusColor: String?
    var payloadJSON: String
    var createdAt: Date

    init(
        blockID: String,
        scriptID: String,
        scriptName: String?,
        scriptIcon: String?,
        scriptIconData: String?,
        blockTypeRaw: String,
        headline: String,
        statusColor: String?,
        payloadJSON: String,
        createdAt: Date
    ) {
        self.blockID = blockID
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.scriptIcon = scriptIcon
        self.scriptIconData = scriptIconData
        self.blockTypeRaw = blockTypeRaw
        self.headline = headline
        self.statusColor = statusColor
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}
