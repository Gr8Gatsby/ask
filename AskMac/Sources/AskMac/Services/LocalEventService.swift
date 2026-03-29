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
            // The DispatchSource can fire before the writer finishes — retry once if empty.
            var data = (try? Data(contentsOf: file)) ?? Data()
            if data.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                data = (try? Data(contentsOf: file)) ?? Data()
            }
            guard !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("[LocalEventService] JSON parse failed for \(file.lastPathComponent) (\(data.count) bytes)")
                if !data.isEmpty { try? fm.removeItem(at: file) }
                continue
            }

            let eventID = json["id"] as? String ?? UUID().uuidString
            let title = json["title"] as? String ?? "Claude Code"
            let message = json["message"] as? String ?? json["content"] as? String ?? ""
            let source = json["source"] as? String ?? "claude-code"
            let options = (json["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            let sessionID = json["sessionID"] as? String

            print("[LocalEventService] Processing: title=\(title) options=\(options) machineID=\(machineID)")

            // Upsert session record when event is tied to a Claude Code session
            if let sessionID = sessionID, !sessionID.isEmpty {
                let sessionStatus = options.isEmpty ? "active" : "waiting"
                try? await cloudKit.upsertSession(
                    sessionID: sessionID,
                    machineID: machineID,
                    title: title,
                    status: sessionStatus
                )
            }

            do {
                try await cloudKit.saveEvent(
                    eventID: eventID,
                    machineID: machineID,
                    title: title,
                    body: message,
                    source: source,
                    options: options,
                    sessionID: sessionID
                )
                print("[LocalEventService] Saved OK: \(title) options=\(options)")
                try fm.removeItem(at: file)
            } catch {
                print("[LocalEventService] Save FAILED: \(error)")
            }
        }
    }
}
