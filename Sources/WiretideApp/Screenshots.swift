#if os(macOS)
import AppCore
import AppKit
import CaptureStore
import ImageIO
import Licensing
import MQTTCore
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
        let firstLaunchLicense = LicenseManager(configuration: LicenseConfiguration(providers: [LemonSqueezyClient(product: .init(storeID: 1, productIDs: [1]))],
                                                                                    purchaseURL: nil, releaseDate: nil),
                                                storage: FileLicenseStorage(url: scratch.appendingPathComponent("first.json")))
        try await shoot(ContentView(model: model, certificates: storage, license: firstLaunchLicense), size: size, dark: false,
                        name: "00-first-launch", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: firstLaunchLicense), size: size, dark: true,
                        name: "00-first-launch-dark", into: directory)

        await model.startCapture()
        for event in SampleTraffic.events() { model.ingest(event) }

        // License states for the License tab: no key yet, and an active Pro license checked today.
        let licenseConfiguration = LicenseConfiguration(providers: [LemonSqueezyClient(product: .init(storeID: 1, productIDs: [1]))],
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
        try await shootRules(model: model, storage: storage, freeLicense: freeLicense, proLicense: proLicense, into: directory)
        try await shootScripts(model: model, storage: storage, freeLicense: freeLicense, proLicense: proLicense, into: directory)
        try await shootSessions(model: model, storage: storage, scratch: scratch, freeLicense: freeLicense, proLicense: proLicense,
                                into: directory)
        try await shootSessionLimit(storage: storage, freeLicense: freeLicense, into: directory)
        await model.stopCapture()
    }

    /// Free tier with its one saved session: the Saved Sessions window, and New Session asking before it replaces.
    private static func shootSessionLimit(storage: CertificateStorage, freeLicense: LicenseManager, into directory: URL) async throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "seed")
        let hour: TimeInterval = 3_600
        for (name, offset) in [("Thermostat firmware 4.2.1", -26 * hour)] {
            let start = Date().addingTimeInterval(offset)
            try store.startSession(named: name, createdAt: start)
            for event in SampleTraffic.events(startingAt: start.addingTimeInterval(5)) {
                switch event {
                case .tlsInterceptionFailed, .tunnelClosed, .mqttDecodingFailed, .webSocketDecodingFailed: continue
                default: store.record(event)
                }
            }
        }
        try store.startSession(named: "Smart home app, Nov 2")
        try store.deleteEmptySessions()
        let model = CaptureViewModel(store: store, engine: nil)
        for event in SampleTraffic.events() { model.ingest(event) }
        model.savedSessionLimit = freeLicense.savedSessionLimit
        model.reloadSessions()
        model.section = .all

        let windowSize = NSSize(width: 900, height: 600)
        try await shoot(SessionsWindow(model: model, license: freeLicense), size: windowSize, dark: false,
                        name: "34-sessions-free", into: directory, title: "Saved Sessions")

        let prompt = try unwrapped(model.sessionLimitPrompt(forNewSessionNamed: "Nov 2, 2026 at 15:10"))
        let size = NSSize(width: 1440, height: 860)
        for dark in [false, true] {
            try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, presentsSheets: false,
                                        stagedSheet: AnyView(SheetStage(width: 520, height: 322) {
                SessionLimitSheet(model: model, prompt: prompt) {}
            })), size: size, dark: dark, name: dark ? "36b-session-limit-dark" : "36-session-limit", into: directory, dimToolbar: true)
        }

        // A Mac with sessions from before the limit: they are listed together.
        let earlier = try CaptureStore(path: ":memory:", sessionName: "seed")
        for name in ["Before the redesign", "Kitchen sensor soak test", "Checkout flow, staging", "Smart home app, Nov 2"] {
            try earlier.startSession(named: name)
            earlier.record(SampleTraffic.events()[1])
        }
        let earlierModel = CaptureViewModel(store: earlier, engine: nil)
        earlierModel.savedSessionLimit = freeLicense.savedSessionLimit
        try earlier.deleteEmptySessions()
        let earlierPrompt = try unwrapped(earlierModel.sessionLimitPrompt(forNewSessionNamed: "Nov 2, 2026 at 15:10"))
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, presentsSheets: false,
                                    stagedSheet: AnyView(SheetStage(width: 520, height: 436) {
            SessionLimitSheet(model: earlierModel, prompt: earlierPrompt) {}
        })), size: size, dark: true, name: "37-session-limit-earlier-dark", into: directory, dimToolbar: true)
    }

    private struct Missing: Error {}
    private static func unwrapped<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    /// The Saved Sessions window and a saved session open in the timeline, with a few earlier sessions on file.
    private static func shootSessions(model: CaptureViewModel, storage: CertificateStorage, scratch: URL, freeLicense: LicenseManager,
                                      proLicense: LicenseManager, into directory: URL) async throws {
        // Earlier sessions go in through a second connection, so the model keeps recording into its own.
        let seeder = try CaptureStore(path: scratch.appendingPathComponent("captures.sqlite").path, sessionName: "seed")
        let hour: TimeInterval = 3_600
        let history: [(String, TimeInterval, Int)] = [
            ("Checkout flow, staging", -2 * hour, 2),
            ("Thermostat firmware 4.2.1", -26 * hour, 1),
            ("Login bug repro", -27 * hour, 3),
            ("Kitchen sensor soak test", -4 * 24 * hour, 6),
            ("Before the redesign", -12 * 24 * hour, 1),
        ]
        for (name, offset, repeats) in history {
            let start = Date().addingTimeInterval(offset)
            try seeder.startSession(named: name, createdAt: start)
            for round in 0..<repeats {
                // Events without their own time would be stamped now; leave them out of the backdated sessions.
                for event in SampleTraffic.events(startingAt: start.addingTimeInterval(Double(round) * 240 + 5)) {
                    switch event {
                    case .tlsInterceptionFailed, .tunnelClosed, .mqttDecodingFailed, .webSocketDecodingFailed: continue
                    default: seeder.record(event)
                    }
                }
            }
            if name.contains("sensor") {
                for event in SampleTraffic.temperatureReadings(count: 120, endingAt: start.addingTimeInterval(3 * hour)) { seeder.record(event) }
            }
        }
        try model.store.deleteEmptySessions()
        try model.store.renameSession(model.store.currentSession, to: "Smart home app, Nov 2")
        model.savedSessionLimit = nil
        model.apply(proLicense.entitlement)
        model.reloadSessions()
        model.openSession(model.sessions.first { $0.name == "Thermostat firmware 4.2.1" }!.id)

        let windowSize = NSSize(width: 900, height: 600)
        try await shoot(SessionsWindow(model: model, license: proLicense), size: windowSize, dark: false,
                        name: "33-sessions", into: directory, title: "Saved Sessions")
        try await shoot(SessionsWindow(model: model, license: proLicense), size: windowSize, dark: true,
                        name: "33b-sessions-dark", into: directory, title: "Saved Sessions")

        // Free tier on a Mac that saved several sessions before the limit: they all stay.
        try await shoot(SessionsWindow(model: model, license: freeLicense), size: windowSize, dark: false,
                        name: "34b-sessions-free-earlier", into: directory, title: "Saved Sessions")

        let login = model.sessions.first { $0.name == "Login bug repro" }!
        model.openSession(login.id)
        model.section = .all
        model.selection = model.rows.first { $0.badge == "503" }?.id
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: NSSize(width: 1440, height: 860),
                        dark: true, name: "35-timeline-saved-session-dark", into: directory)
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: NSSize(width: 1440, height: 860),
                        dark: false, name: "35b-timeline-saved-session", into: directory)
        model.returnToLive()
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

        let stageSize = NSSize(width: 1440, height: 760)
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false,
                                    stagedSheet: AnyView(SheetStage(height: 540) {
            BreakpointEditor(center: center, item: center.paused[0])
        })), size: stageSize, dark: false, name: "14-breakpoint-request", into: directory, dimToolbar: true)
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false,
                                    stagedSheet: AnyView(SheetStage(height: 540) {
            BreakpointEditor(center: center, item: center.paused[1])
        })), size: stageSize, dark: true, name: "15-breakpoint-response-dark", into: directory, dimToolbar: true)
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
        let stage = NSSize(width: 1440, height: 760)
        func composerStage() -> ContentView {
            ContentView(model: model, certificates: storage, license: proLicense, presentsSheets: false,
                        stagedSheet: AnyView(SheetStage(height: 520) {
                MQTTComposerView(composer: model.composer, suggestions: model.topicSuggestions(excluding: model.composer.topic))
            }))
        }
        try await shoot(composerStage(), size: stage, dark: false, name: "18-mqtt-replay", into: directory, dimToolbar: true)
        try await shoot(composerStage(), size: stage, dark: true, name: "19-mqtt-replay-dark", into: directory, dimToolbar: true)

        model.apply(freeLicense.entitlement)
        model.preparePublish(toTopic: "home/kitchen/light/set")
        model.composer.payloadText = #"{"on": true, "brightness": 80}"#
        model.composer.repeatCount = 1
        try await shoot(ContentView(model: model, certificates: storage, license: freeLicense, presentsSheets: false,
                                    stagedSheet: AnyView(SheetStage(height: 560) {
            MQTTComposerView(composer: model.composer, suggestions: model.topicSuggestions(excluding: model.composer.topic))
        })), size: stage, dark: false, name: "20-mqtt-publish-free", into: directory, dimToolbar: true)
    }

    /// Map Local, Map Remote, Rewrite and MQTT rules in the rules window, and their notes in the inspector.
    private static func shootRules(model: CaptureViewModel, storage: CertificateStorage, freeLicense: LicenseManager,
                                   proLicense: LicenseManager, into directory: URL) async throws {
        let center = model.rewrites
        let windowSize = NSSize(width: 980, height: 660)
        let devices = model.rows.last { row in
            if case .httpExchange(let e) = row.event { e.method == "GET" && e.url.hasPrefix("https://api.example.com/v2/devices") } else { false }
        }

        // Free tier, nothing set up yet: the empty state and the Pro notice.
        model.apply(freeLicense.entitlement)
        center.httpRules = []
        center.mqttRules = []
        center.selection = nil
        try await shoot(RulesWindow(model: model), size: windowSize, dark: false, name: "21-rules-empty-free", into: directory,
                        title: "Map & Rewrite")

        model.apply(proLicense.entitlement)
        var mapLocal: HTTPRule
        if let devices, case .httpExchange(let exchange) = devices.event {
            mapLocal = center.addMapLocal(from: exchange)
        } else {
            mapLocal = center.addHTTPRule(kind: .mapLocal, pattern: "https://api.example.com/v2/devices*", method: "GET")
        }
        mapLocal.name = "Empty device list"
        mapLocal.mapLocal.body = """
        {
          "devices": [],
          "page": 1,
          "total": 0
        }
        """
        center.httpRules[0] = mapLocal
        center.addHTTPRule(kind: .mapRemote, pattern: "api.example.com/v2/*")
        center.httpRules[1].name = "API on localhost"
        center.httpRules[1].mapRemote = MapRemoteDestination(url: "http://localhost:3000/v2/*")
        center.addHTTPRule(kind: .rewrite, pattern: "api.example.com/v2/login", method: "POST")
        center.httpRules[2].name = "Force free plan"
        center.httpRules[2].operations = [
            RewriteOperation(phase: .request, target: .header, action: .set, name: "X-Debug", value: "1"),
            RewriteOperation(phase: .response, target: .json, action: .set, name: "user.plan", value: "\"free\""),
            RewriteOperation(phase: .response, target: .header, action: .replace, name: "Cache-Control", value: "max-age=0",
                             find: "max-age=\\d+", useRegex: true),
        ]
        center.httpRules[2].isEnabled = true
        center.addHTTPRule(kind: .rewrite, pattern: "*.example.net/*")
        center.httpRules[3].isEnabled = false
        center.addMQTTRule(topicFilter: "home/+/temperature")
        center.mqttRules[0].name = "Heatwave"
        center.mqttRules[0].direction = .brokerToClient
        center.mqttRules[0].operations = [
            MQTTRewriteOperation(target: .json, action: .set, name: "celsius", value: "41.5"),
            MQTTRewriteOperation(target: .topic, action: .replace, value: "/test/", find: "/kitchen/"),
        ]

        center.selection = .http(center.httpRules[0].id)
        try await shoot(RulesWindow(model: model), size: windowSize, dark: false, name: "22-rules-map-local", into: directory,
                        title: "Map & Rewrite")
        try await shoot(RulesWindow(model: model), size: windowSize, dark: true, name: "22b-rules-map-local-dark", into: directory,
                        title: "Map & Rewrite")
        center.selection = .http(center.httpRules[1].id)
        try await shoot(RulesWindow(model: model), size: windowSize, dark: true, name: "23-rules-map-remote-dark", into: directory,
                        title: "Map & Rewrite")
        center.selection = .http(center.httpRules[2].id)
        try await shoot(RulesWindow(model: model), size: windowSize, dark: false, name: "24-rules-rewrite", into: directory,
                        title: "Map & Rewrite")
        try await shoot(RulesWindow(model: model), size: windowSize, dark: true, name: "24b-rules-rewrite-dark", into: directory,
                        title: "Map & Rewrite")
        center.selection = .mqtt(center.mqttRules[0].id)
        try await shoot(RulesWindow(model: model), size: windowSize, dark: true, name: "25-rules-mqtt-dark", into: directory,
                        title: "Map & Rewrite")

        // The main window: an exchange answered by Map Local, the toolbar count and the sidebar line.
        let mocked = HTTPExchange(
            startedAt: Date(), duration: 0.003, method: "GET", url: "https://api.example.com/v2/devices?room=kitchen&page=1",
            requestHeaders: [CapturedHeader(name: "Accept", value: "application/json")], requestBody: [], statusCode: 200,
            responseHeaders: [CapturedHeader(name: "Content-Type", value: "application/json")],
            responseBody: Array(#"{"devices":[],"page":1,"total":0}"#.utf8),
            rewrittenBy: ["Empty device list"], mappedLocally: true)
        model.ingest(.httpExchange(mocked))
        model.section = .http
        model.selection = model.rows.last?.id
        let size = NSSize(width: 1440, height: 860)
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: size, dark: true,
                        name: "26-timeline-map-local-dark", into: directory)

        if let reading = model.rows.last(where: { $0.kind == .mqtt && $0.summary.contains("home/kitchen/temperature") }),
           case .mqtt(var capture) = reading.event, case .publish(var publish) = capture.event.packet {
            publish.topic = "home/test/temperature"
            publish.payload = Array(#"{"celsius":41.5,"humidity":38}"#.utf8)
            if let bytes = try? MQTTPacketEncoder.encode(.publish(publish), version: capture.event.version) {
                capture.event.frame = MQTTFrame(packet: .publish(publish), rawBytes: bytes)
            }
            capture.event.resolvedTopic = publish.topic
            capture.event.direction = .brokerToClient
            capture.timestamp = Date()
            capture.rewrittenBy = ["Heatwave"]
            model.ingest(.mqtt(capture))
            model.section = .mqtt
            model.selection = model.rows.last?.id
            try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: size, dark: false,
                            name: "27-mqtt-rewritten", into: directory)
        }
    }

    /// The scripts window: empty and locked, HTTP and MQTT scripts after a test run, a syntax error, and the inspector note.
    private static func shootScripts(model: CaptureViewModel, storage: CertificateStorage, freeLicense: LicenseManager,
                                     proLicense: LicenseManager, into directory: URL) async throws {
        let center = model.scripts
        let windowSize = NSSize(width: 1040, height: 720)
        center.scripts = []
        center.selection = nil
        center.clearLog()
        model.apply(freeLicense.entitlement)
        try await shoot(ScriptsWindow(model: model), size: windowSize, dark: false, name: "28-scripts-empty-free", into: directory,
                        title: "Scripts")

        model.apply(proLicense.entitlement)
        center.addScript(.addHeader)
        center.scripts[0].name = "Sign API requests"
        let devices = center.addScript(.editJSONResponse, urlPattern: "api.example.com/v2/devices*", method: "GET", name: "All devices online")
        if let index = center.scripts.firstIndex(where: { $0.id == devices.id }) {
            center.scripts[index].source = """
            // Pretend every device is reachable, to test the app's online state.
            function onResponse(request, response) {
              if (!response.json || !response.json.devices) return;
              let changed = 0;
              for (const device of response.json.devices) {
                if (!device.online) changed += 1;
                device.online = true;
              }
              response.headers["X-Wiretide-Script"] = "devices-online";
              console.log("Marked", changed, "of", response.json.devices.length, "devices online for", request.path);
              return response;
            }
            """
        }
        let fahrenheit = center.addScript(.mqttPayload, topicFilter: "home/+/temperature", name: "Add Fahrenheit")
        if let index = center.scripts.firstIndex(where: { $0.id == fahrenheit.id }) {
            center.scripts[index].direction = .brokerToClient
            center.scripts[index].source = """
            // Add a Fahrenheit reading next to Celsius on every temperature message.
            function onPublish(message) {
              if (message.json && typeof message.json.celsius === "number") {
                message.json.fahrenheit = Math.round((message.json.celsius * 9 / 5 + 32) * 10) / 10;
                console.log(message.topic, message.json.celsius + "°C →", message.json.fahrenheit + "°F");
              }
              return message;
            }
            """
        }
        let mock = center.addScript(.mockResponse, name: "Block deletes")
        if let index = center.scripts.firstIndex(where: { $0.id == mock.id }) { center.scripts[index].isEnabled = false }

        // Try the HTTP script on the captured device list, as "Run on Latest Match" would.
        if let row = model.rows.first(where: { row in
            if case .httpExchange(let e) = row.event { e.url.hasPrefix("https://api.example.com/v2/devices?limit") } else { false }
        }), let script = center.scripts.first(where: { $0.id == devices.id }) {
            await center.test(script, on: row)
        }
        center.selection = devices.id
        try await shoot(ScriptsWindow(model: model), size: windowSize, dark: false, name: "29-scripts-http", into: directory, title: "Scripts")
        try await shoot(ScriptsWindow(model: model), size: windowSize, dark: true, name: "29b-scripts-http-dark", into: directory, title: "Scripts")

        if let row = model.rows.last(where: { $0.kind == .mqtt && $0.summary.contains("home/kitchen/temperature") }),
           let script = center.scripts.first(where: { $0.id == fahrenheit.id }) {
            await center.test(script, on: row)
        }
        center.selection = fahrenheit.id
        try await shoot(ScriptsWindow(model: model), size: windowSize, dark: true, name: "30-scripts-mqtt-dark", into: directory, title: "Scripts")

        // A half-typed edit: the syntax check flags the line before anything runs.
        if let index = center.scripts.firstIndex(where: { $0.id == mock.id }) {
            center.scripts[index].isEnabled = true
            center.scripts[index].source = center.scripts[index].source.replacingOccurrences(of: "return respond(403, \"Deleting is disabled while testing\");",
                                                                                              with: "return respond(403, \"Deleting is disabled\";")
        }
        center.selection = mock.id
        try await shoot(ScriptsWindow(model: model), size: windowSize, dark: false, name: "31-scripts-syntax-error", into: directory, title: "Scripts")

        // The main window: an exchange a script changed, the toolbar count and the sidebar line.
        let scripted = HTTPExchange(
            startedAt: Date(), duration: 0.091, method: "GET", url: "https://api.example.com/v2/devices?limit=20",
            requestHeaders: [CapturedHeader(name: "Accept", value: "application/json"), CapturedHeader(name: "X-Debug", value: "1")],
            requestBody: [], statusCode: 200,
            responseHeaders: [CapturedHeader(name: "Content-Type", value: "application/json"),
                              CapturedHeader(name: "X-Wiretide-Script", value: "devices-online")],
            responseBody: Array(#"{"devices":[{"firmware":"4.2.1","id":"thermo-01","name":"Kitchen","online":true},{"id":"plug-07","name":"Desk lamp","online":true}],"next":null}"#.utf8),
            scriptedBy: ["Sign API requests", "All devices online"])
        model.ingest(.httpExchange(scripted))
        model.section = .http
        model.selection = model.rows.last?.id
        try await shoot(ContentView(model: model, certificates: storage, license: proLicense), size: NSSize(width: 1440, height: 860), dark: true,
                        name: "32-timeline-scripted-dark", into: directory)
    }

    private static func shoot<V: View>(_ view: V, size: NSSize, dark: Bool, name: String, into directory: URL,
                                       dimToolbar: Bool = false, title: String? = nil) async throws {
        let window = UnconstrainedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title ?? (name.contains("settings") ? "Settings" : "Wiretide")
        // Matches the app's main window, which hides its title (`.unified(showsTitle: false)`).
        if title == nil && !name.contains("settings") { window.titleVisibility = .hidden }
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
/// A sheet over the dimmed main window (ContentView's `stagedSheet`), the way the mockups show sheets. A real sheet is its own window,
/// which a window capture leaves out, so screenshots compose the two instead.
private struct SheetStage<Sheet: View>: View {
    static var dimming: Double { 0.42 }
    var width: CGFloat = 760
    let height: CGFloat
    @ViewBuilder var sheet: Sheet

    var body: some View {
        ZStack(alignment: .top) {
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
