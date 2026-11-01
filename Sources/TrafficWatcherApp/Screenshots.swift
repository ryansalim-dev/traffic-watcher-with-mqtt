#if os(macOS)
import AppCore
import AppKit
import CaptureStore
import Licensing
import SwiftUI

/// `TrafficWatcher --screenshots <dir>` fills a throwaway store with sample traffic, opens the
/// main views in a few states and writes PNGs of them. CI runs it so the UI can be reviewed
/// without building the app.
@MainActor
enum Screenshots {
    static func run(into directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await capture(into: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Screenshots failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func capture(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TrafficWatcherScreenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let storage = CertificateStorage(directory: scratch)
        let store = try CaptureStore(path: scratch.appendingPathComponent("captures.sqlite").path, sessionName: "Screenshots")
        var configuration = EngineConfiguration()
        configuration.bypassHosts = ["*.apple.com"]
        configuration.forwarders = [
            ForwarderConfiguration(brokerHost: "broker.example.com", listenPort: 18830),
            ForwarderConfiguration(brokerHost: "iot.example.net", listenPort: 18831, useTLS: true),
        ]
        let model = CaptureViewModel(store: store, engine: CaptureEngine(authority: try storage.loadOrCreate(), threads: 1),
                                     configuration: configuration)
        await model.startCapture()
        for event in SampleTraffic.events() { model.ingest(event) }

        // License states for the License tab: no key yet, and an active Pro license checked today.
        let licenseConfiguration = LicenseConfiguration(product: .init(storeID: 1, productIDs: [1]),
                                                        purchaseURL: URL(string: "https://example.com/pro"), releaseDate: nil)
        let freeLicense = LicenseManager(configuration: licenseConfiguration,
                                         storage: FileLicenseStorage(url: scratch.appendingPathComponent("free.json")))
        let proStorage = FileLicenseStorage(url: scratch.appendingPathComponent("pro.json"))
        try proStorage.save(StoredLicense(key: "3F2A9C1D-77B0-4E5A-9D21-8C4E6B1F5A07", instanceID: "screenshot", status: .active,
                                          customerName: "Ryan", customerEmail: "ryan@example.com",
                                          purchasedAt: Date().addingTimeInterval(-40 * 86_400), lastValidatedAt: Date().addingTimeInterval(-3_600)))
        let proLicense = LicenseManager(configuration: licenseConfiguration, storage: proStorage)

        func row(_ match: (TrafficRow) -> Bool) -> TrafficRow.ID? { model.rows.first(where: match)?.id }
        let size = NSSize(width: 1440, height: 860)

        model.section = .all
        model.selection = row { $0.summary.hasPrefix("GET https://api.example.com/v2/devices") }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "01-timeline-http", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "02-timeline-http-dark", into: directory)

        model.section = .mqtt
        model.selection = row { $0.kind == .mqtt && $0.summary.contains("home/kitchen/temperature") }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "03-mqtt-packets", into: directory)

        model.selection = row { $0.badge == "CONNECT" }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "04-mqtt-connect-dark", into: directory)

        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, mqttMode: .topics, selectedTopic: "home/kitchen/temperature"),
                        size: size, dark: false, name: "05-mqtt-topic-tree", into: directory)

        model.section = .webSocket
        model.selection = row { $0.kind == .webSocket && $0.size > 50 }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "06-websocket", into: directory)

        model.section = .issues
        model.selection = row { $0.kind == .tls }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "07-issues-pinned-host", into: directory)

        model.section = .all
        model.searchText = "kitchen"
        model.selection = model.visibleRows.first { $0.kind == .mqtt }?.id
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "08-search", into: directory)
        model.searchText = ""

        let settingsSize = NSSize(width: 560, height: 560)
        let tabs: [(SettingsView.Tab, String)] = [(.proxy, "09-settings-proxy"), (.mqtt, "10-settings-mqtt"), (.certificate, "11-settings-certificate")]
        for (tab, name) in tabs {
            try await shoot(SettingsView(model: model, certificates: storage, license: freeLicense, tab: tab),
                            size: settingsSize, dark: false, name: name, into: directory)
        }
        try await shoot(SettingsView(model: model, certificates: storage, license: freeLicense, tab: .license),
                        size: settingsSize, dark: false, name: "12-settings-license-free", into: directory)
        try await shoot(SettingsView(model: model, certificates: storage, license: proLicense, tab: .license),
                        size: settingsSize, dark: true, name: "13-settings-license-pro-dark", into: directory)
        await model.stopCapture()
    }

    private static func shoot<V: View>(_ view: V, size: NSSize, dark: Bool, name: String, into directory: URL) async throws {
        let window = UnconstrainedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = name.contains("settings") ? "Settings" : "Traffic Watcher"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = hosting
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .seconds(2))

        let url = directory.appendingPathComponent("\(name).png")
        if !screencapture(window: window, to: url) {
            try renderOffscreen(window: window, to: url)
        }
        print("Wrote \(url.path)")
        window.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Captures the window as the window server draws it, including the toolbar and shadow-free frame.
    private static func screencapture(window: NSWindow, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) > 10_000 else { return false }
        return true
    }

    /// Fallback when screen recording isn't permitted: asks AppKit to draw the window's frame view.
    private static func renderOffscreen(window: NSWindow, to url: URL) throws {
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
/// The CI runner's screen is small; let windows extend past it so shots are taken at full size.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif
