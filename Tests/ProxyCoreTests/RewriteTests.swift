import Foundation
import MQTTCore
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyCore
import XCTest

final class URLPatternTests: XCTestCase {
    func testCapturesFollowTheStars() {
        XCTAssertEqual(URLPattern.captures("api.example.com/v2/*", url: "https://api.example.com/v2/devices/42?x=1"), ["devices/42?x=1"])
        XCTAssertEqual(URLPattern.captures("https://*.example.com/*", url: "https://auth.example.com/login"), ["auth", "login"])
        XCTAssertNil(URLPattern.captures("api.example.com/v1/*", url: "https://api.example.com/v2/x"))
        XCTAssertEqual(URLPattern.substitute(["a", "b"], into: "http://x/*/y/*/*"), "http://x/a/y/b/")
    }
}

final class HTTPRewriterTests: XCTestCase {
    private let request = HTTPRequestDraft(
        method: "GET", url: "https://api.example.com/v2/devices?page=1&room=kitchen",
        headers: [CapturedHeader(name: "Host", value: "api.example.com"), CapturedHeader(name: "Accept", value: "*/*")],
        body: [])

    private func rewrite(_ operations: [RewriteOperation]) -> HTTPRewriter.RequestOutcome {
        HTTPRewriter.rewriteRequest(request, rules: [HTTPRule(name: "R", pattern: "api.example.com/*", kind: .rewrite, operations: operations)])
    }

    func testMapRemoteKeepsPathAndQueryForABareOrigin() {
        let rule = HTTPRule(pattern: "api.example.com/*", kind: .mapRemote,
                            mapRemote: MapRemoteDestination(url: "http://localhost:3000"))
        let outcome = HTTPRewriter.rewriteRequest(request, rules: [rule])
        XCTAssertEqual(outcome.request.url, "http://localhost:3000/v2/devices?page=1&room=kitchen")
        XCTAssertEqual(outcome.request.headers.first { $0.name == "Host" }?.value, "localhost:3000")
        XCTAssertEqual(outcome.applied, ["api.example.com/*"])
        XCTAssertNil(outcome.localResponse)
    }

    func testMapRemoteWithPathAndWildcards() {
        let destination = MapRemoteDestination(url: "https://staging.example.com/api/*", preserveHostHeader: true)
        XCTAssertEqual(destination.destination(for: "https://api.example.com/v2/devices?page=1", pattern: "api.example.com/v2/*"),
                       "https://staging.example.com/api/devices?page=1")
        XCTAssertEqual(MapRemoteDestination(url: "https://s.example.com/fixed?debug=1").destination(for: request.url, pattern: "*"),
                       "https://s.example.com/fixed?debug=1")
        XCTAssertEqual(MapRemoteDestination(url: "https://s.example.com/").destination(for: request.url, pattern: "*"),
                       "https://s.example.com/v2/devices?page=1&room=kitchen")
        XCTAssertNil(MapRemoteDestination(url: "localhost:3000").destination(for: request.url, pattern: "*"))

        let rule = HTTPRule(pattern: "api.example.com/v2/*", kind: .mapRemote, mapRemote: destination)
        let outcome = HTTPRewriter.rewriteRequest(request, rules: [rule])
        XCTAssertEqual(outcome.request.headers.first { $0.name == "Host" }?.value, "api.example.com", "Host kept")
    }

