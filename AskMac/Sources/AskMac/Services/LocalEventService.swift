import Foundation
import Observation

/// Watches ~/.ask/incoming/ for JSON files dropped by Claude Code hooks.
/// Each file is a notification event — forwarded to CloudKit so the iOS app
/// receives a push notification.
@Observable
final class LocalEventService {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let incomingDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    init(cloudKit: CloudKitService, machineID: String) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.incomingDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask/incoming")
        ensureDirectory()
    }

    func start() {
        dirFD = open(incomingDir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source?.setEventHandler { [weak self] in
            Task { await self?.processIncoming() }
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        source?.resume()

        // Process any files left over from a previous run
        Task { await processIncoming() }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
    }

    private func processIncoming() async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: incomingDir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                try? fm.removeItem(at: file)
                continue
            }

            let eventID = json["id"] as? String ?? UUID().uuidString
            let title = json["title"] as? String ?? "Claude Code"
            let message = json["message"] as? String ?? json["content"] as? String ?? ""
            let source = json["source"] as? String ?? "claude-code"
            let options = json["options"] as? [String] ?? []

            do {
                try await cloudKit.saveEvent(
                    eventID: eventID,
                    machineID: machineID,
                    title: title,
                    body: message,
                    source: source,
                    options: options
                )
                try fm.removeItem(at: file)
            } catch {
                print("[LocalEventService] Failed to forward event: \(error)")
            }
        }
    }
}
