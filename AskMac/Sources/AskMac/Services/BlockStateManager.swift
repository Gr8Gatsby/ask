import Foundation
import Observation

/// Owns the live block state for all running scripts.
/// ScriptManager delegates all block reads and writes here.
@Observable
final class BlockStateManager {
    private(set) var blocks: [String: [String: LiveBlock]] = [:]

    /// Upserts a block. Returns `true` if this is a new blockID (not an update).
    func upsert(_ block: LiveBlock, forScript scriptID: String) -> Bool {
        let isNew = blocks[scriptID]?[block.id] == nil
        blocks[scriptID, default: [:]][block.id] = block
        return isNew
    }

    func clear(blockID: String, fromScript scriptID: String) {
        blocks[scriptID]?.removeValue(forKey: blockID)
    }

    func clearAll(forScript scriptID: String) {
        blocks.removeValue(forKey: scriptID)
    }

    func scriptID(forBlockID blockID: String) -> String? {
        blocks.first(where: { $0.value[blockID] != nil })?.key
    }
}
