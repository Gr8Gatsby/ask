import Sparkle
import Combine
import Observation
import OSLog

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "AppUpdater")

@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    /// Last error reported by Sparkle, if any. Captured via SPUUpdaterDelegate
    /// so Diagnostics / UI can show the actual failure reason instead of the
    /// generic "An error occurred while running the updater" message.
    private(set) var lastUpdateError: String? = nil

    private let updaterController: SPUStandardUpdaterController
    private let delegateBox = UpdaterDelegateBox()
    private var cancellable: AnyCancellable?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegateBox,
            userDriverDelegate: nil
        )
        delegateBox.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastUpdateError = message
                logger.error("Sparkle: \(message, privacy: .public)")
            }
        }
        cancellable = updaterController.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        lastUpdateError = nil   // clear before retry so stale text doesn't linger
        updaterController.checkForUpdates(nil)
    }
}

/// Captures Sparkle errors and forwards them. NSObject because Sparkle's
/// delegate protocol requires ObjC runtime visibility.
private final class UpdaterDelegateBox: NSObject, SPUUpdaterDelegate {
    var onError: ((String) -> Void)?

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        onError?(formatError(error, context: "aborted"))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        onError?(formatError(error, context: "download failed (v\(item.versionString))"))
    }

    private func formatError(_ error: Error, context: String) -> String {
        let ns = error as NSError
        var parts = [context, "\(ns.domain) #\(ns.code)"]
        if !ns.localizedDescription.isEmpty { parts.append(ns.localizedDescription) }
        if let reason = ns.localizedFailureReason { parts.append("reason: \(reason)") }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) #\(underlying.code) — \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " · ")
    }
}
