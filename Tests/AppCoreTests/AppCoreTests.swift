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
        let client = LemonSqueezyClient(product: Self.product, transport: { _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data(queue.replies.removeFirst().utf8), 200)
        })
        return LicenseManager(
            configuration: configuration ?? LicenseConfiguration(providers: [client], purchaseURL: nil, releaseDate: nil),
            storage: FileLicenseStorage(url: directory.appendingPathComponent("license.json")),
            instanceName: "Test Mac",
            now: { now }
        )
    }

    @MainActor
    func testActivatePersistsAndUnlocksPro() async {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let manager = makeManager(replies: [Self.reply("activated")], now: now)
        XCTAssertEqual(manager.savedSessionLimit, 1)
        await manager.activate(key: "  KEY-1  ")
        XCTAssertNil(manager.lastError)
        XCTAssertTrue(manager.entitlement.isPro)
        XCTAssertNil(manager.savedSessionLimit)
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
        XCTAssertNil(refused.savedSessionLimit, "a lapsed customer is never asked to give up saved sessions")
    }

    @MainActor
    func testUpdatesAreLimitedToTheLicensesWindow() async {
        let activatedAt = Date(timeIntervalSince1970: 1_793_500_000)
        let manager = makeManager(replies: [Self.reply("activated")], now: activatedAt)
        XCTAssertNil(manager.updatesCoveredUntil, "without a license every update is offered")
        await manager.activate(key: "KEY-1")
        // The reply's purchase date is 2026-09-21T14:13:20Z, so updates are covered until 2027-09-21T14:13:20Z.
        let until = try? XCTUnwrap(manager.updatesCoveredUntil)
        XCTAssertEqual(until, Date(timeIntervalSince1970: 1_821_536_000))
        let day: TimeInterval = 86_400
        XCTAssertTrue(LicenseManager.updateIsCovered(published: until! - 30 * day, coveredUntil: until))
        XCTAssertTrue(LicenseManager.updateIsCovered(published: until! + 3600, coveredUntil: until),
                      "a release from the last covered day counts, like TWReleaseDate")
        XCTAssertFalse(LicenseManager.updateIsCovered(published: until! + day, coveredUntil: until))
        XCTAssertFalse(LicenseManager.updateIsCovered(published: nil, coveredUntil: until))
        XCTAssertTrue(LicenseManager.updateIsCovered(published: until! + 400 * day, coveredUntil: nil))
    }

    @MainActor
    func testCaptivePortalDoesNotRevoke() async {
        let activatedAt = Date(timeIntervalSince1970: 1_793_500_000)
        await makeManager(replies: [Self.reply("activated")], now: activatedAt).activate(key: "KEY-1")
        let portal = makeManager(replies: ["<html>Sign in to the hotel Wi-Fi</html>"], now: activatedAt + 4 * 86_400)
        await portal.refreshIfNeeded()
        XCTAssertTrue(portal.entitlement.isPro)
        XCTAssertEqual(portal.license?.status, .active)
        XCTAssertNotNil(portal.lastError)
    }

    @MainActor
    func testDeactivateForgetsALicenseTheStoreNoLongerKnows() async {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let gone = #"{"deactivated": false, "error": "instance_id not found."}"#
        let manager = makeManager(replies: [Self.reply("activated"), gone], now: now)
        await manager.activate(key: "KEY-1")
        await manager.deactivate()
        XCTAssertNil(manager.license)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testUnreadableLicenseLiftsTheSessionLimit() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("license.json"))
        let manager = makeManager(replies: [], now: Date())
        XCTAssertNotNil(manager.lastError)
        XCTAssertNil(manager.savedSessionLimit, "never limit sessions because the license couldn't be read")
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
                                  configuration: LicenseConfiguration(providers: [], purchaseURL: nil, releaseDate: nil))
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
        XCTAssertEqual(configuration.providers.map(\.id), [LemonSqueezyClient.providerID])
        XCTAssertEqual((configuration.providers.first as? LemonSqueezyClient)?.product,
                       LemonSqueezyClient.Product(storeID: 7, productIDs: [42, 43]))
        XCTAssertEqual(configuration.purchaseURL?.absoluteString, "https://example.com/buy")
        XCTAssertEqual(configuration.releaseDate, Date(timeIntervalSince1970: 1_793_491_200))
        XCTAssertTrue(LicenseConfiguration(infoDictionary: [:]).providers.isEmpty)
    }

    // MARK: Providers

    /// A store that knows a fixed set of keys, records calls, and can be taken offline.
    private final class FakeProvider: LicenseProvider, @unchecked Sendable {
        let id: String
        let storeName: String
        let keys: Set<String>
        var offline = false
        var validated: [String] = []
        var deactivated: [String] = []

        init(id: String, keys: Set<String>) {
            self.id = id
            storeName = id.capitalized
            self.keys = keys
        }

        func activate(key: String, instanceName: String, now: Date) async throws -> StoredLicense {
            if offline { throw LicenseError.network("offline") }
            guard keys.contains(key) else { throw LicenseError.rejected("\(id): license_key not found.") }
            return StoredLicense(provider: id, key: key, instanceID: "\(id)-machine", status: .active,
                                 purchasedAt: now, lastValidatedAt: now)
        }

        func validate(_ license: StoredLicense, now: Date) async throws -> StoredLicense {
            validated.append(license.key)
            var refreshed = license
            refreshed.lastValidatedAt = now
            return refreshed
        }

        func deactivate(_ license: StoredLicense) async throws {
            deactivated.append(license.key)
        }
    }

    @MainActor
    private func makeManager(providers: [any LicenseProvider], now: Date) -> LicenseManager {
        LicenseManager(configuration: LicenseConfiguration(providers: providers, purchaseURL: nil, releaseDate: nil),
                       storage: FileLicenseStorage(url: directory.appendingPathComponent("license.json")),
                       instanceName: "Test Mac", now: { now })
    }

    @MainActor
    func testActivationFallsThroughToTheProviderThatKnowsTheKey() async {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let keygen = FakeProvider(id: "keygen", keys: ["NEW-KEY"])
        let lemon = FakeProvider(id: "lemonsqueezy", keys: ["OLD-KEY"])
        let manager = makeManager(providers: [keygen, lemon], now: now)

        await manager.activate(key: "OLD-KEY")
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.license?.provider, "lemonsqueezy")
        XCTAssertEqual(manager.storeName, "Lemonsqueezy")
        XCTAssertTrue(manager.entitlement.isPro)

        // A key nobody knows reports the first store's refusal.
        await manager.activate(key: "TYPO")
        XCTAssertEqual(manager.lastError, String(describing: LicenseError.rejected("keygen: license_key not found.")))
        XCTAssertEqual(manager.license?.key, "OLD-KEY")
    }

    @MainActor
    func testNetworkFailureStopsActivationInsteadOfTryingTheNextStore() async {
        let keygen = FakeProvider(id: "keygen", keys: [])
        keygen.offline = true
        let lemon = FakeProvider(id: "lemonsqueezy", keys: ["OLD-KEY"])
        let manager = makeManager(providers: [keygen, lemon], now: Date())
        await manager.activate(key: "OLD-KEY")
        XCTAssertNil(manager.license)
        XCTAssertEqual(manager.lastError, String(describing: LicenseError.network("offline")))
    }

    @MainActor
    func testValidationAndDeactivationGoToTheIssuingProvider() async {
        let activatedAt = Date(timeIntervalSince1970: 1_793_500_000)
        let keygen = FakeProvider(id: "keygen", keys: [])
        let lemon = FakeProvider(id: "lemonsqueezy", keys: ["OLD-KEY"])
        await makeManager(providers: [keygen, lemon], now: activatedAt).activate(key: "OLD-KEY")

        let manager = makeManager(providers: [keygen, lemon], now: activatedAt + 4 * 86_400)
        await manager.refreshIfNeeded()
        XCTAssertEqual(lemon.validated, ["OLD-KEY"])
        XCTAssertTrue(keygen.validated.isEmpty)

        await manager.deactivate()
        XCTAssertEqual(lemon.deactivated, ["OLD-KEY"])
        XCTAssertNil(manager.license)
    }

    @MainActor
    func testLicenseFromARemovedProviderIsKeptButNotValidated() async {
        let activatedAt = Date(timeIntervalSince1970: 1_793_500_000)
        await makeManager(providers: [FakeProvider(id: "lemonsqueezy", keys: ["OLD-KEY"])], now: activatedAt)
            .activate(key: "OLD-KEY")

        let keygen = FakeProvider(id: "keygen", keys: [])
        let manager = makeManager(providers: [keygen], now: activatedAt + 4 * 86_400)
        await manager.refreshIfNeeded()
        XCTAssertTrue(keygen.validated.isEmpty)
        XCTAssertEqual(manager.license?.key, "OLD-KEY")
        XCTAssertTrue(manager.entitlement.isPro, "the offline grace period still applies")
        XCTAssertEqual(manager.lastError, String(describing: LicenseError.unknownProvider("lemonsqueezy")))

        // Forgetting it works even though that store can't be reached from this build.
        await manager.deactivate()
        XCTAssertNil(manager.license)
        XCTAssertTrue(keygen.deactivated.isEmpty)
    }
}

final class SessionLimitTests: XCTestCase {
    private func record(_ model: CaptureViewModel) {
        model.ingest(SampleTraffic.events()[1])
    }

    @MainActor
    func testFreeTierAsksBeforeReplacingItsSavedSession() async throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "S1")
        let model = CaptureViewModel(store: store, engine: nil)
        model.savedSessionLimit = 1
        record(model)

        // The first saved session fits.
        model.requestNewSession(named: "S2")
        XCTAssertNil(model.sessionLimitPrompt)
        XCTAssertEqual(model.sessions.map(\.name), ["S2", "S1"])

        // An empty session adds nothing, so it never asks.
        XCTAssertNil(model.sessionLimitPrompt(forNewSessionNamed: "S3"))

        record(model)
        model.requestNewSession(named: "S3")
        let prompt = try XCTUnwrap(model.sessionLimitPrompt)
        XCTAssertEqual(prompt.saving.name, "S2")
        XCTAssertEqual(prompt.replacing.map(\.name), ["S1"])
        XCTAssertEqual(try store.sessions().map(\.name), ["S2", "S1"], "nothing changes until the user chooses")

        model.replaceAndStartNewSession(prompt)
        XCTAssertNil(model.sessionLimitPrompt)
        XCTAssertEqual(try store.sessions().map(\.name), ["S3", "S2"])
        XCTAssertTrue(model.rows.isEmpty)
    }

    @MainActor
    func testSessionsFromBeforeTheLimitStayUntilReplaced() async throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "S1")
        let model = CaptureViewModel(store: store, engine: nil)
        for name in ["S2", "S3", "S4"] {
            record(model)
            model.newSession(named: name)
        }
        record(model)
        model.savedSessionLimit = 1
        model.reloadSessions()
        XCTAssertEqual(model.savedSessions.map(\.name), ["S3", "S2", "S1"], "setting the limit deletes nothing")

        let prompt = try XCTUnwrap(model.sessionLimitPrompt(forNewSessionNamed: "S5"))
        XCTAssertEqual(prompt.replacing.map(\.name), ["S3", "S2", "S1"])
        model.replaceAndStartNewSession(prompt)
        XCTAssertEqual(try store.sessions().map(\.name), ["S5", "S4"])
    }

    @MainActor
    func testProNeverAsks() async throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "S1")
        let model = CaptureViewModel(store: store, engine: nil)
        for name in ["S2", "S3"] {
            record(model)
            model.requestNewSession(named: name)
        }
        XCTAssertNil(model.sessionLimitPrompt)
        XCTAssertEqual(try store.sessions().count, 3)
    }

    @MainActor
    func testLaunchContinuesTheLatestSessionWhenFull() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path

        func launch(_ name: String) throws -> CaptureViewModel {
            let model = CaptureViewModel(store: try CaptureStore(path: path, sessionName: name), engine: nil)
            model.savedSessionLimit = 1
            return model
        }

        // Second launch: one saved session fits, so a new session starts.
        let first = try launch("Monday")
        record(first)
        let second = try launch("Tuesday")
        XCTAssertFalse(second.continueLatestSessionIfFull())
        record(second)
        record(second)

        // Third launch: the saved slot is full, so recording carries on in Tuesday.
        let third = try launch("Wednesday")
        XCTAssertTrue(third.continueLatestSessionIfFull())
        XCTAssertEqual(third.sessions.map(\.name), ["Tuesday", "Monday"])
        XCTAssertTrue(third.isLive(third.sessions[0]))
        XCTAssertEqual(third.rows.count, 2, "the timeline shows what Tuesday already has")
        record(third)
        XCTAssertEqual(try third.store.events(in: third.store.currentSession).count, 3)

        // Pro starts a new session every launch.
        let pro = CaptureViewModel(store: try CaptureStore(path: path, sessionName: "Thursday"), engine: nil)
        XCTAssertFalse(pro.continueLatestSessionIfFull())
    }
}

