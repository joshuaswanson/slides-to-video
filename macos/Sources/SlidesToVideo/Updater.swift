import Foundation
import Sparkle

/// Sparkle updates, active only in the bundled app, where Info.plist has the feed and key.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
