import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyCore
import XCTest

/// `{"devices":[{"id":"thermo-01","online":true}]}` in each coding.
private enum Fixture {
    static let text = #"{"devices":[{"id":"thermo-01","online":true}]}"#
    static let deflateData: [UInt8] = [
        171, 86, 74, 73, 45, 203, 76, 78, 45, 86, 178, 138, 174, 86, 202, 76, 81, 178, 82, 42, 201, 72, 45, 202,
        205, 215, 53, 48, 84, 210, 81, 202, 207, 203, 201, 204, 75, 85, 178, 42, 41, 42, 77, 173, 141, 173, 5, 0,
    ]
    static let gzip: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255] + deflateData + [102, 127, 185, 49, 46, 0, 0, 0]
    static let zlib: [UInt8] = [120, 156] + deflateData + [104, 127, 15, 165]
    /// "ab" and "cd" as two gzip members back to back.
    static let twoMembers: [UInt8] = [
        31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 76, 2, 0, 109, 72, 131, 158, 2, 0, 0, 0,
        31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 78, 1, 0, 218, 143, 214, 69, 2, 0, 0, 0,
    ]
}

final class ContentDecodingTests: XCTestCase {
    private func headers(_ coding: String) -> [CapturedHeader] {
        [CapturedHeader(name: "Content-Type", value: "application/json"), CapturedHeader(name: "Content-Encoding", value: coding)]
    }

    func testDecodesGzipAndBothDeflateForms() throws {
        for (coding, body) in [("gzip", Fixture.gzip), ("x-gzip", Fixture.gzip), ("deflate", Fixture.zlib), ("deflate", Fixture.deflateData)] {
            let decoded = try XCTUnwrap(ContentDecoding.decode(body: body, headers: headers(coding), limit: 1 << 20), coding)
            XCTAssertEqual(String(decoding: decoded.body, as: UTF8.self), Fixture.text, coding)
            XCTAssertEqual(decoded.headers, [CapturedHeader(name: "Content-Type", value: "application/json")])
        }
        let members = try XCTUnwrap(ContentDecoding.decode(body: Fixture.twoMembers, headers: headers("gzip"), limit: 100))
        XCTAssertEqual(String(decoding: members.body, as: UTF8.self), "abcd")
    }

    func testLeavesUnknownCorruptTruncatedAndOversizedBodiesAlone() {
        XCTAssertNil(ContentDecoding.decode(body: [1, 2, 3], headers: headers("br"), limit: 100))
        XCTAssertNil(ContentDecoding.decode(body: Array("plain".utf8), headers: [], limit: 100))
        XCTAssertNil(ContentDecoding.decode(body: Array("not gzip".utf8), headers: headers("gzip"), limit: 100))
        XCTAssertNil(ContentDecoding.decode(body: Array(Fixture.gzip.prefix(30)), headers: headers("gzip"), limit: 100))
        XCTAssertNil(ContentDecoding.decode(body: Fixture.gzip, headers: headers("gzip"), limit: 10))
    }

    func testNarrowsAcceptEncodingToDecodableCodings() {
        XCTAssertEqual(ContentDecoding.acceptEncoding("gzip, deflate, br"), "gzip, deflate")
        XCTAssertEqual(ContentDecoding.acceptEncoding("br;q=1.0, gzip;q=0.8, zstd"), "gzip;q=0.8")
        XCTAssertNil(ContentDecoding.acceptEncoding("br, zstd"))
    }
}

/// Answers every request with the gzip fixture, echoing the Accept-Encoding it received.
private final class GzipUpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head else { return }
            var response = HTTPResponseHead(version: .http1_1, status: .ok)
            response.headers.add(name: "Content-Type", value: "application/json")
            response.headers.add(name: "Content-Encoding", value: "gzip")
            response.headers.add(name: "X-Accept-Encoding", value: head.headers["Accept-Encoding"].first ?? "none")
            response.headers.add(name: "Content-Length", value: String(Fixture.gzip.count))
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            if head.method != .HEAD {
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: Fixture.gzip)))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

final class ContentDecodingProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func startUpstream() async throws -> Channel {
        try await startServer(group: group) { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(GzipUpstreamHandler()) }
            }
        }
    }

    func testCapturesAndForwardsCompressedResponsesDecoded() async throws {
        let upstream = try await startUpstream()
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("GET http://127.0.0.1:\(port)/devices HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
                              "Accept-Encoding: gzip, deflate, br\r\nConnection: close\r\n\r\n")
        await eventually("client closed") { client.isClosed }

        XCTAssertTrue(client.text.hasSuffix(Fixture.text), client.text)
        XCTAssertTrue(client.text.contains("Content-Length: \(Fixture.text.utf8.count)"), client.text)
        XCTAssertFalse(client.text.lowercased().contains("content-encoding"), client.text)
        XCTAssertTrue(client.text.contains("X-Accept-Encoding: gzip, deflate\r\n"), "br is not offered upstream: \(client.text)")

        guard case .httpExchange(let exchange)? = log.events.first else { return XCTFail("no exchange: \(log.events)") }
        XCTAssertEqual(String(decoding: exchange.responseBody, as: UTF8.self), Fixture.text)
        XCTAssertFalse(exchange.responseHeaders.contains { $0.name.lowercased() == "content-encoding" })
        XCTAssertTrue(exchange.requestHeaders.contains(CapturedHeader(name: "Accept-Encoding", value: "gzip, deflate, br")),
                      "the capture shows what the app sent")

        try await proxy.stop()
        try await upstream.close()
    }

    func testHeadResponsesKeepTheServersContentLength() async throws {
        let upstream = try await startUpstream()
        let port = upstream.localAddress!.port!
        let proxy = HTTPProxyServer(group: group, sink: CaptureLog())
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("HEAD http://127.0.0.1:\(port)/devices HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n")
        await eventually("client closed") { client.isClosed }

        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 200 OK"), client.text)
        XCTAssertTrue(client.text.contains("Content-Length: \(Fixture.gzip.count)\r\n"), client.text)
        XCTAssertTrue(client.text.hasSuffix("\r\n\r\n"), "no body after a HEAD response: \(client.text)")

        try await proxy.stop()
        try await upstream.close()
    }

    func testContentLengthRules() {
        var headers = HTTPHeaders([("Content-Length", "99")])
        ProxyRequestHandler.setContentLength(&headers, bodyCount: 5, status: 200, requestMethod: "GET")
        XCTAssertEqual(headers["Content-Length"], ["5"])

        headers = HTTPHeaders([("Content-Length", "99")])
        ProxyRequestHandler.setContentLength(&headers, bodyCount: 0, status: 304, requestMethod: "GET")
        XCTAssertEqual(headers["Content-Length"], ["99"])

        headers = HTTPHeaders([("Content-Length", "0")])
        ProxyRequestHandler.setContentLength(&headers, bodyCount: 0, status: 204, requestMethod: "DELETE")
        XCTAssertEqual(headers["Content-Length"], [])
    }
}
