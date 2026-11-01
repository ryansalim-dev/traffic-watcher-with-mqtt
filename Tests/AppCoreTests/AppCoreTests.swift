@testable import AppCore
import CaptureStore
import Licensing
import Foundation
import MQTTCore
import ProxyCore
import TLSMitm
import XCTest

final class FormattingTests: XCTestCase {
    func testPresentPicksJSONTextOrHex() {
        XCTAssertEqual(Formatting.present([]), .empty)
        XCTAssertEqual(Formatting.present(Array(#"{"b":1,"a":[true]}"#.utf8)),
                       .json("{\n  \"b\": 1,\n  \"a\": [\n    true\n  ]\n}"))
        XCTAssertEqual(Formatting.present(Array("hello\nworld".utf8)), .text("hello\nworld"))
        guard case .binary(let dump) = Formatting.present([0x00, 0x01, 0xFF]) else {
            return XCTFail("expected hex")
        }
        XCTAssertTrue(dump.hasPrefix("00000000  00 01 ff"))
    }

    func testPrettyJSONKeepsNumbersOrderAndStrings() {
        let source = #"{"t":21.6,"s":"a, {b}: \"c\"","e":{},"l":[ ],"n":[1,{"x":null}]}"#
        XCTAssertEqual(Formatting.prettyJSON(Array(source.utf8)), """
        {
          "t": 21.6,
          "s": "a, {b}: \\"c\\"",
          "e": {},
          "l": [],
          "n": [
            1,
            {
              "x": null
            }
          ]
        }
        """)
        XCTAssertNil(Formatting.prettyJSON(Array("{nope".utf8)))
    }

    func testJSONContentTypeThatIsNotJSONFallsBackToText() {
        XCTAssertEqual(Formatting.present(Array("not json".utf8), contentType: "application/json"), .text("not json"))
    }

    func testHexDumpLayout() {
        let dump = Formatting.hexDump(Array(0x41...0x52)) // 18 bytes: A...R
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), "00000000  41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  |ABCDEFGHIJKLMNOP|")
        XCTAssertTrue(lines[1].hasPrefix("00000010  51 52 "))
        XCTAssertTrue(lines[1].hasSuffix("|QR|"))
        XCTAssertEqual(lines[0].count - 14, lines[1].count) // hex column padded, ASCII column 14 shorter
    }

    func testDuration() {
        XCTAssertEqual(Formatting.duration(0.0841), "84 ms")
        XCTAssertEqual(Formatting.duration(1.4), "1.40 s")
    }
}

final class TopicTreeTests: XCTestCase {
    func testCountsAndLatestPayload() {
        var tree = TopicTree()
        let date = Date(timeIntervalSince1970: 100)
        tree.record(topic: "home/kitchen/temp", payload: [1], retained: false, at: date)
        tree.record(topic: "home/kitchen/temp", payload: [2], retained: true, at: date + 1)
        tree.record(topic: "home/bedroom/temp", payload: [3], retained: false, at: date)
        tree.record(topic: "home", payload: [4], retained: false, at: date)

        XCTAssertEqual(tree.roots.map(\.id), ["home"])
        let home = tree.node(for: "home")
        XCTAssertEqual(home?.totalCount, 4)
        XCTAssertEqual(home?.messageCount, 1)
        XCTAssertEqual(home?.children.map(\.name), ["bedroom", "kitchen"])
        let kitchen = tree.node(for: "home/kitchen/temp")
        XCTAssertEqual(kitchen?.messageCount, 2)
        XCTAssertEqual(kitchen?.lastPayload, [2])
        XCTAssertEqual(kitchen?.retained, true)
        XCTAssertEqual(kitchen?.lastUpdated, date + 1)
        XCTAssertNil(kitchen?.outlineChildren)
        XCTAssertNil(tree.node(for: "home/garage"))
    }