final class SavedSessionTests: XCTestCase {
    @MainActor
    func testOpenSavedSessionWhileLiveCaptureContinues() async throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "Monday")
        let model = CaptureViewModel(store: store, engine: nil)
        let monday = store.currentSession
        for event in SampleTraffic.events() { model.ingest(event) }
        let mondayCount = model.rows.count
        model.newSession(named: "Tuesday")
        model.ingest(SampleTraffic.events()[1])
        XCTAssertEqual(model.rows.count, 1)

        model.reloadSessions()
        XCTAssertEqual(model.sessions.map(\.name), ["Tuesday", "Monday"])
        let saved = try XCTUnwrap(model.sessions.last)
        XCTAssertEqual(saved.eventCount, mondayCount)
        XCTAssertGreaterThan(saved.kindCounts["http"] ?? 0, 0)
        XCTAssertGreaterThan(saved.kindCounts["mqtt"] ?? 0, 0)
        XCTAssertNotNil(saved.lastEventAt)
        XCTAssertTrue(model.isLive(model.sessions[0]))

        model.openSession(monday)
        XCTAssertEqual(model.viewedSession?.name, "Monday")
        XCTAssertEqual(model.rows.count, mondayCount)
        XCTAssertNotEqual(model.topicTree, TopicTree(), "the topic tree is rebuilt from the saved packets")
        model.searchText = "kitchen"
        XCTAssertFalse(model.visibleRows.isEmpty, "search runs on the session on screen")
        model.searchText = ""

        // Live traffic keeps landing in Tuesday, behind the saved session.
        model.ingest(SampleTraffic.events()[1])
        XCTAssertEqual(model.rows.count, mondayCount)
        XCTAssertEqual(model.liveTimeline.count, 2)
        XCTAssertFalse(try model.exportHAR().isEmpty)

        model.returnToLive()
        XCTAssertNil(model.viewedSession)
        XCTAssertEqual(model.rows.count, 2)

        model.renameSession(monday, to: "  Login bug  ")
        XCTAssertEqual(model.sessions.last?.name, "Login bug")
        model.openSession(monday)
        model.deleteSession(monday)
        XCTAssertNil(model.viewedSession, "deleting the session on screen goes back to live")
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.sessions.map(\.name), ["Tuesday"])
        model.deleteSession(store.currentSession)
        XCTAssertEqual(model.sessions.count, 1, "the live session can't be deleted")
    }

    func testEmptySessionsFromEarlierLaunchesAreRemoved() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Empty-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try CaptureStore(path: path, sessionName: "Kept")
        first.record(SampleTraffic.events()[1])
        _ = try CaptureStore(path: path, sessionName: "Empty launch")
        let latest = try CaptureStore(path: path, sessionName: "Now")
        XCTAssertEqual(try latest.deleteEmptySessions(), 1)
        XCTAssertEqual(try latest.sessions().map(\.name), ["Now", "Kept"])
    }
}

