import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyCore
import XCTest

final class BreakpointRuleTests: XCTestCase {
    func testPatternsMatchWholeURLWithWildcards() {
        let rule = BreakpointRule(pattern: "api.example.com/v2/*")
        XCTAssertTrue(rule.matches(method: "GET", url: "https://api.example.com/v2/devices?page=1"))
        XCTAssertTrue(rule.matches(method: "POST", url: "http://API.example.com/v2/x"))
        XCTAssertFalse(rule.matches(method: "GET", url: "https://api.example.com/v1/devices"))
        XCTAssertFalse(rule.matches(method: "GET", url: "https://evil.com/?api.example.com/v2/x"))

        XCTAssertTrue(BreakpointRule(pattern: "https://*.example.com/login").matches(method: "GET", url: "https://auth.example.com/login/"))
        XCTAssertFalse(BreakpointRule(pattern: "https://*.example.com/login").matches(method: "GET", url: "http://auth.example.com/login"))
        XCTAssertTrue(BreakpointRule(pattern: "*").matches(method: "GET", url: "http://a/b"))
        XCTAssertTrue(BreakpointRule(pattern: "*a*b*c").matches(method: "GET", url: "http://xaybzc"))
        XCTAssertFalse(BreakpointRule(pattern: "").matches(method: "GET", url: "http://a"))
    }

    func testMethodEnabledAndStages() {
        var rule = BreakpointRule(pattern: "*", method: "POST", stages: [.response])
        XCTAssertFalse(rule.matches(method: "GET", url: "http://a"))
        XCTAssertTrue(rule.matches(method: "post", url: "http://a"))
        let rules = [rule, BreakpointRule(pattern: "a/*", stages: [.request])]
        XCTAssertEqual(rules.stages(method: "POST", url: "http://a/b"), [.request, .response])
        XCTAssertEqual(rules.stages(method: "GET", url: "http://a/b"), [.request])
        rule.isEnabled = false
        XCTAssertFalse(rule.matches(method: "POST", url: "http://a"))
    }

    func testRulesRoundTripThroughJSON() throws {
        let rules = [BreakpointRule(pattern: "a/*", method: "GET", stages: [.response])]
        XCTAssertEqual(try JSONDecoder().decode([BreakpointRule].self, from: JSONEncoder().encode(rules)), rules)
    }
}

/// Edits whatever pauses with the closures it was given.
final class ScriptedBreakpoints: HTTPBreakpointHandler, @unchecked Sendable {
    let stagesToPause: BreakpointStages
    let onRequest: @Sendable (HTTPRequestDraft) -> BreakpointResolution<HTTPRequestDraft>
    let onResponse: @Sendable (HTTPResponseDraft) -> BreakpointResolution<HTTPResponseDraft>

    init(_ stages: BreakpointStages,
         request: @escaping @Sendable (HTTPRequestDraft) -> BreakpointResolution<HTTPRequestDraft> = { .proceed($0) },
         response: @escaping @Sendable (HTTPResponseDraft) -> BreakpointResolution<HTTPResponseDraft> = { .proceed($0) }) {
        stagesToPause = stages
        onRequest = request
        onResponse = response
    }

    func stages(method: String, url: String) -> BreakpointStages { url.contains("/paused") ? stagesToPause : [] }

    func editRequest(_ request: HTTPRequestDraft) async -> BreakpointResolution<HTTPRequestDraft> {
        try? await Task.sleep(nanoseconds: 50_000_000) // like a person taking a moment
        return onRequest(request)
    }

    func editResponse(_ response: HTTPResponseDraft, for request: HTTPRequestDraft) async -> BreakpointResolution<HTTPResponseDraft> {
        onResponse(response)
    }
}

