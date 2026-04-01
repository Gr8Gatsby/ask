import Sparkle

/// Wraps SPUStandardUpdaterController for use in the SwiftUI app lifecycle.
///
/// Sparkle is started at app launch and checks for updates automatically
/// (at most once per day). The `checkForUpdates()` method is called when
/// the user selects "Check for Updates…" from the menu.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Mirror the updater's KVO property into the published value.
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
