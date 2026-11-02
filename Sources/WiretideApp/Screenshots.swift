#if os(macOS)
import AppCore
import AppKit
import CaptureStore
import ImageIO
import Licensing
import ProxyCore
import SwiftUI

/// `Wiretide --screenshots <dir>` fills a throwaway store with sample traffic, opens the
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
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WiretideScreenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let storage = CertificateStorage(directory: scratch)
        let store = try CaptureStore(path: scratch.appendingPathComponent("captures.sqlite").path, sessionName: "Screenshots")
        var configuration = EngineConfiguration()
        configuration.bypassHosts = ["*.apple.com"]
        configuration.setSystemProxy = true
        configuration.forwarders = [
            ForwarderConfiguration(brokerHost: "broker.example.com", listenPort: 18830),
            ForwarderConfiguration(brokerHost: "iot.example.net", listenPort: 18831, useTLS: true),
        ]
        let model = CaptureViewModel(store: store, engine: CaptureEngine(authority: try storage.loadOrCreate(), threads: 1),
                                     configuration: configuration)
        let size = NSSize(width: 1440, height: 860)
        UserDefaults.standard.set(RowDensity.regular.rawValue, forKey: RowDensity.storageKey)
        let firstLaunchLicense = LicenseManager(configuration: LicenseConfiguration(product: .init(storeID: 1, productIDs: [1]),
                                                                                    purchaseURL: nil, releaseDate: nil),
                                                storage: FileLicenseStorage(url: scratch.appendingPathComponent("first.json")))
        try await shoot(ContentView(model: model, certificates: storage, license: firstLaunchLicense), size: size, dark: false,
                        name: "00-first-launch", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: firstLaunchLicense), size: size, dark: true,
                        name: "00-first-launch-dark", into: directory)

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
        let helper = SystemProxyHelper()

        func row(_ match: (TrafficRow) -> Bool) -> TrafficRow.ID? { model.rows.first(where: match)?.id }

        model.section = .all
        model.selection = row { $0.summary.hasPrefix("GET https://api.example.com/v2/devices") }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "01-timeline-http", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "02-timeline-http-dark", into: directory)

        model.section = .mqtt
        model.selection = row { $0.kind == .mqtt && $0.summary.contains("home/kitchen/temperature") }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: false, name: "03-mqtt-packets", into: directory)

        model.selection = row { $0.badge == "CONNECT" }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "04-mqtt-connect-dark", into: directory)

        for event in SampleTraffic.temperatureReadings() { model.ingest(event) }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, mqttMode: .topics, selectedTopic: "home/kitchen/temperature"),
                        size: size, dark: false, name: "05-mqtt-topic-tree", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, mqttMode: .topics, selectedTopic: "home/kitchen/temperature"),
                        size: size, dark: true, name: "05b-mqtt-topics-dark", into: directory)

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

        // Quick filter and host filter together, then the compact density.
        model.quickFilter = .errors
        model.hostFilter = "api.example.com"
        model.selection = row { $0.badge == "503" }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "08b-filters-dark", into: directory)
        model.quickFilter = .all
        model.hostFilter = nil
        UserDefaults.standard.set(RowDensity.compact.rawValue, forKey: RowDensity.storageKey)
        model.selection = row { $0.summary.hasPrefix("GET https://api.example.com/v2/devices") }
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense), size: size, dark: true, name: "08c-compact-dark", into: directory)
        UserDefaults.standard.set(RowDensity.regular.rawValue, forKey: RowDensity.storageKey)

        let settingsSize = NSSize(width: 560, height: 560)
        let tabs: [(SettingsView.Tab, String)] = [(.proxy, "09-settings-proxy"), (.mqtt, "10-settings-mqtt"), (.certificate, "11-settings-certificate")]
        for (tab, name) in tabs {
            try await shoot(SettingsView(model: model, certificates: storage, license: freeLicense, helper: helper, tab: tab),
                            size: settingsSize, dark: false, name: name, into: directory)
        }
        try await shoot(SettingsView(model: model, certificates: storage, license: freeLicense, helper: helper, tab: .license),
                        size: settingsSize, dark: false, name: "12-settings-license-free", into: directory)
        try await shoot(SettingsView(model: model, certificates: storage, license: proLicense, helper: helper, tab: .license),
                        size: settingsSize, dark: true, name: "13-settings-license-pro-dark", into: directory)

        try await shootProTools(model: model, storage: storage, freeLicense: freeLicense, proLicense: proLicense, helper: helper, into: directory)
        await model.stopCapture()
    }

    /// Breakpoints and MQTT publish/replay, with a Pro license (and one locked, free-tier view).
    private static func shootProTools(model: CaptureViewModel, storage: CertificateStorage, freeLicense: LicenseManager,
                                      proLicense: LicenseManager, helper: SystemProxyHelper, into directory: URL) async throws {
        let size = NSSize(width: 1440, height: 860)
        model.apply(proLicense.entitlement)
        let center = model.breakpoints
        center.rules = [
            BreakpointRule(pattern: "api.example.com/v2/devices*", method: "GET"),
            BreakpointRule(pattern: "https://api.example.com/v2/login", method: "POST", stages: .response),
            BreakpointRule(isEnabled: false, pattern: "*.example.net/*", stages: .request),
        ]

        // A finished exchange that went through a breakpoint, so the inspector shows the note.
        let edited = HTTPExchange(
            startedAt: Date(), duration: 4.2, method: "PATCH", url: "https://api.example.com/v2/devices/42",
            requestHeaders: [CapturedHeader(name: "Content-Type", value: "application/json")],
            requestBody: Array(#"{"name":"Kitchen lamp","on":false}"#.utf8), statusCode: 200,
            responseHeaders: [CapturedHeader(name: "Content-Type", value: "application/json")],
            responseBody: Array(#"{"id":42,"name":"Kitchen lamp","on":false,"firmware":"2.4.1"}"#.utf8),
            breakpoint: [.request, .response])
        model.ingest(.httpExchange(edited))
        model.section = .http
        model.selection = model.rows.last?.id

        // Two requests waiting at breakpoints.
        let request = HTTPRequestDraft(
            method: "GET", url: "https://api.example.com/v2/devices?room=kitchen&page=1",
            headers: [CapturedHeader(name: "Host", value: "api.example.com"),
                      CapturedHeader(name: "Accept", value: "application/json"),
                      CapturedHeader(name: "Authorization", value: "Bearer eyJhbGciOiJIUzI1NiJ9.demo"),
                      CapturedHeader(name: "User-Agent", value: "HomeHub/3.2 (iPhone; iOS 18.1)")],
            body: [])
        let login = HTTPRequestDraft(method: "POST", url: "https://api.example.com/v2/login",
                                     headers: [CapturedHeader(name: "Content-Type", value: "application/json")],
                                     body: Array(#"{"email":"ryan@example.com","password":"••••••"}"#.utf8))
        let response = HTTPResponseDraft(
            statusCode: 200,
            headers: [CapturedHeader(name: "Content-Type", value: "application/json; charset=utf-8"),
                      CapturedHeader(name: "Cache-Control", value: "no-store"),
                      CapturedHeader(name: "Set-Cookie", value: "session=4f1c…; HttpOnly; Secure")],
            body: Array("""
            {
              "token": "eyJhbGciOiJIUzI1NiJ9.demo",
              "expiresIn": 3600,
              "user": { "id": 7, "name": "Ryan", "plan": "pro" }
            }
            """.utf8))
        let handler = center.handler
        let first = Task { await handler.editRequest(request) }
        let second = Task { await handler.editResponse(response, for: login) }
        while center.paused.count < 2 { try await Task.sleep(for: .milliseconds(20)) }

        let stageSize = NSSize(width: 1360, height: 740)
        try await shoot(SheetStage(background: ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false), height: 540) {
            BreakpointEditor(center: center, item: center.paused[0])
        }, size: stageSize, dark: false, name: "14-breakpoint-request", into: directory, dimToolbar: true)
        try await shoot(SheetStage(background: ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false), height: 540) {
            BreakpointEditor(center: center, item: center.paused[1])
        }, size: stageSize, dark: true, name: "15-breakpoint-response-dark", into: directory, dimToolbar: true)
        try await shoot(SettingsView(model: model, certificates: storage, license: proLicense, helper: helper, tab: .breakpoints),
                        size: NSSize(width: 560, height: 560), dark: false, name: "16-settings-breakpoints", into: directory)
        center.resumeAll()
        _ = await (first.value, second.value)

        // Main window with Pro tools in the toolbar and an exchange edited at a breakpoint.
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: size, dark: false,
                        name: "17-timeline-breakpoint-edited", into: directory)

        // Replay of a captured PUBLISH, ready to send.
        model.section = .mqtt
        if let publish = model.rows.last(where: { $0.kind == .mqtt && $0.summary.contains("home/kitchen/temperature") }) {
            model.selection = publish.id
            model.prepareReplay(of: publish)
        }
        // As in the mockup: an MQTT 5 broker with two properties, and Format pressed on the payload.
        model.composer.target.version = .v5
        model.composer.contentType = "application/json"
        model.composer.userProperties = [.init(key: "source", value: "wiretide")]
        model.composer.formatPayload()
        model.composer.qos = .atLeastOnce
        model.composer.retain = true
        model.composer.repeatCount = 5
        model.composer.intervalMilliseconds = 500
        let stage = NSSize(width: 1360, height: 740)
        func composerStage() -> some View {
            SheetStage(background: ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false), height: 520) {
                MQTTComposerView(composer: model.composer, suggestions: model.topicSuggestions(excluding: model.composer.topic))
            }
        }
        try await shoot(composerStage(), size: stage, dark: false, name: "18-mqtt-replay", into: directory, dimToolbar: true)
        try await shoot(composerStage(), size: stage, dark: true, name: "19-mqtt-replay-dark", into: directory, dimToolbar: true)

        model.apply(freeLicense.entitlement)
        model.preparePublish(toTopic: "home/kitchen/light/set")
        model.composer.payloadText = #"{"on": true, "brightness": 80}"#
        model.composer.repeatCount = 1
        try await shoot(SheetStage(background: ContentView(model: model, certificates: storage, license: freeLicense, presentsSheets: false), height: 560) {
            MQTTComposerView(composer: model.composer, suggestions: model.topicSuggestions(excluding: model.composer.topic))
        }, size: stage, dark: false, name: "20-mqtt-publish-free", into: directory, dimToolbar: true)
    }

    private static func shoot<V: View>(_ view: V, size: NSSize, dark: Bool, name: String, into directory: URL,
                                       dimToolbar: Bool = false) async throws {
        let window = UnconstrainedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = name.contains("settings") ? "Settings" : "Wiretide"
        // Matches the app's main window, which hides its title (`.unified(showsTitle: false)`).
        if !name.contains("settings") { window.titleVisibility = .hidden }
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
        if dimToolbar {
            // A sheet dims the whole window behind it, toolbar included.
            try dimTop(points: window.frame.height - window.contentLayoutRect.height, ofWindowHeight: window.frame.height,
                       opacity: 0.42, in: url)
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

    /// Darkens the top strip of a window capture (the toolbar), leaving the transparent corners alone.
    private static func dimTop(points: CGFloat, ofWindowHeight windowHeight: CGFloat, opacity: CGFloat, in url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: full)
        // The image may include a frame margin; scale from the window's height to the image's.
        let strip = (points / windowHeight * CGFloat(image.height)).rounded()
        context.setBlendMode(.sourceAtop)
        context.setFillColor(CGColor(gray: 0, alpha: opacity))
        context.fill(CGRect(x: 0, y: CGFloat(image.height) - strip, width: CGFloat(image.width), height: strip))
        guard let dimmed = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, dimmed, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
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
/// A sheet drawn over the dimmed main window, the way the mockups show sheets. A real sheet is its own window,
/// which a window capture leaves out, so screenshots compose the two instead.
private struct SheetStage<Background: View, Sheet: View>: View {
    static var dimming: Double { 0.42 }
    let background: Background
    var width: CGFloat = 760
    let height: CGFloat
    @ViewBuilder var sheet: Sheet

    var body: some View {
        ZStack(alignment: .top) {
            background
                .allowsHitTesting(false)
            // Below the toolbar only: the toolbar is drawn by the window, so `shoot` dims it in the PNG instead.
            Color.black.opacity(SheetStage.dimming).ignoresSafeArea(edges: [.horizontal, .bottom])
            sheet
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
        }
    }
}

/// The CI runner's screen is small; let windows extend past it so shots are taken at full size.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif
