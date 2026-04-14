import Testing
import Foundation
@testable import AskMacCore

// MARK: - Suite 1: Error Descriptions

@Suite("TaskServiceError — Suite 1: Error Descriptions")
struct TaskServiceErrorTests {

    @Test("noContent error has correct description")
    func noContentDescription() {
        let error = TaskServiceError.noContent
        #expect(error.errorDescription == "put_artifact requires filePath or content")
    }

    @Test("fileNotFound error includes path in description")
    func fileNotFoundDescription() {
        let error = TaskServiceError.fileNotFound("/tmp/missing.pdf")
        #expect(error.errorDescription?.contains("/tmp/missing.pdf") == true)
    }

    @Test("invalidBase64 error has correct description")
    func invalidBase64Description() {
        let error = TaskServiceError.invalidBase64
        #expect(error.errorDescription?.contains("base64") == true)
    }

    @Test("contentTooLarge error includes MB size in description")
    func contentTooLargeDescription() {
        let elevenMB = 11 * 1024 * 1024
        let error = TaskServiceError.contentTooLarge(elevenMB)
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("10 MB"))
        #expect(desc.contains("11.0 MB"))
    }

    @Test("invalidPartsJSON error has correct description")
    func invalidPartsJSONDescription() {
        let error = TaskServiceError.invalidPartsJSON
        #expect(error.errorDescription?.contains("JSON") == true)
    }

    @Test("taskNotFound error includes task ID in description")
    func taskNotFoundDescription() {
        let error = TaskServiceError.taskNotFound("task-abc-123")
        #expect(error.errorDescription?.contains("task-abc-123") == true)
    }
}

// MARK: - Suite 2: Registry State Machine

@Suite("TaskRegistryActor — Suite 2: State Machine")
struct TaskRegistryActorTests {

    /// Creates a registry backed by a temp file that is cleaned up after the test.
    private func makeRegistry() -> (TaskRegistryActor, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-registry-\(UUID().uuidString).json")
        let reg = TaskRegistryActor(persistURL: url)
        return (reg, url)
    }

