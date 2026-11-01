#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// Sparkle's updater, started only inside a packaged app that names an appcast (`SUFeedURL`) and a
/// signing key (`SUPublicEDKey`). `swift run` builds have neither, so the menu item is disabled there.
@MainActor
final class Updates: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
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
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
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
