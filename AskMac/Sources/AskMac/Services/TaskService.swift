import Foundation
import CloudKit
import OSLog
#if canImport(AskMacCore)
import AskMacCore
#endif

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "TaskService")

/// Manages the A2A task protocol: open_task, append_message, put_artifact.
///
/// Maintains a local registry of task state (sequence numbers, counts) that
/// persists to disk so tasks survive daemon restarts. All CloudKit writes are
/// delegated to CloudKitService.
final class TaskService: @unchecked Sendable {

    // MARK: - Dependencies

    private let registry = TaskRegistryActor()
    private let cloudKit: CloudKitService
    private let machineID: String
    private let scriptID: String
    private let scriptName: String
    private let scriptIcon: String?
    private let scriptIconData: String?

    init(
        cloudKit: CloudKitService,
        machineID: String,
        scriptID: String,
        scriptName: String,
        scriptIcon: String?,
        scriptIconData: String?
    ) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.scriptIcon = scriptIcon
        self.scriptIconData = scriptIconData
    }

    func loadRegistry() async {
        await registry.load()
        let count = await registry.entries.count
        logger.info("TaskRegistry loaded \(count) tasks from disk")
    }

    // MARK: - open_task

    func openTask(taskID: String, title: String, status: String) async throws {
        let key = registryKey(taskID)
        let entry = await registry.upsert(key: key, title: title, status: status)

        let taskRecord = AskTaskRecord(
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: scriptName,
            scriptIcon: scriptIcon,
            scriptIconData: scriptIconData,
            title: title,
            status: status,
            lastActivityAt: Date(),
            messageCount: entry.messageCount,
            artifactCount: entry.artifactCount
        )
        try await cloudKit.saveTask(taskRecord)
        logger.info("open_task — taskID: \(taskID) status: \(status)")
    }

    // MARK: - append_message

    func appendMessage(taskID: String, role: String, parts: [[String: Any]]) async throws {
        guard let partsJSON = try? JSONSerialization.data(withJSONObject: parts),
              let partsString = String(data: partsJSON, encoding: .utf8)
        else { throw TaskServiceError.invalidPartsJSON }

        let key = registryKey(taskID)
        let seq = await registry.incrementMessage(key: key)
        let entry = await registry.entry(for: key)

        let messageRecord = AskTaskMessageRecord(
            messageID: UUID().uuidString,
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            role: role,
            partsJSON: partsString,
            timestamp: Date(),
            sequenceNumber: seq
        )
        try await cloudKit.saveTaskMessage(messageRecord)

        // Update task lastActivityAt + messageCount
        if let e = entry {
            let taskRecord = AskTaskRecord(
                taskID: taskID,
                machineID: machineID,
                scriptID: scriptID,
                scriptName: scriptName,
                scriptIcon: scriptIcon,
                scriptIconData: scriptIconData,
                title: e.title,
                status: e.status,
                lastActivityAt: Date(),
                messageCount: e.messageCount,
                artifactCount: e.artifactCount
            )
            try await cloudKit.saveTask(taskRecord)
        }
        logger.info("append_message — taskID: \(taskID) role: \(role) seq: \(seq)")
    }

    // MARK: - put_artifact

    static let tenMB = 10 * 1024 * 1024  // 10 MB in bytes

    func putArtifact(
        taskID: String,
        artifactID: String,
        filename: String,
        mimeType: String,
        description: String?,
        filePath: String?,
        contentBase64: String?
    ) async throws {
        // Resolve content to a local URL
        let (localURL, sizeBytes, shouldDelete) = try resolveArtifactContent(
            filePath: filePath,
            contentBase64: contentBase64
        )

        defer {
            if shouldDelete {
                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let key = registryKey(taskID)
        await registry.incrementArtifact(key: key)
        let entry = await registry.entry(for: key)

        let artifactRecord = AskArtifactRecord(
            artifactID: artifactID,
            taskID: taskID,
            machineID: machineID,
            scriptID: scriptID,
            filename: filename,
            mimeType: mimeType,
            artifactDescription: description,
            sizeBytes: sizeBytes,
            contentURL: localURL,
            updatedAt: Date()
        )
        try await cloudKit.saveArtifact(artifactRecord)

        // Update task lastActivityAt + artifactCount
        if let e = entry {
            let taskRecord = AskTaskRecord(
                taskID: taskID,
                machineID: machineID,
                scriptID: scriptID,
                scriptName: scriptName,
                scriptIcon: scriptIcon,
                scriptIconData: scriptIconData,
                title: e.title,
                status: e.status,
                lastActivityAt: Date(),
                messageCount: e.messageCount,
                artifactCount: e.artifactCount
            )
            try await cloudKit.saveTask(taskRecord)
        }
        logger.info("put_artifact — taskID: \(taskID) artifactID: \(artifactID) size: \(sizeBytes) bytes")
    }

    /// Resolves filePath or base64 content to a local file URL.
    /// Returns (url, sizeBytes, shouldDeleteAfterUse).
    func resolveArtifactContent(
        filePath: String?,
        contentBase64: String?
    ) throws -> (URL, Int, Bool) {
        if let path = filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw TaskServiceError.fileNotFound(path)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = attrs[.size] as? Int ?? 0
            return (url, size, false)  // don't delete — script owns this file
        }

        if let base64 = contentBase64, !base64.isEmpty {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw TaskServiceError.invalidBase64
            }
            guard data.count <= Self.tenMB else {
                throw TaskServiceError.contentTooLarge(data.count)
            }
            // Write to a temp file so we can create a CKAsset
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ask-artifact-\(UUID().uuidString)")
            try data.write(to: tmpURL)
            return (tmpURL, data.count, true)  // delete after use
        }

        throw TaskServiceError.noContent
    }

    // MARK: - Helpers

    func taskExists(_ taskID: String) async -> Bool {
        await registry.entry(for: registryKey(taskID)) != nil
    }

    private func registryKey(_ taskID: String) -> String {
        "\(machineID)/\(scriptID)/\(taskID)"
    }
}
