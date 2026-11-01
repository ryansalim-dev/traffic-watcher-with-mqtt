@testable import AppCore
import CaptureStore
import Foundation
import Licensing
import MQTTCore
import ProxyCore
import XCTest

final class BreakpointCenterTests: XCTestCase {
    private let request = HTTPRequestDraft(method: "GET", url: "https://api.example.com/v2/devices?page=1",
                                           headers: [CapturedHeader(name: "Accept", value: "*/*")], body: [])

    @MainActor
    private func waitForPause(_ center: BreakpointCenter, count: Int = 1) async {
        for _ in 0..<200 where center.paused.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    func testOnlyPausesWhenAllowedAndEnabled() async {
        let center = BreakpointCenter(rules: [BreakpointRule(pattern: "api.example.com/*")])
        XCTAssertEqual(center.handler.stages(method: "GET", url: request.url), [], "free tier never pauses")
        center.isAllowed = true
        XCTAssertEqual(center.handler.stages(method: "GET", url: request.url), [.request, .response])
        center.isEnabled = false
        XCTAssertEqual(center.handler.stages(method: "GET", url: request.url), [])
    }

    @MainActor
    func testResumeWithEditsAbortAndUnchanged() async {
        let center = BreakpointCenter(rules: [BreakpointRule(pattern: "*")])
        center.isAllowed = true
        let handler = center.handler
        let request = self.request

        let edited = Task { await handler.editRequest(request) }
        await waitForPause(center)
        XCTAssertEqual(center.paused.first?.stage, .request)
        var changed = request
        changed.method = "DELETE"
        center.resume(center.paused[0].id, request: changed)
        let editedResult = await edited.value
        XCTAssertEqual(editedResult, .proceed(changed))
        XCTAssertTrue(center.paused.isEmpty)

        let response = HTTPResponseDraft(statusCode: 200, headers: [], body: Array("ok".utf8))
        let aborted = Task { await handler.editResponse(response, for: request) }
        await waitForPause(center)
        XCTAssertEqual(center.paused.first?.response, response)
        center.abort(center.paused[0].id)
        let abortedResult = await aborted.value
        XCTAssertEqual(abortedResult, .abort)

        let untouched = Task { await handler.editResponse(response, for: request) }
        await waitForPause(center)
        center.isEnabled = false // switching off lets everything continue
        let untouchedResult = await untouched.value
        XCTAssertEqual(untouchedResult, .proceed(response))
    }

    @MainActor
    func testTimeoutContinuesUnchanged() async {
        let center = BreakpointCenter(rules: [BreakpointRule(pattern: "*")], timeout: .milliseconds(50))
        center.isAllowed = true
        let request = self.request
        let handler = center.handler
        let result = await handler.editRequest(request)
        XCTAssertEqual(result, .proceed(request))
        XCTAssertTrue(center.paused.isEmpty)
    }

    @MainActor
    func testAddRuleFromURLAndPersistence() async {
        var saved: [BreakpointRule] = []
        let center = BreakpointCenter(save: { saved = $0 })
        let rule = center.addRule(for: request.url, method: "GET")
        XCTAssertEqual(rule.pattern, "https://api.example.com/v2/devices*")
        XCTAssertTrue(rule.matches(method: "GET", url: "https://api.example.com/v2/devices?page=2"))
        center.addRule(for: request.url, method: "GET")
        XCTAssertEqual(center.rules.count, 1, "same URL and method reuses the rule")
        XCTAssertEqual(saved, center.rules)
    }

    func testHeaderTextRoundTrip() async {
        let headers = [CapturedHeader(name: "Content-Type", value: "application/json"), CapturedHeader(name: "X-Time", value: "12:30")]
        XCTAssertEqual(HeaderText.parse(HeaderText.format(headers)), headers)
        XCTAssertEqual(HeaderText.parse("  A :  b \nno colon\n: empty\n\nC:"), [CapturedHeader(name: "A", value: "b"), CapturedHeader(name: "C", value: "")])
    }
}

final class MQTTComposerTests: XCTestCase {
    private func publishCapture(broker: String, topic: String = "home/kitchen/temperature", payload: [UInt8] = Array("21.5".utf8),
                                version: MQTTVersion = .v5) -> MQTTCaptureEvent {
        let publish = MQTTPublish(topic: topic, payload: payload, qos: .atLeastOnce, retain: true, packetIdentifier: 4,
                                  properties: version == .v5 ? [.contentType("text/plain"), .userProperty(key: "unit", value: "C")] : [])
        let bytes = try! MQTTPacketEncoder.encode(.publish(publish), version: version)
        return MQTTCaptureEvent(connectionID: UUID(), timestamp: Date(), broker: broker,
                                event: MQTTSessionEvent(direction: .clientToBroker, version: version,
                                                        frame: MQTTFrame(packet: .publish(publish), rawBytes: bytes), resolvedTopic: topic))
    }

