import MQTTCore
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyCore
import XCTest

final class ProxyCoreTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    // MARK: HTTP

    func testForwardsPlainHTTPAndCapturesExchange() async throws {
        let upstream = try await startServer(group: group) { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UpstreamHTTPHandler()) }
            }
        }
        let upstreamPort = upstream.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send(
            "POST http://127.0.0.1:\(upstreamPort)/items?x=1 HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamPort)\r\nProxy-Connection: keep-alive\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
        )
        await eventually("client closed") { client.isClosed }

        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 201 Created"), client.text)
        XCTAssertTrue(client.text.contains("X-Upstream: 1"))
        XCTAssertTrue(client.text.hasSuffix("POST /items?x=1 host=127.0.0.1:\(upstreamPort) body=hello"), client.text)

        guard case .httpExchange(let exchange)? = log.events.first else { return XCTFail("no exchange: \(log.events)") }
        XCTAssertEqual(exchange.method, "POST")
        XCTAssertEqual(exchange.url, "http://127.0.0.1:\(upstreamPort)/items?x=1")
        XCTAssertEqual(exchange.statusCode, 201)
        XCTAssertEqual(exchange.requestBody, Array("hello".utf8))
        XCTAssertTrue(exchange.responseHeaders.contains(CapturedHeader(name: "X-Upstream", value: "1")))
        XCTAssertNil(exchange.error)

        try await proxy.stop()
        try await upstream.close()
    }

    func testKeepAliveServesSequentialRequests() async throws {
        let upstream = try await startServer(group: group) { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UpstreamHTTPHandler()) }
            }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("GET http://127.0.0.1:\(port)/one HTTP/1.1\r\nHost: x\r\n\r\n")
        await eventually("first response") { client.text.contains("GET /one") }
        try await client.send("GET http://127.0.0.1:\(port)/two HTTP/1.1\r\nHost: x\r\n\r\n")
        await eventually("second response") { client.text.contains("GET /two") }
        XCTAssertFalse(client.isClosed)
        XCTAssertEqual(log.events.count, 2)

        try await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }

    func testUnreachableUpstreamReturns502() async throws {
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("GET http://127.0.0.1:1/ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        await eventually("client closed") { client.isClosed }

        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 502 Bad Gateway"), client.text)
        guard case .httpExchange(let exchange)? = log.events.first else { return XCTFail("no exchange") }
        XCTAssertEqual(exchange.statusCode, 502)
        XCTAssertNotNil(exchange.error)
        try await proxy.stop()
    }

    func testRejectsOriginFormRequests() async throws {
        let proxy = HTTPProxyServer(group: group, sink: CaptureLog())
        let proxyPort = try await proxy.start()
        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("GET /index.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        await eventually("client closed") { client.isClosed }
        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 400 Bad Request"), client.text)
        try await proxy.stop()
    }

    // MARK: CONNECT

    func testConnectTunnelRelaysBytesAndReportsCounts() async throws {
        let echo = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let echoPort = echo.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("CONNECT 127.0.0.1:\(echoPort) HTTP/1.1\r\nHost: 127.0.0.1:\(echoPort)\r\n\r\n")
        await eventually("tunnel established") { client.text.contains("\r\n\r\n") }
        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 200 OK"), client.text)

        let established = client.bytes.count
        try await client.send([0x16, 0x03, 0x01, 0x00, 0xFF]) // looks like a TLS record, must pass untouched
        await eventually("echo") { client.bytes.count == established + 5 }
        XCTAssertEqual(Array(client.bytes.suffix(5)), [0x16, 0x03, 0x01, 0x00, 0xFF])

        try await client.channel.close()
        await eventually("tunnel closed") {
            log.events.contains { if case .tunnelClosed = $0 { true } else { false } }
        }
        guard case .tunnelOpened(let info)? = log.events.first else { return XCTFail("no tunnelOpened") }
        XCTAssertEqual(info.port, echoPort)
        XCTAssertTrue(log.events.contains(.tunnelClosed(id: info.id, bytesFromClient: 5, bytesFromServer: 5)), "\(log.events)")

        try await proxy.stop()
        try await echo.close()
    }

    // MARK: MQTT

    func testMQTTForwarderDecodesBothDirections() async throws {
        let broker = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(FakeBrokerHandler()) }
        }
        let log = CaptureLog()
        let forwarder = MQTTForwarder(group: group, sink: log, brokerHost: "127.0.0.1", brokerPort: broker.localAddress!.port!)
        let port = try await forwarder.start()

        let client = try await RawClient.connect(port: port, group: group)
        // CONNECT v3.1.1, client id "ios-app", keep alive 60
        let connect: [UInt8] = [0x10, 0x13, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x07] + Array("ios-app".utf8)
        try await client.send(connect)
        await eventually("CONNACK relayed") { client.bytes == [0x20, 0x02, 0x00, 0x00] }

        try await client.send([0x30, 0x07, 0x00, 0x03] + Array("a/b".utf8) + [0x68, 0x69]) // PUBLISH "hi"
        await eventually("publish decoded") { log.events.count == 3 }
        try await client.send([0xC0, 0x00])
        await eventually("PINGRESP relayed") { client.bytes.count == 6 }
        await eventually("five MQTT events") { log.events.count == 5 }

        let packets = log.events.compactMap { event -> (MQTTDirection, MQTTPacketType)? in
            guard case .mqtt(let e) = event else { return nil }
            return (e.event.direction, e.event.packet.type)
        }
        XCTAssertEqual(packets.map(\.1), [.connect, .connack, .publish, .pingreq, .pingresp])
        XCTAssertEqual(packets.filter { $0.0 == .brokerToClient }.map(\.1), [.connack, .pingresp])

        if case .mqtt(let e)? = log.events.first(where: {
            if case .mqtt(let e) = $0, e.event.packet.type == .publish { true } else { false }
        }) {
            XCTAssertEqual(e.event.resolvedTopic, "a/b")
        } else {
            XCTFail("no publish")
        }

        try await client.channel.close()
        try await forwarder.stop()
        try await broker.close()
    }
}

final class TargetParsingTests: XCTestCase {
    func testAbsoluteTargets() {
        XCTAssertEqual(AbsoluteHTTPTarget("http://example.com")?.originForm, "/")
        XCTAssertEqual(AbsoluteHTTPTarget("http://example.com?q=1")?.originForm, "/?q=1")
        let t = AbsoluteHTTPTarget("HTTP://example.com:8080/a/b?c=d#frag")
        XCTAssertEqual(t?.host, "example.com")
        XCTAssertEqual(t?.port, 8080)
        XCTAssertEqual(t?.originForm, "/a/b?c=d")
        XCTAssertEqual(AbsoluteHTTPTarget("http://[::1]:9000/x")?.host, "::1")
        XCTAssertNil(AbsoluteHTTPTarget("https://example.com/"))
        XCTAssertNil(AbsoluteHTTPTarget("/relative"))
    }

    func testAuthority() {
        XCTAssertTrue(parseAuthority("example.com:443")! == ("example.com", 443))
        XCTAssertNil(parseAuthority("example.com"))
        XCTAssertNil(parseAuthority("example.com:0"))
        XCTAssertTrue(parseAuthority("[::1]:8443")! == ("::1", 8443))
    }

    func testHopByHopRemoval() {
        let headers = HTTPHeaders([("Connection", "close, X-Custom"), ("X-Custom", "1"), ("Keep-Alive", "5"), ("Accept", "*/*")])
        XCTAssertEqual(headers.removingHopByHop().map(\.name), ["Accept"])
    }
}
