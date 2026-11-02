@testable import AppCore
import CaptureStore
import Foundation
import Licensing
import MQTTCore
import ProxyCore
import XCTest

final class RewriteCenterTests: XCTestCase {
    @MainActor
    func testRulesReachTheProxyOnlyWithProAndTheSwitchOn() async {
        let rule = HTTPRule(pattern: "*", kind: .mapLocal)
        let center = RewriteCenter(settings: RewriteSettings(http: [rule], mqtt: [MQTTRule(topicFilter: "#")]))
        XCTAssertTrue(center.rules.http.isEmpty, "free tier keeps rules but applies none")
        center.isAllowed = true
        XCTAssertEqual(center.rules.http, [rule])
        XCTAssertEqual(center.rules.mqtt.count, 1)
        center.isEnabled = false
        XCTAssertTrue(center.rules.http.isEmpty)
        XCTAssertTrue(center.rules.mqtt.isEmpty)
        center.isEnabled = true
        center.httpRules[0].isEnabled = false
        XCTAssertTrue(center.rules.http.isEmpty, "disabled rules are left out")
        XCTAssertEqual(center.enabledCount, 1)
    }

    @MainActor
    func testEditsAreSavedAndSettingsRoundTrip() async throws {
        var saved: RewriteSettings?
        let center = RewriteCenter(save: { saved = $0 })
        center.addHTTPRule(kind: .mapRemote, pattern: "api.example.com/*")
        center.addMQTTRule(topicFilter: "home/#")
        center.isEnabled = false
        XCTAssertEqual(saved, center.settings)
        XCTAssertEqual(saved?.http.first?.kind, .mapRemote)
        XCTAssertEqual(center.selection, .mqtt(center.mqttRules[0].id))
        let decoded = try JSONDecoder().decode(RewriteSettings.self, from: JSONEncoder().encode(center.settings))
        XCTAssertEqual(decoded, center.settings)
        XCTAssertEqual(try JSONDecoder().decode(RewriteSettings.self, from: Data("{}".utf8)), RewriteSettings())
    }

    @MainActor
    func testMapLocalStartsFromTheCapturedResponse() async {
        let exchange = HTTPExchange(
            startedAt: Date(), duration: 0.2, method: "GET", url: "https://api.example.com/v2/devices?page=1",
            requestHeaders: [], requestBody: [], statusCode: 200,
            responseHeaders: [CapturedHeader(name: "Content-Type", value: "application/json"),
                              CapturedHeader(name: "Content-Length", value: "9"),
                              CapturedHeader(name: "Content-Encoding", value: "br")],
            responseBody: Array(#"{"a":[1]}"#.utf8))
        let center = RewriteCenter()
        let rule = center.addMapLocal(from: exchange)
        XCTAssertEqual(rule.kind, .mapLocal)
        XCTAssertEqual(rule.pattern, "https://api.example.com/v2/devices*")
        XCTAssertEqual(rule.method, "GET")
        XCTAssertEqual(rule.name, "Mock /v2/devices")
        XCTAssertEqual(rule.mapLocal.headers, [CapturedHeader(name: "Content-Type", value: "application/json")])
        XCTAssertTrue(rule.mapLocal.body.contains("\"a\""))

        let remote = center.addMapRemote(from: exchange)
        XCTAssertEqual(remote.pattern, "https://api.example.com/*")
        XCTAssertEqual(center.httpRules.count, 2)

        center.duplicate(.http(remote.id))
        XCTAssertEqual(center.httpRules.count, 3)
        XCTAssertEqual(center.httpRules[2].pattern, remote.pattern)
        center.remove(.http(remote.id))
        XCTAssertEqual(center.httpRules.count, 2)
    }

    @MainActor
    func testModelGatesWithTheLicenseAndCountsMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path)
        let model = CaptureViewModel(store: store, engine: nil)
        model.ingest(.httpExchange(HTTPExchange(startedAt: Date(), duration: 0.1, method: "GET", url: "https://api.example.com/v2/a",
                                                requestHeaders: [], requestBody: [], statusCode: 200, responseHeaders: [], responseBody: [])))
        model.ingest(.httpExchange(HTTPExchange(startedAt: Date(), duration: 0.1, method: "POST", url: "https://other.example.com/",
                                                requestHeaders: [], requestBody: [], statusCode: 200, responseHeaders: [], responseBody: [])))
        model.apply(.pro(coveredUntil: Date().addingTimeInterval(86_400)))
        XCTAssertTrue(model.rewrites.isAllowed)
        model.apply(.free(.noLicense))
        XCTAssertFalse(model.rewrites.isAllowed)

        let rule = try XCTUnwrap(model.addRule(.rewrite, for: model.rows[0]))
        XCTAssertTrue(model.rewrites.isPresented)
        XCTAssertEqual(RewriteCenter.matchingURLs(rule, in: model.rows), ["https://api.example.com/v2/a"])
        XCTAssertNil(model.addRule(.mapLocal, for: TrafficRowFixture.tunnelRow(store: store, model: model)))
    }
}

enum TrafficRowFixture {
    @MainActor
    static func tunnelRow(store: CaptureStore, model: CaptureViewModel) -> TrafficRow {
        model.ingest(.tunnelOpened(TunnelInfo(openedAt: Date(), host: "pinned.example.com", port: 443)))
        return model.rows.last!
    }
}
