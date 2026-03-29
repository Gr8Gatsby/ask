import Foundation
import Observation

/// Polls CloudKit for AskResponse records addressed to this machine.
/// When a response arrives it writes ~/.ask/responses/<eventID>.json
/// so that waiting ask-prompt.sh processes can read the result.
@Observable
final class ResponseWatcherService {
    private let cloudKit: CloudKitService
    private let machineID: String
    private let responsesDir: URL
    private var pollTask: Task<Void, Never>?

    /// Last time the iPhone sent a response. Shown in menu bar.
    private(set) var lastResponseAt: Date?

    init(cloudKit: CloudKitService, machineID: String) {
        self.cloudKit = cloudKit
        self.machineID = machineID
        self.responsesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask/responses")
        try? FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func poll() async {
        guard let responses = try? await cloudKit.drainResponses(machineID: machineID) else { return }
        for response in responses {
            lastResponseAt = Date()
            deliver(eventID: response.eventID, choice: response.choice)
        }
    }

    private func deliver(eventID: String, choice: String) {
        let file = responsesDir.appendingPathComponent("\(eventID).json")
        let json = "{\"choice\":\(encodeString(choice))}\n"
        try? json.write(to: file, atomically: true, encoding: .utf8)
    }

    private func encodeString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