    @Test("New task entry starts with zero counts and sequence 1")
    func newEntryDefaults() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "My Task", status: "working")
        let entry = await reg.entry(for: "m/s/t1")
        #expect(entry?.messageCount == 0)
        #expect(entry?.artifactCount == 0)
        #expect(entry?.nextSequenceNumber == 1)
        #expect(entry?.status == "working")
    }

    @Test("Upsert updates title and status without resetting counters")
    func upsertPreservesCounters() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "Initial", status: "working")
        _ = await reg.incrementMessage(key: "m/s/t1")
        _ = await reg.incrementMessage(key: "m/s/t1")

        await reg.upsert(key: "m/s/t1", title: "Updated", status: "completed")
        let entry = await reg.entry(for: "m/s/t1")
        #expect(entry?.title == "Updated")
        #expect(entry?.status == "completed")
        #expect(entry?.messageCount == 2)  // preserved
        #expect(entry?.nextSequenceNumber == 3)  // preserved
    }

    @Test("incrementMessage returns monotonically increasing sequence numbers")
    func sequenceNumbersIncrement() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "T", status: "working")
        let seq1 = await reg.incrementMessage(key: "m/s/t1")
        let seq2 = await reg.incrementMessage(key: "m/s/t1")
        let seq3 = await reg.incrementMessage(key: "m/s/t1")

        #expect(seq1 == 1)
        #expect(seq2 == 2)
        #expect(seq3 == 3)
    }

    @Test("incrementMessage increments messageCount")
    func messageCountIncrements() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "T", status: "working")
        _ = await reg.incrementMessage(key: "m/s/t1")
        _ = await reg.incrementMessage(key: "m/s/t1")
        let entry = await reg.entry(for: "m/s/t1")
        #expect(entry?.messageCount == 2)
    }

    @Test("incrementArtifact increments artifactCount")
    func artifactCountIncrements() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "T", status: "working")
        await reg.incrementArtifact(key: "m/s/t1")
        await reg.incrementArtifact(key: "m/s/t1")
        let entry = await reg.entry(for: "m/s/t1")
        #expect(entry?.artifactCount == 2)
    }

    @Test("Entries survive save and reload from disk")
    func persistsAndLoads() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "Persistent", status: "working")
        _ = await reg.incrementMessage(key: "m/s/t1")
        _ = await reg.incrementMessage(key: "m/s/t1")
        await reg.incrementArtifact(key: "m/s/t1")
        await reg.save()

        let reg2 = TaskRegistryActor(persistURL: url)
        await reg2.load()
        let entry = await reg2.entry(for: "m/s/t1")
        #expect(entry?.title == "Persistent")
        #expect(entry?.status == "working")
        #expect(entry?.messageCount == 2)
        #expect(entry?.artifactCount == 1)
        #expect(entry?.nextSequenceNumber == 3)
    }

    @Test("Sequence numbers continue from persisted state after reload")
    func sequenceContinuesAfterReload() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "T", status: "working")
        _ = await reg.incrementMessage(key: "m/s/t1")  // seq 1
        _ = await reg.incrementMessage(key: "m/s/t1")  // seq 2
        await reg.save()

        let reg2 = TaskRegistryActor(persistURL: url)
        await reg2.load()
        let seq3 = await reg2.incrementMessage(key: "m/s/t1")
        let seq4 = await reg2.incrementMessage(key: "m/s/t1")
        #expect(seq3 == 3)
        #expect(seq4 == 4)
    }

    @Test("Multiple tasks tracked independently in the same registry")
    func multipleTasksIndependent() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        await reg.upsert(key: "m/s/t1", title: "Task 1", status: "working")
        await reg.upsert(key: "m/s/t2", title: "Task 2", status: "working")
        _ = await reg.incrementMessage(key: "m/s/t1")
        _ = await reg.incrementMessage(key: "m/s/t1")
        _ = await reg.incrementMessage(key: "m/s/t2")

        let e1 = await reg.entry(for: "m/s/t1")
        let e2 = await reg.entry(for: "m/s/t2")
        #expect(e1?.messageCount == 2)
        #expect(e2?.messageCount == 1)
        #expect(e1?.nextSequenceNumber == 3)
        #expect(e2?.nextSequenceNumber == 2)
    }

    @Test("entry returns nil for unknown key")
    func unknownKeyReturnsNil() async {
        let (reg, url) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = await reg.entry(for: "nonexistent/key")
        #expect(entry == nil)
    }
}

// MARK: - Suite 3: Artifact Content Resolution

/// Tests the pure artifact content resolution logic, isolated from CloudKit.
@Suite("Artifact Content Resolution — Suite 3: File Handling")
struct ArtifactContentResolutionTests {

    // We test the resolveArtifactContent logic by replicating it inline.
    // This suite validates the rules: filePath preferred, base64 fallback, 10 MB limit.

    private let tenMB = 10 * 1024 * 1024

