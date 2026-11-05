@testable import AppCore
import CaptureStore
import Foundation
import Licensing
import MQTTCore
import ProxyCore
import XCTest

final class FreeTierLimitTests: XCTestCase {
    // MARK: Policy

    func testEntitlementLimits() {
        XCTAssertNil(Entitlement.pro(coveredUntil: .distantFuture).limits())
        XCTAssertEqual(Entitlement.free(.noLicense).limits(), FreeLimits(activeRules: 1, replaysPerSession: 5))
        XCTAssertEqual(Entitlement.free(.revoked).limits(), FreeLimits(activeRules: 1, replaysPerSession: 5),
                       "a lapsed license falls back to the free limits, not to nothing")
        let policy = LicensePolicy(freeActiveRules: 2, freeReplaysPerSession: 3)
        XCTAssertEqual(Entitlement.free(.noLicense).limits(policy), FreeLimits(activeRules: 2, replaysPerSession: 3))
        XCTAssertEqual(ProFeature.breakpoints.freeAllowance(.standard), "Free runs 1 rule at a time")
    }

    // MARK: Rules

    @MainActor
    func testFreeRunsOneBreakpointAndRefusesASecond() async {
        let first = BreakpointRule(pattern: "a.example.com/*")
        let center = BreakpointCenter(rules: [first])
        XCTAssertEqual(center.limit, 1)
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://a.example.com/x"), [.request, .response])

        center.rules.append(BreakpointRule(pattern: "b.example.com/*"))
        XCTAssertEqual(center.rules.count, 2, "the new rule is kept")
        XCTAssertFalse(center.rules[1].isEnabled, "and switched off")
        XCTAssertEqual(center.limitPrompt?.reason, .ruleLimit(.breakpoint, limit: 1))
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://b.example.com/x"), [])

        // Turning the first off frees the slot for the second.
        center.rules[0].isEnabled = false
        center.rules[1].isEnabled = true
        XCTAssertTrue(center.rules[1].isEnabled)
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://b.example.com/x"), [.request, .response])
    }

    @MainActor
    func testDowngradeKeepsRulesOnAndRunsTheFirst() async {
        let rules = [BreakpointRule(pattern: "a.example.com/*"), BreakpointRule(pattern: "b.example.com/*")]
        let center = BreakpointCenter(rules: rules)
        center.limit = nil
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://b.example.com/x"), [.request, .response])

        center.limit = 1
        XCTAssertTrue(center.rules.allSatisfy(\.isEnabled), "nothing the user turned on is switched off")
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://a.example.com/x"), [.request, .response])
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://b.example.com/x"), [], "past the limit it waits for Pro")
        XCTAssertEqual(center.heldRuleIDs, [rules[1].id])
        XCTAssertNil(center.limitPrompt)

        // Editing a held rule doesn't switch it off.
        center.rules[1].pattern = "c.example.com/*"
        XCTAssertTrue(center.rules[1].isEnabled)

        center.limit = nil
        XCTAssertTrue(center.heldRuleIDs.isEmpty)
        XCTAssertEqual(center.handler.stages(method: "GET", url: "https://c.example.com/x"), [.request, .response])
    }

    @MainActor
    func testRewriteLimitIsPerKind() async {
        let center = RewriteCenter()
        center.addHTTPRule(kind: .mapLocal, pattern: "a/*")
        center.addHTTPRule(kind: .rewrite, pattern: "a/*")
        center.addHTTPRule(kind: .mapRemote, pattern: "a/*")
        center.addMQTTRule(topicFilter: "x/#")
        XCTAssertTrue(center.httpRules.allSatisfy(\.isEnabled), "one of each kind fits")
        XCTAssertTrue(center.mqttRules.allSatisfy(\.isEnabled))
        XCTAssertNil(center.limitPrompt)
        XCTAssertEqual(center.rules.http.count, 3)

        center.addHTTPRule(kind: .mapLocal, pattern: "b/*")
        XCTAssertFalse(center.httpRules[3].isEnabled)
        XCTAssertEqual(center.limitPrompt?.reason, .ruleLimit(.mapLocal, limit: 1))

        center.limitPrompt = nil
        center.duplicate(.mqtt(center.mqttRules[0].id))
        XCTAssertFalse(center.mqttRules[1].isEnabled, "a duplicate counts as a new rule")
        XCTAssertEqual(center.limitPrompt?.reason, .ruleLimit(.mqttRewrite, limit: 1))

        center.limit = nil
        center.httpRules[3].isEnabled = true
        XCTAssertTrue(center.httpRules[3].isEnabled)
        XCTAssertEqual(center.rules.http.count, 4)
    }

