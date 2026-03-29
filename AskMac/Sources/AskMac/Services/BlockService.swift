import Foundation

/// Routes emit_block / clear_block tool calls from an MCPConnection to CloudKit.
final class BlockService: @unchecked Sendable {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let scriptID: String

    init(cloudKit: CloudKitService, machineID: String, scriptID: String) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.scriptID = scriptID
    }

    func emitBlock(blockID: String, blockType: String, payload: String, expiresAt: Date?) async throws {
        let record = RKBlockRecord(
            blockID: blockID,
            machineID: machineID,
            scriptID: scriptID,
            blockType: blockType,
            payload: payload,
            createdAt: Date(),
            expiresAt: expiresAt
        )
        try await cloudKit.saveBlock(record)
    }

    func clearBlock(blockID: String) async throws {
        try await cloudKit.clearBlock(blockID: blockID)
    }

    /// Deletes all RKBlock records for this script. Called when the script reconnects.
    func clearAllBlocks() async throws {
        try await cloudKit.clearBlocksForScript(scriptID: scriptID, machineID: machineID)
    }
}
