@testable import AppCore
import CaptureStore
import Foundation
import MQTTCore
import ProxyCore
import XCTest

private final class EchoEngine: ScriptEngine, @unchecked Sendable {
    let output: String
    init(_ output: String) { self.output = output }
    func call(_ hook: ScriptHook, script: UserScript, input: String) -> ScriptCallResult { .output(output) }
}

final class ScriptCenterTests: XCTestCase {
    @MainActor
    func testScriptsReachTheProxyOnlyWithTheSwitchOn() async {
        let script = UserScript(name: "S", source: "function onRequest(r) {}", urlPattern: "*")
        let second = UserScript(name: "T", source: "function onRequest(r) {}", urlPattern: "*")
        let center = ScriptCenter(settings: ScriptSettings(scripts: [script, second]), makeEngine: { _ in EchoEngine("{}") })
        XCTAssertEqual(center.live.snapshot?.scripts, [script], "free tier runs one script")
        center.limit = nil
        XCTAssertEqual(center.live.snapshot?.scripts, [script, second])
        center.scripts.removeLast()
        XCTAssertEqual(center.live.snapshot?.scripts, [script])
        center.isEnabled = false
        XCTAssertNil(center.live.snapshot)
        center.isEnabled = true
        center.scripts[0].isEnabled = false
        XCTAssertNil(center.live.snapshot)
        XCTAssertEqual(center.enabledCount, 0)
    }

    @MainActor
    func testEditsAreSavedAndSettingsRoundTrip() async throws {
        var saved: ScriptSettings?
        let center = ScriptCenter(makeEngine: { _ in nil }, save: { saved = $0 })
        let added = center.addScript(.mqttPayload)
        XCTAssertEqual(center.selection, added.id)
        XCTAssertEqual(added.topicFilter, "home/#")
        XCTAssertEqual(added.definedHooks, [.publish])
        center.duplicate(added.id)
        XCTAssertEqual(center.scripts.map(\.name), ["Transform payloads", "Transform payloads copy"])
        center.remove(added.id)
        XCTAssertEqual(saved, center.settings)
        let decoded = try JSONDecoder().decode(ScriptSettings.self, from: JSONEncoder().encode(center.settings))
        XCTAssertEqual(decoded, center.settings)
        XCTAssertEqual(try JSONDecoder().decode(ScriptSettings.self, from: Data("{}".utf8)), ScriptSettings())
    }

    @MainActor
    func testTemplatesDefineTheirHooks() async {
        let expected: [ScriptTemplate: Set<ScriptHook>] = [
            .blank: [.request, .response, .publish], .addHeader: [.request], .editJSONResponse: [.response],
            .mockResponse: [.request], .httpBoth: [.request, .response], .mqttPayload: [.publish],
        ]
        for template in ScriptTemplate.allCases {
            XCTAssertEqual(template.script.definedHooks, expected[template], template.title)
        }
    }

    @MainActor
    func testStartingFromAnExchangeAndATopic() async {
        let center = ScriptCenter(makeEngine: { _ in nil })
        let exchange = HTTPExchange(startedAt: Date(), duration: 0.1, method: "GET", url: "https://api.example.com/v2/devices?page=1",
                                    requestHeaders: [], requestBody: [], statusCode: 200, responseHeaders: [], responseBody: [])
        let script = center.addScript(for: exchange)
        XCTAssertEqual(script.urlPattern, "https://api.example.com/v2/devices*")
        XCTAssertEqual(script.method, "GET")
        XCTAssertEqual(script.name, "Script for /v2/devices")
        XCTAssertEqual(center.addScript(forTopic: "home/kitchen/temperature").topicFilter, "home/kitchen/temperature")
    }

    @MainActor
    func testLogIsCappedAndConsoleOutputArrives() async {
        let center = ScriptCenter(makeEngine: { _ in nil })
        let entries = (0..<(ScriptCenter.logLimit + 10)).map {
            ScriptLogEntry(level: .log, scriptID: nil, scriptName: "S", context: "", message: "\($0)")
        }
        center.append(entries)
        XCTAssertEqual(center.log.count, ScriptCenter.logLimit)
        XCTAssertEqual(center.log.first?.message, "10")
        center.clearLog()
        XCTAssertTrue(center.log.isEmpty)
    }

    @MainActor
    func testTestRunReportsWhatChanged() async {
        let engine = EchoEngine(#"{"logs":[["log","hi"]],"request":{"headers":[["X-Debug","1"]],"body":null}}"#)
        let center = ScriptCenter(makeEngine: { _ in engine })
        let script = UserScript(name: "Sign", source: "function onRequest(r) {}", urlPattern: "*")
        let exchange = HTTPExchange(startedAt: Date(), duration: 0.1, method: "GET", url: "https://api.example.com/x",
                                    requestHeaders: [CapturedHeader(name: "Accept", value: "*/*")], requestBody: [], statusCode: 200,
                                    responseHeaders: [], responseBody: [])
        let entries = ScriptCenter.testEntries(script, on: .httpExchange(exchange), makeEngine: { _ in engine })
        XCTAssertEqual(entries.map(\.message), ["hi", "Changed headers Accept, X-Debug"])
        XCTAssertEqual(entries.last?.context, "Test · onRequest")

        let nothing = ScriptCenter.testEntries(UserScript(name: "N", source: "", urlPattern: "*"), on: .httpExchange(exchange),
                                               makeEngine: { _ in engine })
        XCTAssertEqual(nothing.map(\.message), ["Define onRequest(request) or onResponse(request, response) to handle HTTP"])
        _ = center
    }

    @MainActor
    func testEntitlementUnlocksScripting() async {
        let center = ScriptCenter(makeEngine: { _ in nil })
        let model = CaptureViewModel(store: try! CaptureStore(path: ":memory:"), engine: nil, scripts: center)
        model.apply(.pro(coveredUntil: .distantFuture))
        XCTAssertNil(center.limit)
        model.apply(.free(.noLicense))
        XCTAssertEqual(center.limit, 1)
    }

    func testJavaScriptHighlighting() {
        let source = "// hi\nfunction onRequest(r) { r.headers[\"X\"] = 'a' + 42; return null; /* c */ }"
        let tokens = JavaScriptHighlighter.tokens(source)
        XCTAssertEqual(tokens.map(\.text).joined(), source, "tokens join back into the source")
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.map(\.text), ["// hi", "/* c */"])
        XCTAssertEqual(tokens.filter { $0.kind == .keyword }.map(\.text), ["function", "return"])
        XCTAssertEqual(tokens.filter { $0.kind == .string }.map(\.text), ["\"X\"", "'a'"])
        XCTAssertEqual(tokens.filter { $0.kind == .number }.map(\.text), ["42"])
        XCTAssertEqual(tokens.filter { $0.kind == .key }.map(\.text), ["onRequest"])
        XCTAssertEqual(tokens.filter { $0.kind == .literal }.map(\.text), ["null"])
        XCTAssertTrue(JavaScriptHighlighter.tokens("request.return").allSatisfy { $0.kind == .plain }, "properties aren't keywords")
        XCTAssertEqual(JavaScriptHighlighter.tokens("`a\nb`").map(\.kind), [.string], "template literals span lines")
    }
}
