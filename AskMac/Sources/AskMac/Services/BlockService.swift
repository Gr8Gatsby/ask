import Foundation

/// Routes emit_block / clear_block tool calls from an MCPConnection to CloudKit.
/// All CloudKit writes are retried up to 3 times with exponential back-off so that
/// transient network hiccups don't silently drop blocks.
final class BlockService: @unchecked Sendable {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let scriptID: String
    private let scriptName: String
    private let scriptIcon: String?
    private let scriptIconData: String?
    private let scriptIconSVG: String?
    private let scriptType: String   // "tile" or "feed"

    init(cloudKit: CloudKitService, machineID: String, scriptID: String, scriptName: String = "", scriptIcon: String? = nil, scriptIconData: String? = nil, scriptIconSVG: String? = nil, scriptType: String = "tile") {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.scriptIcon = scriptIcon
        self.scriptIconData = scriptIconData
        self.scriptIconSVG = scriptIconSVG
        self.scriptType = scriptType
    }

    func emitBlock(blockID: String, blockType: String, payload: String, expiresAt: Date?, requiresResponse: Bool = false, showsInInbox: Bool = false) async throws {
        let record = RKBlockRecord(
            blockID: blockID,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: scriptName,
            scriptIcon: scriptIcon,
            scriptIconData: scriptIconData,
            scriptIconSVG: scriptIconSVG,
            blockType: blockType,
            payload: payload,
            createdAt: Date(),
            expiresAt: expiresAt,
            scriptType: scriptType,
            requiresResponse: requiresResponse ? 1 : 0,
            showsInInbox: showsInInbox ? 1 : 0
        )
        try await withRetry(label: "emitBlock(\(blockID))") {
            try await self.cloudKit.saveBlock(record)
        }
    }

    func clearBlock(blockID: String) async throws {
        try await withRetry(label: "clearBlock(\(blockID))") {
            try await self.cloudKit.clearBlock(blockID: blockID)
        }
    }

    /// Deletes all RKBlock records for this script. Best-effort — not retried.
    func clearAllBlocks() async throws {
        try await cloudKit.clearBlocksForScript(scriptID: scriptID, machineID: machineID)
    }

    // MARK: - Retry

    /// Retries `operation` up to `maxAttempts` times with exponential back-off (2 s, 4 s, …).
    /// Logs each failed attempt. Throws the final error if all attempts fail.
    private func withRetry<T>(
        label: String,
        maxAttempts: Int = 3,
        operation: () async throws -> T
    ) async throws -> T {
        var delay: UInt64 = 2_000_000_000
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    print("[BlockService:\(scriptID)] \(label) attempt \(attempt)/\(maxAttempts) failed: \(error) — retrying in \(delay / 1_000_000_000)s")
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                } else {
                    print("[BlockService:\(scriptID)] \(label) failed after \(maxAttempts) attempts: \(error)")
                }
            }
        }
        throw lastError!
    }
}