final class SystemProxyTests: XCTestCase {
    private final class FakeProxy: SystemProxyControlling, @unchecked Sendable {
        var calls: [String] = []
        var failEnable = false
        func enable(host: String, port: Int, bypass: [String]) async throws {
            calls.append("enable \(host):\(port) \(bypass)")
            if failEnable { throw CocoaError(.featureUnsupported) }
        }
        func disable() async throws { calls.append("disable") }
    }

    @MainActor
    private func makeModel(_ proxy: FakeProxy, setSystemProxy: Bool) throws -> (CaptureViewModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SysProxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = EngineConfiguration()
        configuration.proxyPort = 0
        configuration.setSystemProxy = setSystemProxy
        configuration.bypassHosts = ["pinned.example"]
        let model = CaptureViewModel(store: try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path),
                                     engine: CaptureEngine(authority: try CertificateAuthority.generate(), threads: 1),
                                     configuration: configuration, systemProxy: proxy)
        return (model, directory)
    }

    @MainActor
    func testSystemProxyFollowsCapture() async throws {
        let proxy = FakeProxy()
        let (model, directory) = try makeModel(proxy, setSystemProxy: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.startCapture()
        let port = try XCTUnwrap(model.proxyPort)
        XCTAssertTrue(model.systemProxyActive)
        await model.stopCapture()
        XCTAssertFalse(model.systemProxyActive)
        XCTAssertEqual(proxy.calls, ["enable 127.0.0.1:\(port) [\"pinned.example\"]", "disable"])
    }

    @MainActor
    func testSystemProxyOffByDefaultAndFailuresDontStopCapture() async throws {
        let proxy = FakeProxy()
        let (model, directory) = try makeModel(proxy, setSystemProxy: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.startCapture()
        await model.stopCapture()
        XCTAssertEqual(proxy.calls, [])

        model.configuration.setSystemProxy = true
        proxy.failEnable = true
        await model.startCapture()
        XCTAssertTrue(model.isCapturing)
        XCTAssertFalse(model.systemProxyActive)
        XCTAssertNotNil(model.lastError)
        await model.stopCapture()
        XCTAssertEqual(proxy.calls.count, 1) // nothing to disable
    }

    func testOldSavedConfigurationStillDecodes() throws {
        let saved = #"{"proxyPort":8888,"allowRemoteDevices":true,"decryptHTTPS":false,"bypassHosts":["a.example"],"forwarders":[]}"#
        let configuration = try JSONDecoder().decode(EngineConfiguration.self, from: Data(saved.utf8))
        XCTAssertEqual(configuration.proxyPort, 8888)
        XCTAssertFalse(configuration.setSystemProxy)
    }
}