    @MainActor
    func testReplayFillsMessageAndBrokerFromForwarder() async {
        let composer = MQTTComposer(publisher: nil)
        let forwarders = [ForwarderConfiguration(brokerHost: "iot.example.net", listenPort: 18831, useTLS: true)]
        composer.prepareReplay(of: publishCapture(broker: "iot.example.net:8883"), forwarders: forwarders)
        XCTAssertEqual(composer.topic, "home/kitchen/temperature")
        XCTAssertEqual(composer.payloadText, "21.5")
        XCTAssertEqual(composer.payloadFormat, .text)
        XCTAssertEqual(composer.qos, .atLeastOnce)
        XCTAssertTrue(composer.retain)
        XCTAssertEqual(composer.contentType, "text/plain")
        XCTAssertEqual(composer.userProperties, [.init(key: "unit", value: "C")])
        XCTAssertEqual(composer.target.host, "iot.example.net")
        XCTAssertEqual(composer.target.port, 8883)
        XCTAssertTrue(composer.target.useTLS)
        XCTAssertEqual(composer.target.version, .v5)

        composer.prepareReplay(of: publishCapture(broker: "10.0.0.2:1883", payload: [0x00, 0xFF, 0x10], version: .v3_1_1), forwarders: forwarders)
        XCTAssertEqual(composer.payloadFormat, .hex)
        XCTAssertEqual(composer.payloadText, "00 ff 10")
        XCTAssertEqual(composer.payload, [0x00, 0xFF, 0x10])
        XCTAssertEqual(composer.target.host, "10.0.0.2")
        XCTAssertFalse(composer.target.useTLS)
    }

    @MainActor
    func testProblemsGateSending() async {
        let composer = MQTTComposer(publisher: nil)
        composer.topic = "a/b"
        XCTAssertEqual(composer.problem, "Publishing and replay are part of Pro.")
        composer.isAllowed = true
        XCTAssertNil(composer.problem)
        composer.topic = "a/+"
        XCTAssertNotNil(composer.problem)
        composer.topic = "a/b"
        composer.payloadFormat = .hex
        composer.payloadText = "abc"
        XCTAssertEqual(composer.problem, "The payload isn't valid hex.")
        composer.payloadText = "0xAB:cd"
        XCTAssertEqual(composer.payload, [0xAB, 0xCD])
        composer.repeatCount = 0
        XCTAssertNotNil(composer.problem)
    }

    @MainActor
    func testSendIsGatedByProAndReportsConnectionFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProFeatureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = try CertificateStorage(directory: directory).loadOrCreate()
        let engine = CaptureEngine(authority: authority, threads: 1)
        let model = CaptureViewModel(store: try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path), engine: engine)

        // Nothing listens on port 1, so the connection fails fast; the publisher's success path is covered in ProxyCoreTests.
        model.composer.target = MQTTBrokerTarget(host: "127.0.0.1", port: 1)
        model.composer.topic = "t"
        model.apply(.free(.noLicense))
        model.composer.send()
        XCTAssertFalse(model.composer.isSending, "free tier can't send")

        model.apply(.pro(coveredUntil: .distantFuture))
        XCTAssertTrue(model.breakpoints.isAllowed)
        model.composer.send()
        XCTAssertTrue(model.composer.isSending)
        for _ in 0..<400 where model.composer.isSending { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed? = model.composer.status else { return XCTFail("\(String(describing: model.composer.status))") }
    }

    @MainActor
    func testModelPreparesReplayAndBreakpointsFromRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProFeatureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CaptureViewModel(store: try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path), engine: nil)
        for event in SampleTraffic.events() { model.ingest(event) }

        let publishRow = try XCTUnwrap(model.rows.first { $0.kind == .mqtt && $0.badge == "PUBLISH" })
        XCTAssertTrue(model.prepareReplay(of: publishRow))
        XCTAssertFalse(model.composer.topic.isEmpty)
        let httpRow = try XCTUnwrap(model.rows.first { $0.kind == .http })
        XCTAssertFalse(model.prepareReplay(of: httpRow))
        let rule = try XCTUnwrap(model.addBreakpoint(for: httpRow))
        guard case .httpExchange(let exchange) = httpRow.event else { return XCTFail() }
        XCTAssertTrue(rule.matches(method: exchange.method, url: exchange.url))

        model.preparePublish(toTopic: model.composer.topic)
        XCTAssertEqual(model.composer.payloadText, "")
    }
}