final class BreakpointProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func run(_ breakpoints: HTTPBreakpointHandler, path: String = "/paused", body: String = "hello")
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
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        let proxyPort = try await proxy.start()
        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("POST http://127.0.0.1:\(port)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
                              "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        await eventually("client closed") { client.isClosed }
        await eventually("exchange recorded") { !log.events.isEmpty }
        try await proxy.stop()
        try await upstream.close()
        if case .httpExchange(let exchange)? = log.events.first { return (client.text, exchange, port) }
        return (client.text, nil, port)
    }

    func testEditsRequestBeforeItLeaves() async throws {
        let handler = ScriptedBreakpoints([.request], request: { request in
            var edited = request
            edited.method = "PUT"
            edited.url = request.url.replacingOccurrences(of: "/paused", with: "/paused/edited?x=2")
            edited.body = Array("changed body".utf8)
            return .proceed(edited)
        })
        let (response, exchange, port) = try await run(handler)
        XCTAssertTrue(response.hasSuffix("PUT /paused/edited?x=2 host=127.0.0.1:\(port) body=changed body"), response)
        XCTAssertEqual(exchange?.method, "PUT")
        XCTAssertEqual(exchange?.url, "http://127.0.0.1:\(port)/paused/edited?x=2")
        XCTAssertEqual(exchange?.requestBody, Array("changed body".utf8))
        XCTAssertEqual(exchange?.breakpoint, [.request])
    }

    func testEditsResponseBeforeTheClientSeesIt() async throws {
        let handler = ScriptedBreakpoints([.response], response: { response in
            var edited = response
            edited.statusCode = 503
            edited.headers.append(CapturedHeader(name: "X-Edited", value: "yes"))
            edited.body = Array("maintenance".utf8)
            return .proceed(edited)
        })
        let (response, exchange, _) = try await run(handler)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503 Service Unavailable"), response)
        XCTAssertTrue(response.contains("X-Edited: yes"))
        XCTAssertTrue(response.contains("Content-Length: 11"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\nmaintenance"), response)
        XCTAssertEqual(exchange?.statusCode, 503)
        XCTAssertEqual(exchange?.responseBody, Array("maintenance".utf8))
        XCTAssertEqual(exchange?.breakpoint, [.response])
    }

    func testAbortNeverReachesTheServer() async throws {
        let (response, exchange, _) = try await run(ScriptedBreakpoints([.request], request: { _ in .abort }))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 502"), response)
        XCTAssertTrue(response.contains("Aborted at a breakpoint"))
        XCTAssertFalse(response.contains("X-Upstream"))
        XCTAssertEqual(exchange?.error, "Aborted at a breakpoint")
        XCTAssertNil(exchange?.statusCode)
    }

    func testUnmatchedRequestsPassStraightThrough() async throws {
        let (response, exchange, _) = try await run(ScriptedBreakpoints([.request], request: { _ in .abort }), path: "/other")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201"), response)
        XCTAssertNil(exchange?.breakpoint)
    }

    func testInvalidEditedURLIsRejected() async throws {
        let handler = ScriptedBreakpoints([.request], request: { request in
            var edited = request
            edited.url = "ftp://nowhere"
            return .proceed(edited)
        })
        let (response, exchange, _) = try await run(handler)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), response)
        XCTAssertEqual(exchange?.statusCode, 400)
    }

    func testParsesHTTPAndHTTPSTargets() {
        let plain = AbsoluteHTTPTarget.parse(url: "http://a.com:8080/x?y")
        XCTAssertEqual(plain?.0, AbsoluteHTTPTarget(host: "a.com", port: 8080, originForm: "/x?y"))
        XCTAssertEqual(plain?.useTLS, false)
        let secure = AbsoluteHTTPTarget.parse(url: "HTTPS://b.com")
        XCTAssertEqual(secure?.0.port, 443)
        XCTAssertEqual(secure?.0.originForm, "/")
        XCTAssertEqual(secure?.useTLS, true)
        XCTAssertNil(AbsoluteHTTPTarget.parse(url: "b.com/x"))
    }
}