    func testLeadingSlashAndNumericOrdering() {
        var tree = TopicTree()
        for topic in ["/devices/10", "/devices/9", "/devices/1"] {
            tree.record(topic: topic, payload: [], retained: false, at: Date())
        }
        XCTAssertEqual(tree.roots.first?.name, "(empty)")
        XCTAssertEqual(tree.node(for: "/devices")?.children.map(\.name), ["1", "9", "10"])
    }
}

final class SampleTrafficTests: XCTestCase {
    func testSampleTrafficDecodesEveryKind() {
        let events = SampleTraffic.events()
        var publishes = 0, connects = 0, http = 0, sockets = 0, pinned = 0
        for event in events {
            switch event {
            case .mqtt(let m):
                if case .publish = m.event.packet { publishes += 1 }
                if case .connect = m.event.packet { connects += 1 }
            case .httpExchange: http += 1
            case .webSocketMessage: sockets += 1
            case .tlsInterceptionFailed: pinned += 1
            default: break
            }
        }
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(publishes, 7)
        XCTAssertEqual(http, 5)
        XCTAssertEqual(sockets, 2)
        XCTAssertEqual(pinned, 1)
    }

    func testDescriberRowsForPublish() throws {
        let publish = try XCTUnwrap(SampleTraffic.events().lazy.compactMap { event -> MQTTSessionEvent? in
            if case .mqtt(let m) = event, case .publish = m.event.packet { return m.event }
            return nil
        }.first)
        let rows = MQTTDescriber.rows(for: publish)
        XCTAssertTrue(rows.contains { $0.label == "Topic" && $0.value == "home/kitchen/temperature" }, "\(rows)")
    }
}

final class CaptureViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makeModel(saved: ((EngineConfiguration) -> Void)? = nil) throws -> CaptureViewModel {
        let store = try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path)
        return CaptureViewModel(store: store, engine: nil, saveConfiguration: saved)
    }

    @MainActor
    func testIngestBuildsRowsSectionsAndTopicTree() async throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_793_520_000)
        for event in SampleTraffic.events(startingAt: start) { model.ingest(event) }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.rows.count, SampleTraffic.events().count)
        XCTAssertEqual(model.count(in: .http), 5)
        XCTAssertEqual(model.count(in: .webSocket), 2)
        XCTAssertEqual(model.count(in: .issues), 2) // pinned host + 503
        XCTAssertEqual(model.pinnedHosts, ["pinned.bank.example"])
        XCTAssertEqual(model.topicTree.node(for: "home/kitchen/temperature")?.messageCount, 2)

        model.section = .mqtt
        XCTAssertTrue(model.visibleRows.allSatisfy { $0.kind == .mqtt })
        let connack = try XCTUnwrap(model.rows.first { $0.badge == "CONNACK" })
        XCTAssertEqual(connack.summary, "← Accepted")

        let failed = try XCTUnwrap(model.rows.first { $0.badge == "503" })
        XCTAssertTrue(failed.isIssue)
        XCTAssertEqual(failed.summary, "PUT https://api.example.com/v2/devices/plug-07")

        // Rows keep the event's own time, not the time they were stored.
        let first = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(first.time.timeIntervalSince(start), 0.137, accuracy: 0.001)
    }

    @MainActor
    func testSearchNarrowsVisibleRowsAndSelectionResolves() async throws {
        let model = try makeModel()
        for event in SampleTraffic.events() { model.ingest(event) }

        model.searchText = "bedroom"
        XCTAssertEqual(model.visibleRows.count, 2)
        model.selection = model.visibleRows.first?.id
        XCTAssertEqual(model.selectedRow?.kind, .mqtt)

        model.searchText = "  "
        XCTAssertNil(model.searchResults)
        XCTAssertEqual(model.visibleRows.count, model.rows.count)
    }

    @MainActor
    func testBypassRemembersHostAndSavesConfiguration() async throws {
        var saved: [EngineConfiguration] = []
        let model = try makeModel { saved.append($0) }
        model.ingest(.tlsInterceptionFailed(host: "pinned.example", port: 443, reason: "bad certificate"))
        XCTAssertEqual(model.pinnedHosts, ["pinned.example"])

        model.bypass(host: "pinned.example")
        XCTAssertEqual(model.pinnedHosts, [])
        XCTAssertEqual(model.configuration.bypassHosts, ["pinned.example"])
        XCTAssertEqual(saved.last?.bypassHosts, ["pinned.example"])

        // A bypassed host that fails again is not offered again.
        model.ingest(.tlsInterceptionFailed(host: "pinned.example", port: 443, reason: "bad certificate"))
        XCTAssertEqual(model.pinnedHosts, [])
    }

    @MainActor
    func testNewSessionClearsTimeline() async throws {
        let model = try makeModel()
        for event in SampleTraffic.events() { model.ingest(event) }
        model.newSession()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.topicTree.roots.isEmpty)
        XCTAssertEqual(try model.store.events(in: model.store.currentSession).count, 0)
    }

    @MainActor
    func testConfigurationRoundTripsThroughJSON() async throws {
        var configuration = EngineConfiguration()
        configuration.forwarders = [ForwarderConfiguration(brokerHost: "b.example", useTLS: true)]
        configuration.bypassHosts = ["*.apple.com"]
        let decoded = try JSONDecoder().decode(EngineConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.forwarders.first?.brokerPort, 8883)
        XCTAssertEqual(decoded.forwarders.first?.label, "b.example:8883 (TLS)")
    }
}

final class CaptureEngineTests: XCTestCase {
    func testCertificateStorageCreatesOnceAndProtectsKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CertStorage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CertificateStorage(directory: directory)
        let first = try storage.loadOrCreate()
        let second = try storage.loadOrCreate()
        XCTAssertEqual(try first.certificateDER, try second.certificateDER)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("ca-key.pem").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let der = try storage.exportDER(first)
        XCTAssertEqual(try Data(contentsOf: der), Data(try first.certificateDER))
    }

    func testSimulatorArguments() {
        XCTAssertEqual(SimulatorTools.addRootCertificateArguments(certificatePath: "/tmp/ca.cer"),
                       ["xcrun", "simctl", "keychain", "booted", "add-root-cert", "/tmp/ca.cer"])
    }

    func testEngineStartsAndStops() async throws {
        let engine = CaptureEngine(authority: try CertificateAuthority.generate(), threads: 1)
        var configuration = EngineConfiguration()
        configuration.proxyPort = 0
        configuration.forwarders = [ForwarderConfiguration(brokerHost: "127.0.0.1", brokerPort: 1, listenPort: 0)]
        let port = try await engine.start(configuration)
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.runningConfiguration, configuration)
        try await engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.runningConfiguration)
    }
}

final class LicenseManagerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LicenseManager-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let product = LemonSqueezyClient.Product(storeID: 7, productIDs: [42])

    private static func reply(_ flag: String, ok: Bool = true, status: String = "active") -> String {
        """
        {"\(flag)": \(ok), "error": \(ok ? "null" : "\"license_key is disabled.\""),
         "license_key": {"status": "\(status)", "created_at": "2026-09-21T14:13:20.000000Z", "expires_at": null},
         "instance": {"id": "inst-9"},
         "meta": {"store_id": 7, "product_id": 42, "customer_name": "Ryan", "customer_email": "ryan@example.com"}}
        """
    }

    @MainActor
    private func makeManager(replies: [String], now: Date, offline: Bool = false,
                             configuration: LicenseConfiguration? = nil) -> LicenseManager {
        final class Queue: @unchecked Sendable { var replies: [String] = [] }
        let queue = Queue()
        queue.replies = replies
        return LicenseManager(
            configuration: configuration ?? LicenseConfiguration(product: Self.product, purchaseURL: nil, releaseDate: nil),
            storage: FileLicenseStorage(url: directory.appendingPathComponent("license.json")),
            instanceName: "Test Mac",
            transport: { _ in
                if offline { throw URLError(.notConnectedToInternet) }
                return (Data(queue.replies.removeFirst().utf8), 200)
            },
            now: { now }
        )
    }

    @MainActor
    func testActivatePersistsAndUnlocksPro() async {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let manager = makeManager(replies: [Self.reply("activated")], now: now)
        XCTAssertEqual(manager.sessionLimit, 3)
        await manager.activate(key: "  KEY-1  ")
        XCTAssertNil(manager.lastError)
        XCTAssertTrue(manager.entitlement.isPro)
        XCTAssertNil(manager.sessionLimit)
        XCTAssertEqual(manager.license?.key, "KEY-1")
        XCTAssertTrue(manager.summary.hasPrefix("Pro · updates until"))

        // A new launch reads the stored license.
        let relaunched = makeManager(replies: [], now: now)
        XCTAssertTrue(relaunched.entitlement.isPro)
    }

    @MainActor
    func testRefreshKeepsProOfflineAndRevokesOnRefusal() async {
        let activatedAt = Date(timeIntervalSince1970: 1_793_500_000)
        await makeManager(replies: [Self.reply("activated")], now: activatedAt).activate(key: "KEY-1")

        let later = activatedAt + 4 * 86_400
        let offline = makeManager(replies: [], now: later, offline: true)
        await offline.refreshIfNeeded()
        XCTAssertTrue(offline.entitlement.isPro)
        XCTAssertNotNil(offline.lastError)

        let refused = makeManager(replies: [Self.reply("valid", ok: false, status: "disabled")], now: later)
        await refused.refreshIfNeeded()
        XCTAssertEqual(refused.entitlement, .free(.revoked))
        XCTAssertEqual(refused.sessionLimit, 3)
    }

    @MainActor
    func testDeactivateForgetsLicense() async {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let manager = makeManager(replies: [Self.reply("activated"), Self.reply("deactivated")], now: now)
        await manager.activate(key: "KEY-1")
        await manager.deactivate()
        XCTAssertNil(manager.license)
        XCTAssertEqual(manager.entitlement, .free(.noLicense))
        XCTAssertNil(makeManager(replies: [], now: now).license)
    }

    @MainActor
    func testUnconfiguredBuildExplainsWhyActivationFails() async {
        let manager = makeManager(replies: [], now: Date(),
                                  configuration: LicenseConfiguration(product: nil, purchaseURL: nil, releaseDate: nil))
        XCTAssertFalse(manager.isConfigured)
        await manager.activate(key: "KEY-1")
        XCTAssertNotNil(manager.lastError)
        XCTAssertNil(manager.license)
    }

    func testConfigurationFromInfoPlist() {
        let configuration = LicenseConfiguration(infoDictionary: [
            "TWLemonSqueezyStoreID": NSNumber(value: 7),
            "TWLemonSqueezyProductIDs": "42, 43",
            "TWPurchaseURL": "https://example.com/buy",
            "TWReleaseDate": "2026-11-01",
        ])
        XCTAssertEqual(configuration.product, LemonSqueezyClient.Product(storeID: 7, productIDs: [42, 43]))
        XCTAssertEqual(configuration.purchaseURL?.absoluteString, "https://example.com/buy")
        XCTAssertEqual(configuration.releaseDate, Date(timeIntervalSince1970: 1_793_491_200))
        XCTAssertNil(LicenseConfiguration(infoDictionary: [:]).product)
    }
}

final class SessionLimitTests: XCTestCase {
    @MainActor
    func testFreeTierKeepsNewestSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path, sessionName: "S1")
        let model = CaptureViewModel(store: store, engine: nil)
        for name in ["S2", "S3", "S4"] { model.newSession(named: name) }
        XCTAssertEqual(try store.sessions().count, 4)

        model.sessionLimit = 3
        XCTAssertEqual(try store.sessions().map(\.name), ["S4", "S3", "S2"])
        model.newSession(named: "S5")
        XCTAssertEqual(try store.sessions().map(\.name), ["S5", "S4", "S3"])

        model.sessionLimit = nil
        model.newSession(named: "S6")
        XCTAssertEqual(try store.sessions().count, 4)
    }
}