    @MainActor
    func testFreeRunsOneScript() async {
        let center = ScriptCenter(makeEngine: { _ in nil })
        center.addScript(.httpBoth)
        center.addScript(.mqttPayload)
        XCTAssertTrue(center.scripts[0].isEnabled)
        XCTAssertFalse(center.scripts[1].isEnabled)
        XCTAssertEqual(center.limitPrompt?.reason, .ruleLimit(.script, limit: 1))
        XCTAssertEqual(center.runningScripts.map(\.id), [center.scripts[0].id])
    }

    // MARK: MQTT replay

    private func capture(topic: String = "home/light", payload: String = "{\"on\":true}") -> MQTTCaptureEvent {
        let publish = MQTTPublish(topic: topic, payload: Array(payload.utf8), qos: .atLeastOnce, retain: false, packetIdentifier: 7,
                                  properties: [.contentType("application/json"), .userProperty(key: "unit", value: "C")])
        let bytes = try! MQTTPacketEncoder.encode(.publish(publish), version: .v5)
        return MQTTCaptureEvent(connectionID: UUID(), timestamp: Date(), broker: "127.0.0.1:1",
                                event: MQTTSessionEvent(direction: .clientToBroker, version: .v5,
                                                        frame: MQTTFrame(packet: .publish(publish), rawBytes: bytes), resolvedTopic: topic))
    }

    @MainActor
    func testFreeResendsCapturedMessagesUnchangedFiveTimesPerSession() async {
        var saved: [UUID: Int] = [:]
        let composer = MQTTComposer(publisher: nil, saveReplayCounts: { saved = $0 })
        let session = UUID()
        composer.replaySession = session

        composer.preparePublish(toTopic: "home/light", broker: nil, version: nil, forwarders: [])
        XCTAssertEqual(composer.freeTierBlock, .newMessage)

        composer.prepareReplay(of: capture(), forwarders: [])
        XCTAssertNil(composer.freeTierBlock)
        XCTAssertNil(composer.problem)

        composer.payloadText = "{\"on\":false}"
        XCTAssertEqual(composer.freeTierBlock, .editedReplay)
        composer.revertToCaptured()
        XCTAssertNil(composer.freeTierBlock)

        composer.retain = true
        XCTAssertEqual(composer.freeTierBlock, .editedReplay)
        composer.retain = false

        composer.repeatCount = 6
        XCTAssertEqual(composer.freeTierBlock, .replayLimit(5), "a repeat run counts every message")
        composer.repeatCount = 1
        XCTAssertEqual(composer.replaysLeft, 5)
        XCTAssertTrue(saved.isEmpty)
    }

    @MainActor
    func testReplayCountsAndSavedSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeTier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = try CertificateStorage(directory: directory).loadOrCreate()
        let engine = CaptureEngine(authority: authority, threads: 1)
        let store = try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path)
        let model = CaptureViewModel(store: store, engine: engine)
        model.apply(.free(.noLicense))
        let composer = model.composer
        composer.target = MQTTBrokerTarget(host: "127.0.0.1", port: 1) // nothing listens: fails fast

        composer.prepareReplay(of: capture(), forwarders: [])
        for sent in 1...5 {
            XCTAssertNil(composer.problem, "replay \(sent)")
            composer.send()
            for _ in 0..<400 where composer.isSending { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(composer.replaysUsed, sent)
        }
        XCTAssertEqual(composer.freeTierBlock, .replayLimit(5))
        composer.send()
        XCTAssertFalse(composer.isSending)

        model.newSession(named: "Next")
        XCTAssertEqual(composer.replaysUsed, 0, "a new session starts a new count")
        XCTAssertNil(composer.freeTierBlock)

        composer.prepareReplay(of: capture(), forwarders: [], fromSavedSession: true)
        XCTAssertEqual(composer.freeTierBlock, .savedSessionReplay)

        model.apply(.pro(coveredUntil: .distantFuture))
        XCTAssertNil(composer.freeTierBlock)
        composer.topic = "home/other"
        XCTAssertNil(composer.problem, "Pro edits freely")
    }
}