    private func resolve(filePath: String?, contentBase64: String?) throws -> (URL, Int, Bool) {
        if let path = filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw TaskServiceError.fileNotFound(path)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = attrs[.size] as? Int ?? 0
            return (url, size, false)
        }
        if let base64 = contentBase64, !base64.isEmpty {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw TaskServiceError.invalidBase64
            }
            guard data.count <= tenMB else {
                throw TaskServiceError.contentTooLarge(data.count)
            }
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-artifact-\(UUID().uuidString)")
            try data.write(to: tmpURL)
            return (tmpURL, data.count, true)
        }
        throw TaskServiceError.noContent
    }

    @Test("filePath resolves to URL, shouldDelete = false")
    func filePathResolution() throws {
        // Write a known file to disk
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-input-\(UUID().uuidString).txt")
        let content = "hello world".data(using: .utf8)!
        try content.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let (url, size, shouldDelete) = try resolve(filePath: tmpURL.path, contentBase64: nil)
        #expect(url.path == tmpURL.path)
        #expect(size == content.count)
        #expect(shouldDelete == false)
    }

    @Test("filePath not found throws fileNotFound error")
    func filePathNotFound() {
        #expect(throws: TaskServiceError.fileNotFound("/nonexistent/path/file.pdf")) {
            try resolve(filePath: "/nonexistent/path/file.pdf", contentBase64: nil)
        }
    }

    @Test("Valid base64 content writes temp file, shouldDelete = true")
    func base64ContentWritesTempFile() throws {
        let original = "PDF content stub".data(using: .utf8)!
        let base64 = original.base64EncodedString()

        let (url, size, shouldDelete) = try resolve(filePath: nil, contentBase64: base64)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(shouldDelete == true)
        #expect(size == original.count)
        let readBack = try Data(contentsOf: url)
        #expect(readBack == original)
    }

    @Test("Invalid base64 string throws invalidBase64 error")
    func invalidBase64Throws() {
        #expect(throws: TaskServiceError.invalidBase64) {
            try resolve(filePath: nil, contentBase64: "!!not-valid-base64!!")
        }
    }

    @Test("Base64 content exactly at 10 MB limit is accepted")
    func exactlyTenMBAccepted() throws {
        let exactly10MB = Data(repeating: 0xAB, count: tenMB)
        let base64 = exactly10MB.base64EncodedString()
        let (url, size, shouldDelete) = try resolve(filePath: nil, contentBase64: base64)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(size == tenMB)
        #expect(shouldDelete == true)
    }

    @Test("Base64 content exceeding 10 MB throws contentTooLarge error")
    func overTenMBThrows() {
        let elevenMB = Data(repeating: 0xAB, count: tenMB + 1)
        let base64 = elevenMB.base64EncodedString()
        #expect(throws: TaskServiceError.contentTooLarge(tenMB + 1)) {
            try resolve(filePath: nil, contentBase64: base64)
        }
    }

    @Test("Neither filePath nor content throws noContent error")
    func neitherThrowsNoContent() {
        #expect(throws: TaskServiceError.noContent) {
            try resolve(filePath: nil, contentBase64: nil)
        }
    }

    @Test("Empty filePath falls through to base64")
    func emptyFilePathFallsThrough() throws {
        let original = "data".data(using: .utf8)!
        let base64 = original.base64EncodedString()
        let (_, size, shouldDelete) = try resolve(filePath: "", contentBase64: base64)
        #expect(size == original.count)
        #expect(shouldDelete == true)
    }

    @Test("filePath takes precedence over base64 when both provided")
    func filePathTakesPrecedence() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-precedence-\(UUID().uuidString).txt")
        let fileContent = "file data".data(using: .utf8)!
        try fileContent.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let base64 = "aW50ZW50aW9uYWxseSB3cm9uZw==".data(using: .utf8)!.base64EncodedString()
        let (url, _, shouldDelete) = try resolve(filePath: tmpURL.path, contentBase64: base64)
        #expect(url.path == tmpURL.path)
        #expect(shouldDelete == false)
    }
}

// MARK: - Suite 4: Registry Entry Codable

@Suite("TaskRegistryEntry — Suite 4: Codable")
struct TaskRegistryEntryCodableTests {

    @Test("Round-trips through JSON encoding and decoding")
    func jsonRoundTrip() throws {
        var entry = TaskRegistryEntry(title: "Test Task", status: "completed")
        entry.messageCount = 5
        entry.artifactCount = 2
        entry.nextSequenceNumber = 6

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TaskRegistryEntry.self, from: data)

        #expect(decoded.title == "Test Task")
        #expect(decoded.status == "completed")
        #expect(decoded.messageCount == 5)
        #expect(decoded.artifactCount == 2)
        #expect(decoded.nextSequenceNumber == 6)
    }

    @Test("Dictionary of entries round-trips through JSON")
    func dictionaryRoundTrip() throws {
        var entries: [String: TaskRegistryEntry] = [:]
        entries["machine/script/task-1"] = TaskRegistryEntry(title: "Task 1", status: "working")
        entries["machine/script/task-2"] = TaskRegistryEntry(title: "Task 2", status: "failed")

        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([String: TaskRegistryEntry].self, from: data)

        #expect(decoded["machine/script/task-1"]?.title == "Task 1")
        #expect(decoded["machine/script/task-2"]?.status == "failed")
    }
}
