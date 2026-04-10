import SwiftData
import Foundation
import Observation

// MARK: - TaskHistoryStore

/// App-level service that owns all TaskRecord, TaskMessage, and ArtifactRecord SwiftData writes.
///
/// Views read from the ModelContainer directly via @Query. This store is responsible for:
/// - Polling CloudKit on refresh and writing new/updated records to SwiftData.
/// - Tracking which machineIDs to poll (updated whenever HomeView fetches machines).
/// - Downloading artifact content on demand and marking ArtifactRecord.isDownloaded.
@Observable
final class TaskHistoryStore {

    // MARK: - Public state

    /// True while a CloudKit fetch is in-flight.
    private(set) var isRefreshing = false
    /// The most recent refresh error, if any.
    private(set) var lastError: Error?

    // MARK: - Dependencies

    private let cloudKit: iOSCloudKitService
    private let modelContext: ModelContext

    // MARK: - Init

    init(cloudKit: iOSCloudKitService, modelContext: ModelContext) {
        self.cloudKit = cloudKit
        self.modelContext = modelContext
    }

    // MARK: - Refresh

    /// Fetches tasks (and their messages/artifacts) for all known machines from CloudKit.
    /// Upserts new records; existing records are updated in place by recordName.
    func refresh(machineIDs: [String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        for machineID in machineIDs {
            do {
                try await refreshTasks(machineID: machineID)
            } catch {
                lastError = error
            }
        }
    }

    private func refreshTasks(machineID: String) async throws {
        let remoteTasks = try await cloudKit.fetchTasks(machineID: machineID)
        for task in remoteTasks {
            upsertTask(task)
        }
        // Fetch messages + artifacts for any task updated in the last 7 days
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recentTasks = remoteTasks.filter { $0.lastActivityAt > cutoff }
        for task in recentTasks {
            let messages = try await cloudKit.fetchMessages(taskID: task.taskID, machineID: machineID)
            for msg in messages { upsertMessage(msg) }

            let artifacts = try await cloudKit.fetchArtifacts(taskID: task.taskID, machineID: machineID)
            for art in artifacts { upsertArtifact(art) }
        }
        try modelContext.save()
    }

    // MARK: - Artifact download

    /// Downloads artifact content to the local cache directory. No-op if already downloaded.
    func downloadArtifact(_ artifact: ArtifactRecord) async {
        guard !artifact.isDownloaded else { return }
        do {
            _ = try await cloudKit.downloadArtifactContent(
                recordName: artifact.recordName,
                destinationURL: artifact.localCacheURL
            )
            artifact.isDownloaded = true
            try modelContext.save()
        } catch {
            lastError = error
        }
    }

    // MARK: - Clear history

    /// Deletes all tasks, messages, and artifacts for a specific machine + script pair.
    func clearHistory(machineID: String, scriptID: String) throws {
        let taskDescriptor = FetchDescriptor<TaskRecord>(
            predicate: #Predicate { $0.machineID == machineID && $0.scriptID == scriptID }
        )
        let tasks = try modelContext.fetch(taskDescriptor)
        for task in tasks {
            let taskID = task.taskID
            let msgDescriptor = FetchDescriptor<TaskMessage>(
                predicate: #Predicate { $0.taskID == taskID && $0.machineID == machineID }
            )
            let msgs = try modelContext.fetch(msgDescriptor)
            msgs.forEach { modelContext.delete($0) }

            let artDescriptor = FetchDescriptor<ArtifactRecord>(
                predicate: #Predicate { $0.taskID == taskID && $0.machineID == machineID }
            )
            let arts = try modelContext.fetch(artDescriptor)
            arts.forEach { art in
                try? FileManager.default.removeItem(at: art.localCacheURL)
                modelContext.delete(art)
            }
            modelContext.delete(task)
        }
        try modelContext.save()
    }

    /// Deletes all stored task history across all machines.
    func clearAllHistory() throws {
        try modelContext.delete(model: TaskRecord.self)
        try modelContext.delete(model: TaskMessage.self)
        // Remove cached artifact files
        let artDescriptor = FetchDescriptor<ArtifactRecord>()
        if let arts = try? modelContext.fetch(artDescriptor) {
            arts.forEach { try? FileManager.default.removeItem(at: $0.localCacheURL) }
        }
        try modelContext.delete(model: ArtifactRecord.self)
        try modelContext.save()
    }

    // MARK: - Private upsert helpers

    private func upsertTask(_ incoming: TaskRecord) {
        let recordName = incoming.recordName
        let descriptor = FetchDescriptor<TaskRecord>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = incoming.title
            existing.status = incoming.status
            existing.lastActivityAt = incoming.lastActivityAt
            existing.messageCount = incoming.messageCount
            existing.artifactCount = incoming.artifactCount
            existing.scriptName = incoming.scriptName
            existing.scriptIcon = incoming.scriptIcon
            existing.scriptIconData = incoming.scriptIconData
        } else {
            modelContext.insert(incoming)
        }
    }

    private func upsertMessage(_ incoming: TaskMessage) {
        let messageID = incoming.messageID
        let descriptor = FetchDescriptor<TaskMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        guard (try? modelContext.fetch(descriptor).first) == nil else { return }
        modelContext.insert(incoming)
    }

    private func upsertArtifact(_ incoming: ArtifactRecord) {
        let recordName = incoming.recordName
        let descriptor = FetchDescriptor<ArtifactRecord>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            // Preserve isDownloaded if the artifact content hasn't changed
            if existing.updatedAt < incoming.updatedAt {
                existing.updatedAt = incoming.updatedAt
                existing.sizeBytes = incoming.sizeBytes
                existing.filename = incoming.filename
                existing.mimeType = incoming.mimeType
                existing.artifactDescription = incoming.artifactDescription
                existing.isDownloaded = false  // content may have changed
            }
        } else {
            modelContext.insert(incoming)
        }
    }
}