    func testMapLocalAnswersWithInlineBodyOrFile() {
        let inline = HTTPRule(name: "Mock", pattern: "*/v2/devices*", method: "GET", kind: .mapLocal,
                              mapLocal: MapLocalResponse(statusCode: 418, body: #"{"mock":true}"#))
        let outcome = HTTPRewriter.rewriteRequest(request, rules: [inline])
        XCTAssertEqual(outcome.localResponse?.statusCode, 418)
        XCTAssertEqual(outcome.localResponse?.body, Array(#"{"mock":true}"#.utf8))
        XCTAssertEqual(outcome.localResponse?.headers, [CapturedHeader(name: "Content-Type", value: "application/json")])
        XCTAssertEqual(outcome.applied, ["Mock"])

        let file = HTTPRule(pattern: "*", kind: .mapLocal, mapLocal: MapLocalResponse(headers: [], filePath: "/mocks/devices.json"))
        let fromFile = HTTPRewriter.rewriteRequest(request, rules: [file]) { path in
            XCTAssertEqual(path, "/mocks/devices.json")
            return Array("[1,2]".utf8)
        }
        XCTAssertEqual(fromFile.localResponse?.body, Array("[1,2]".utf8))
        XCTAssertEqual(fromFile.localResponse?.headers, [CapturedHeader(name: "Content-Type", value: "application/json")])

        struct Missing: Error {}
        let broken = HTTPRewriter.rewriteRequest(request, rules: [file]) { _ in throw Missing() }
        XCTAssertEqual(broken.localResponse?.statusCode, 500)
        XCTAssertTrue(String(decoding: broken.localResponse?.body ?? [], as: UTF8.self).contains("/mocks/devices.json"))
    }

    func testMethodAndDisabledRulesDontMatch() {
        var rule = HTTPRule(pattern: "*", method: "POST", kind: .mapLocal)
        XCTAssertNil(HTTPRewriter.rewriteRequest(request, rules: [rule]).localResponse)
        rule.method = nil
        rule.isEnabled = false
        XCTAssertNil(HTTPRewriter.rewriteRequest(request, rules: [rule]).localResponse)
    }

    func testRequestOperations() {
        let outcome = rewrite([
            RewriteOperation(phase: .request, target: .header, action: .set, name: "accept", value: "application/json"),
            RewriteOperation(phase: .request, target: .header, action: .set, name: "X-Debug", value: "1"),
            RewriteOperation(phase: .request, target: .query, action: .set, name: "page", value: "2 3"),
            RewriteOperation(phase: .request, target: .query, action: .remove, name: "room"),
            RewriteOperation(phase: .request, target: .query, action: .set, name: "limit", value: "50"),
            RewriteOperation(phase: .request, target: .method, action: .set, value: "post"),
            RewriteOperation(phase: .request, target: .body, action: .set, value: "hello"),
            RewriteOperation(phase: .request, target: .url, action: .replace, value: "/v3/", find: "/v2/"),
            // Response-only and ignored here:
            RewriteOperation(phase: .request, target: .status, action: .set, value: "500"),
        ])
        XCTAssertEqual(outcome.request.url, "https://api.example.com/v3/devices?page=2%203&limit=50")
        XCTAssertEqual(outcome.request.method, "POST")
        XCTAssertEqual(outcome.request.body, Array("hello".utf8))
        XCTAssertEqual(outcome.request.headers, [
            CapturedHeader(name: "Host", value: "api.example.com"),
            CapturedHeader(name: "Accept", value: "application/json"),
            CapturedHeader(name: "X-Debug", value: "1"),
        ])
        XCTAssertEqual(outcome.applied, ["R"])
    }

    func testRuleThatChangesNothingIsNotReported() {
        let outcome = rewrite([RewriteOperation(phase: .request, target: .header, action: .remove, name: "Cookie")])
        XCTAssertEqual(outcome.applied, [])
        XCTAssertEqual(outcome.matched.count, 1)
    }

    func testResponseOperations() {
        let rule = HTTPRule(name: "R", pattern: "*", kind: .rewrite, operations: [
            RewriteOperation(phase: .response, target: .status, action: .set, value: "503"),
            RewriteOperation(phase: .response, target: .header, action: .remove, name: "set-cookie"),
            RewriteOperation(phase: .response, target: .header, action: .replace, name: "", value: "max-age=0", find: "max-age=\\d+", useRegex: true),
            RewriteOperation(phase: .response, target: .json, action: .set, name: "user.plan", value: "\"free\""),
            RewriteOperation(phase: .response, target: .json, action: .set, name: "items[1].on", value: "true"),
            RewriteOperation(phase: .response, target: .json, action: .remove, name: "token"),
            RewriteOperation(phase: .response, target: .json, action: .set, name: "flags.beta", value: "yes please"),
        ])
        let response = HTTPResponseDraft(statusCode: 200, headers: [
            CapturedHeader(name: "Content-Type", value: "application/json"),
            CapturedHeader(name: "Set-Cookie", value: "a=b"),
            CapturedHeader(name: "Cache-Control", value: "public, max-age=3600"),
        ], body: Array(#"{"token":"t","user":{"id":7,"plan":"pro"},"items":[{"on":false},{"on":false}]}"#.utf8))
        let (rewritten, applied) = HTTPRewriter.rewriteResponse(response, matched: [rule])
        XCTAssertEqual(applied, ["R"])
        XCTAssertEqual(rewritten.statusCode, 503)
        XCTAssertEqual(rewritten.headers.map(\.name), ["Content-Type", "Cache-Control"])
        XCTAssertEqual(rewritten.headers.last?.value, "public, max-age=0")
        XCTAssertEqual(String(decoding: rewritten.body, as: UTF8.self),
                       #"{"flags":{"beta":"yes please"},"items":[{"on":false},{"on":true}],"user":{"id":7,"plan":"free"}}"#)
    }

    func testBodyReplaceSkipsCompressedBodiesAndSetDropsEncoding() {
        let gzipped = HTTPResponseDraft(statusCode: 200, headers: [CapturedHeader(name: "Content-Encoding", value: "gzip")], body: [0x1F, 0x8B, 0x08])
        let replace = HTTPRule(pattern: "*", kind: .rewrite, operations: [RewriteOperation(target: .body, action: .replace, value: "x", find: "\u{1F}")])
        XCTAssertEqual(HTTPRewriter.rewriteResponse(gzipped, matched: [replace]).0, gzipped)

        let set = HTTPRule(pattern: "*", kind: .rewrite, operations: [RewriteOperation(target: .body, action: .set, value: "plain")])
        let (rewritten, _) = HTTPRewriter.rewriteResponse(gzipped, matched: [set])
        XCTAssertEqual(rewritten.body, Array("plain".utf8))
        XCTAssertTrue(rewritten.headers.isEmpty)
    }

    func testRulesDecodeWithMissingKeys() throws {
        let rule = try JSONDecoder().decode(HTTPRule.self, from: Data(#"{"pattern":"a/*","kind":"mapLocal"}"#.utf8))
        XCTAssertEqual(rule.kind, .mapLocal)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.mapLocal.statusCode, 200)
        let full = HTTPRule(name: "x", pattern: "p", method: "GET", kind: .rewrite,
                            operations: [RewriteOperation(target: .json, action: .remove, name: "a.b")])
        XCTAssertEqual(try JSONDecoder().decode(HTTPRule.self, from: JSONEncoder().encode(full)), full)
    }

    func testJSONPaths() {
        XCTAssertEqual(JSONPath.parse("items[0].id"), [.key("items"), .index(0), .key("id")])
        XCTAssertEqual(JSONPath.parse("a.2.b"), [.key("a"), .index(2), .key("b")])
        XCTAssertEqual(JSONPath.parse("[3]"), [.index(3)])
    }
}

final class MQTTRewriteTests: XCTestCase {
    func testTopicFilters() {
        XCTAssertTrue(MQTTTopicFilter.matches("home/+/temperature", topic: "home/kitchen/temperature"))
        XCTAssertFalse(MQTTTopicFilter.matches("home/+/temperature", topic: "home/kitchen/oven/temperature"))
        XCTAssertTrue(MQTTTopicFilter.matches("home/#", topic: "home"))
        XCTAssertTrue(MQTTTopicFilter.matches("home/#", topic: "home/a/b"))
        XCTAssertTrue(MQTTTopicFilter.matches("#", topic: "a"))
        XCTAssertFalse(MQTTTopicFilter.matches("#", topic: "$SYS/uptime"))
        XCTAssertTrue(MQTTTopicFilter.matches("$SYS/#", topic: "$SYS/uptime"))
        XCTAssertFalse(MQTTTopicFilter.matches("a/b", topic: "a/b/c"))
        XCTAssertFalse(MQTTTopicFilter.matches("", topic: "a"))
    }

    func testRewritesTopicPayloadAndRetain() {
        let publish = MQTTPublish(topic: "home/kitchen/temperature", payload: Array(#"{"celsius":21.5}"#.utf8),
                                  qos: .atLeastOnce, packetIdentifier: 9)
        let rule = MQTTRule(name: "Hot kitchen", topicFilter: "home/+/temperature", direction: .brokerToClient, operations: [
            MQTTRewriteOperation(target: .json, action: .set, name: "celsius", value: "48"),
            MQTTRewriteOperation(target: .topic, action: .replace, value: "/test/", find: "/kitchen/"),
            MQTTRewriteOperation(target: .retain, value: "true"),
        ])
        XCTAssertNil(MQTTRewriter.rewrite(publish, resolvedTopic: publish.topic, direction: .clientToBroker, rules: [rule]),
                     "wrong direction")
        let result = MQTTRewriter.rewrite(publish, resolvedTopic: publish.topic, direction: .brokerToClient, rules: [rule])
        XCTAssertEqual(result?.publish.topic, "home/test/temperature")
        XCTAssertEqual(result?.topic, "home/test/temperature")
        XCTAssertEqual(result?.publish.payload, Array(#"{"celsius":48}"#.utf8))
        XCTAssertEqual(result?.publish.retain, true)
        XCTAssertEqual(result?.publish.packetIdentifier, 9)
        XCTAssertEqual(result?.applied, ["Hot kitchen"])
    }

    func testRefusesWildcardTopicsAndKeepsAliasOnlyPackets() {
        let rule = MQTTRule(topicFilter: "#", operations: [MQTTRewriteOperation(target: .topic, value: "a/+")])
        let publish = MQTTPublish(topic: "x", payload: [])
        XCTAssertNil(MQTTRewriter.rewrite(publish, resolvedTopic: "x", direction: .clientToBroker, rules: [rule]))

        let aliased = MQTTPublish(topic: "", payload: [], properties: [.topicAlias(3)])
        let rename = MQTTRule(topicFilter: "x", operations: [MQTTRewriteOperation(target: .topic, value: "y")])
        let result = MQTTRewriter.rewrite(aliased, resolvedTopic: "x", direction: .clientToBroker, rules: [rename])
        XCTAssertEqual(result?.publish.topic, "", "alias-only packets keep their empty wire topic")
        XCTAssertEqual(result?.topic, "y")
    }

    func testRelayHoldsPartialPacketsAndRewrites() throws {
        let log = CaptureLog()
        let rules = LiveRules()
        let relay = MQTTRelay(sink: log, broker: "b:1883", rules: rules)
        let connect: [UInt8] = [0x10, 0x13, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x07] + Array("ios-app".utf8)
        XCTAssertEqual(relay.relay(connect, from: .clientToBroker), connect)

        let publish: [UInt8] = [0x30, 0x07, 0x00, 0x03] + Array("a/b".utf8) + [0x68, 0x69] // "hi" on a/b
        XCTAssertEqual(relay.relay(Array(publish.prefix(4)), from: .clientToBroker), [], "held until complete")
        XCTAssertEqual(relay.relay(Array(publish.dropFirst(4)), from: .clientToBroker), publish, "unchanged without rules")

        rules.update(http: [], mqtt: [MQTTRule(name: "Shout", topicFilter: "a/#", operations: [
            MQTTRewriteOperation(target: .payload, action: .set, value: "HELLO"),
        ])])
        let output = relay.relay(publish + [0xC0, 0x00], from: .clientToBroker)
        let expected = try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "a/b", payload: Array("HELLO".utf8))),
                                                   version: .v3_1_1)
        XCTAssertEqual(output, expected + [0xC0, 0x00])

        let recorded = log.events.compactMap { event -> MQTTCaptureEvent? in if case .mqtt(let e) = event { e } else { nil } }
        XCTAssertEqual(recorded.map(\.event.packet.type), [.connect, .publish, .publish, .pingreq])
        XCTAssertNil(recorded[1].rewrittenBy)
        XCTAssertEqual(recorded[2].rewrittenBy, ["Shout"])
        XCTAssertEqual(recorded[2].event.frame.rawBytes, expected, "the log shows what was forwarded")
    }

    func testRelayPassesGarbageThroughAfterDecodingFails() {
        let log = CaptureLog()
        let relay = MQTTRelay(sink: log, broker: "b", rules: nil)
        XCTAssertEqual(relay.relay([0x00, 0x01, 0x02], from: .clientToBroker), [0x00, 0x01, 0x02])
        XCTAssertEqual(relay.relay([0x09], from: .clientToBroker), [0x09])
        if case .mqttDecodingFailed? = log.events.first {} else { XCTFail("expected a decoding failure") }
    }
}

final class RewriteProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func run(_ rules: [HTTPRule], breakpoints: HTTPBreakpointHandler? = nil, path: String = "/paused")
    async throws -> (response: String, exchange: HTTPExchange?, upstreamPort: Int) {
        let upstream = try await startServer(group: group) { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UpstreamHTTPHandler()) }
            }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        var configuration = HTTPProxyServer.Configuration()
        configuration.breakpoints = breakpoints
        // Placeholders let rules point at the test server's port.
        let live = LiveRules()
        live.update(http: rules.map { rule in
            var rule = rule
            rule.mapRemote.url = rule.mapRemote.url.replacingOccurrences(of: "PORT", with: String(port))
            return rule
        }, mqtt: [])
        configuration.rules = live
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        let proxyPort = try await proxy.start()
        let client = try await RawClient.connect(port: proxyPort, group: group)
        let body = "hello"
        try await client.send("POST http://127.0.0.1:\(port)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
                              "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        await eventually("client closed") { client.isClosed }
        await eventually("exchange recorded") { !log.events.isEmpty }
        try await proxy.stop()
        try await upstream.close()
        if case .httpExchange(let exchange)? = log.events.first { return (client.text, exchange, port) }
        return (client.text, nil, port)
    }

    func testMapLocalNeverContactsTheServer() async throws {
        let rule = HTTPRule(name: "Mock", pattern: "*/paused", kind: .mapLocal,
                            mapLocal: MapLocalResponse(statusCode: 202, body: #"{"mocked":true}"#))
        let (response, exchange, _) = try await run([rule])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 202 Accepted"), response)
        XCTAssertFalse(response.contains("X-Upstream"))
        XCTAssertTrue(response.hasSuffix(#"{"mocked":true}"#), response)
        XCTAssertEqual(exchange?.statusCode, 202)
        XCTAssertEqual(exchange?.rewrittenBy, ["Mock"])
        XCTAssertEqual(exchange?.mappedLocally, true)
        XCTAssertNil(exchange?.timing)
    }

    func testMapRemoteAndRewriteBothPhases() async throws {
        let remote = HTTPRule(name: "To other path", pattern: "127.0.0.1:*/paused", kind: .mapRemote,
                              mapRemote: MapRemoteDestination(url: "http://localhost:PORT/remote"))
        let rewrite = HTTPRule(name: "Edit", pattern: "*/paused", kind: .rewrite, operations: [
            RewriteOperation(phase: .request, target: .body, action: .replace, value: "bye", find: "hello"),
            RewriteOperation(phase: .response, target: .status, action: .set, value: "299"),
            RewriteOperation(phase: .response, target: .header, action: .set, name: "X-Rewritten", value: "yes"),
            RewriteOperation(phase: .response, target: .body, action: .replace, value: "REMOTE", find: "/remote"),
        ])
        let (response, exchange, port) = try await run([remote, rewrite])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 299"), response)
        XCTAssertTrue(response.contains("X-Rewritten: yes"), response)
        XCTAssertTrue(response.hasSuffix("POST REMOTE host=localhost:\(port) body=bye"), response)
        XCTAssertEqual(exchange?.url, "http://localhost:\(port)/remote")
        XCTAssertEqual(exchange?.rewrittenBy, ["To other path", "Edit"])
        XCTAssertNil(exchange?.mappedLocally)
    }

    func testBreakpointSeesTheRewrittenRequest() async throws {
        let rewrite = HTTPRule(name: "Edit", pattern: "*", kind: .rewrite, operations: [
            RewriteOperation(phase: .request, target: .header, action: .set, name: "X-Rule", value: "1"),
        ])
        let handler = ScriptedBreakpoints([.request], request: { request in
            XCTAssertEqual(request.headers.last, CapturedHeader(name: "X-Rule", value: "1"))
            return .proceed(request)
        })
        let (response, exchange, _) = try await run([rewrite], breakpoints: handler)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201"), response)
        XCTAssertEqual(exchange?.breakpoint, [.request])
        XCTAssertEqual(exchange?.rewrittenBy, ["Edit"])
    }

    func testUnmatchedRequestsAreUntouched() async throws {
        let rule = HTTPRule(pattern: "*/elsewhere", kind: .mapLocal)
        let (response, exchange, _) = try await run([rule])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201"), response)
        XCTAssertNil(exchange?.rewrittenBy)
    }
}

final class MQTTForwarderRewriteTests: XCTestCase {
    func testForwarderRewritesPublishesToTheBroker() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let echo = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let log = CaptureLog()
        let rules = LiveRules()
        rules.update(http: [], mqtt: [MQTTRule(topicFilter: "a/b", direction: .clientToBroker, operations: [
            MQTTRewriteOperation(target: .topic, value: "c/d"),
        ])])
        let forwarder = MQTTForwarder(group: group, sink: log, brokerHost: "127.0.0.1", brokerPort: echo.localAddress!.port!, rules: rules)
        let port = try await forwarder.start()
        let client = try await RawClient.connect(port: port, group: group)
        // The echo "broker" sends the forwarded PUBLISH straight back, so the client sees what the broker got.
        try await client.send([0x30, 0x07, 0x00, 0x03] + Array("a/b".utf8) + [0x68, 0x69])
        let expected: [UInt8] = [0x30, 0x07, 0x00, 0x03] + Array("c/d".utf8) + [0x68, 0x69]
        await eventually("rewritten publish echoed") { client.bytes == expected }
        try await client.channel.close()
        try await forwarder.stop()
        try await echo.close()
        try await group.shutdownGracefully()
    }
}
