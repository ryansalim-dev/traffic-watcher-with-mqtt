#if os(macOS)
import AppCore
import Combine
import Sparkle
import SwiftUI

/// Sparkle's updater, started only inside a packaged app that names an appcast (`SUFeedURL`) and a
/// signing key (`SUPublicEDKey`). `swift run` builds have neither, so the menu item is disabled there.
///
/// Pro covers releases from the 12 months after purchase. Installing a later one would turn Pro off,
/// so a licensed Mac is only offered releases published inside its update window.
@MainActor
final class Updates: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    private let window = UpdateWindow()
    private var observation: AnyCancellable?

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let configured = bundle.bundleURL.pathExtension == "app"
            && (info["SUFeedURL"] as? String).map { !$0.isEmpty } == true
            && (info["SUPublicEDKey"] as? String).map { !$0.isEmpty } == true
        guard configured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: window, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    var isAvailable: Bool { controller != nil }

    /// The license's update window; call when the license loads or changes.
    func follow(_ license: LicenseManager) {
        window.coveredUntil = license.updatesCoveredUntil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Picks the newest release this Mac's license covers. Sparkle may ask from any thread.
private final class UpdateWindow: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _coveredUntil: Date?

    var coveredUntil: Date? {
        get { lock.withLock { _coveredUntil } }
        set { lock.withLock { _coveredUntil = newValue } }
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let coveredUntil else { return nil } // no license window: Sparkle's own choice
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let comparator = SUStandardVersionComparator()
        let covered = appcast.items.filter { item in
            item.channel == nil
                && item.minimumOperatingSystemVersionIsOK && item.maximumOperatingSystemVersionIsOK
                && LicenseManager.updateIsCovered(published: item.date, coveredUntil: coveredUntil)
                && comparator.compareVersion(current, toVersion: item.versionString) == .orderedAscending
        }
        let best = covered.max { comparator.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending }
        return best ?? SUAppcastItem.empty()
    }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: Updates

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
                .help(updates.isAvailable ? "" : "Updates are available in the downloaded app, not in development builds.")
        }
    }
}
#endif
