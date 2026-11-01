import Foundation
import MQTTCore
import NIOCore
import NIOPosix
import NIOSSL
@testable import ProxyCore
import TLSMitm
import XCTest

/// Builds one WebSocket frame. Client frames must be masked.
func wsFrame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, mask: [UInt8]? = nil) -> [UInt8] {
    var frame: [UInt8] = [(fin ? 0x80 : 0) | opcode]
    let maskBit: UInt8 = mask == nil ? 0 : 0x80
    if payload.count < 126 {
        frame.append(maskBit | UInt8(payload.count))
    } else if payload.count <= 0xFFFF {
        frame += [maskBit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    } else {
        frame.append(maskBit | 127)
        frame += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
    }
    guard let mask else { return frame + payload }
    return frame + mask + payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
}

final class WebSocketFrameParserTests: XCTestCase {
    func testUnmasksClientFrame() throws {
        var parser = WebSocketFrameParser()
        let messages = try parser.feed(wsFrame(0x1, Array("Hello".utf8), mask: [0x37, 0xFA, 0x21, 0x3D]))
        XCTAssertEqual(messages, [.init(opcode: .text, payload: Array("Hello".utf8))])
    }

    func testExtendedLengthsAcrossChunks() throws {
        var parser = WebSocketFrameParser()
        let medium = Array(repeating: UInt8(7), count: 300)
        let large = Array(repeating: UInt8(9), count: 70_000)
        let stream = wsFrame(0x2, medium) + wsFrame(0x2, large, mask: [1, 2, 3, 4])
        var messages: [WebSocketFrameParser.Message] = []
        var index = 0
        while index < stream.count {
            let end = min(index + 1000, stream.count)
            messages += try parser.feed(stream[index..<end])
            index = end
        }
        XCTAssertEqual(messages.map(\.payload.count), [300, 70_000])
        XCTAssertEqual(messages[1].payload.first, 9)
    }

    func testJoinsFragmentsAroundControlFrame() throws {
        var parser = WebSocketFrameParser()
        let stream = wsFrame(0x2, [1, 2], fin: false) + wsFrame(0x9, [0xAA]) + wsFrame(0x0, [3], fin: false) + wsFrame(0x0, [4])
        XCTAssertEqual(try parser.feed(stream), [
            .init(opcode: .ping, payload: [0xAA]),
            .init(opcode: .binary, payload: [1, 2, 3, 4]),
        ])
    }

    func testRejectsCompressedFrames() {
        var parser = WebSocketFrameParser()
        XCTAssertThrowsError(try parser.feed([0xC1, 0x00])) {
            XCTAssertEqual($0 as? WebSocketParsingError, .reservedBitsSet)
        }
    }

    func testRejectsStrayContinuation() {
        var parser = WebSocketFrameParser()
        XCTAssertThrowsError(try parser.feed(wsFrame(0x0, [1])))
    }
}

/// Accepts one WebSocket upgrade, remembers the request head, then answers frames:
/// MQTT CONNECT gets a CONNACK, text messages are echoed.
final class FakeWebSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let subprotocol: String?
    private let lock = NSLock()
    private var _requestHead = ""
    private var pending: [UInt8] = []
    private var upgraded = false
    private var parser = WebSocketFrameParser()

    init(subprotocol: String?) { self.subprotocol = subprotocol }

    var requestHead: String { lock.lock(); defer { lock.unlock() }; return _requestHead }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        pending += unwrapInboundIn(data).readableBytesView
        if !upgraded {
            guard let end = headerEnd(pending) else { return }
            lock.lock(); _requestHead = String(decoding: pending[..<end], as: UTF8.self); lock.unlock()
            pending.removeFirst(end + 4)
            upgraded = true
            var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            if let subprotocol { response += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response + "\r\n")), promise: nil)
        }
        guard let messages = try? parser.feed(pending) else { return context.close(promise: nil) }
        pending = []
        for message in messages {
            switch message.opcode {
            case .binary where message.payload.first.map({ $0 >> 4 == 1 }) == true:
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: wsFrame(0x2, [0x20, 0x02, 0x00, 0x00]))), promise: nil)
            case .text:
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: wsFrame(0x1, message.payload))), promise: nil)
            default:
                break
            }
        }
    }
}

final class WebSocketProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() { group = MultiThreadedEventLoopGroup(numberOfThreads: 2) }
    override func tearDown() { try? group.syncShutdownGracefully() }

    private let mqttConnect: [UInt8] = [0x10, 0x10, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x04] + Array("wsid".utf8)

    private func upgradeRequest(port: Int, subprotocol: String?) -> String {
        var request = "GET http://127.0.0.1:\(port)/mqtt HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\nProxy-Connection: keep-alive\r\n"
        if let subprotocol { request += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
        return request + "\r\n"
    }

    func testCapturesMQTTOverWebSocket() async throws {
        let server = FakeWebSocketServerHandler(subprotocol: "mqtt")
        let upstream = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(server) }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send(upgradeRequest(port: port, subprotocol: "mqtt"))
        await eventually("101 relayed") { client.text.contains("\r\n\r\n") }
        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 101"), client.text)

        // Split the CONNECT across two frames to prove MQTT reassembly spans WebSocket messages.
        // One write, so the fake broker cannot answer the first half before the proxy sees the second.
        let prefix = client.bytes.count
        try await client.send(wsFrame(0x2, Array(mqttConnect[..<5]), mask: [9, 8, 7, 6]) + wsFrame(0x2, Array(mqttConnect[5...]), mask: [1, 3, 5, 7]))
        await eventually("CONNACK frame relayed") { client.bytes.count == prefix + 6 }

        await eventually("events") { log.events.count == 3 }
        guard case .httpExchange(let handshake) = log.events[0] else { return XCTFail("\(log.events)") }
        XCTAssertEqual(handshake.statusCode, 101)
        XCTAssertEqual(handshake.url, "http://127.0.0.1:\(port)/mqtt")

        let mqtt = log.events.compactMap { if case .mqtt(let e) = $0 { e } else { nil } }
        XCTAssertEqual(mqtt.map(\.event.packet.type), [.connect, .connack])
        XCTAssertEqual(mqtt.first?.broker, "http://127.0.0.1:\(port)/mqtt")

        XCTAssertTrue(server.requestHead.hasPrefix("GET /mqtt HTTP/1.1"), server.requestHead)
        XCTAssertFalse(server.requestHead.lowercased().contains("sec-websocket-extensions"), server.requestHead)
        XCTAssertFalse(server.requestHead.lowercased().contains("proxy-connection"), server.requestHead)
        XCTAssertTrue(server.requestHead.contains("Sec-WebSocket-Protocol: mqtt"))

        try? await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }

    func testCapturesPlainWebSocketMessages() async throws {
        let server = FakeWebSocketServerHandler(subprotocol: nil)
        let upstream = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(server) }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let proxy = HTTPProxyServer(group: group, sink: log)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send(upgradeRequest(port: port, subprotocol: nil))
        await eventually("101 relayed") { client.text.contains("\r\n\r\n") }
        try await client.send(wsFrame(0x1, Array("ping me".utf8), mask: [4, 3, 2, 1]))
        await eventually("events") { log.events.count == 3 }

        let messages = log.events.compactMap { if case .webSocketMessage(let m) = $0 { m } else { nil } }
        XCTAssertEqual(messages.map(\.direction), [.clientToServer, .serverToClient])
        XCTAssertEqual(messages.map(\.opcode), [.text, .text])
        XCTAssertEqual(messages.map { String(decoding: $0.payload, as: UTF8.self) }, ["ping me", "ping me"])

        try? await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }
}

final class MQTTOverTLSForwarderTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() { group = MultiThreadedEventLoopGroup(numberOfThreads: 2) }
    override func tearDown() { try? group.syncShutdownGracefully() }

    func testTerminatesAndReencryptsTLS() async throws {
        let brokerCA = try CertificateAuthority.generate(commonName: "Broker CA")
        let proxyCA = try CertificateAuthority.generate(commonName: "Proxy CA")
        let brokerTLS = try NIOSSLContext(configuration: brokerCA.issueLeaf(for: "localhost").serverTLSConfiguration())
        let broker = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: brokerTLS))
                try channel.pipeline.syncOperations.addHandler(FakeBrokerHandler())
            }
        }

        var upstream = TLSConfiguration.makeClientConfiguration()
        upstream.trustRoots = .certificates([try NIOSSLCertificate(bytes: brokerCA.certificateDER, format: .der)])
        let log = CaptureLog()
        let forwarder = MQTTForwarder(
            group: group,
            sink: log,
            brokerHost: "localhost",
            brokerPort: broker.localAddress!.port!,
            tls: .init(interceptor: TLSInterceptor(authority: proxyCA), upstream: upstream)
        )
        let port = try await forwarder.start()

        var clientConfiguration = TLSConfiguration.makeClientConfiguration()
        clientConfiguration.trustRoots = .certificates([try NIOSSLCertificate(bytes: proxyCA.certificateDER, format: .der)])
        let clientTLS = try NIOSSLContext(configuration: clientConfiguration)
        let client = try await RawClient.connect(port: port, group: group)
        let channel = client.channel
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: clientTLS, serverHostname: "localhost"), position: .first)
        }.get()

        let connect: [UInt8] = [0x10, 0x0F, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x03] + Array("tls".utf8)
        try await client.send(connect)
        await eventually("CONNACK decrypted") { client.bytes == [0x20, 0x02, 0x00, 0x00] }
        await eventually("events") { log.events.count == 2 }

        let mqtt = log.events.compactMap { if case .mqtt(let e) = $0 { e } else { nil } }
        XCTAssertEqual(mqtt.map(\.event.packet.type), [.connect, .connack])
        guard case .connect(let packet) = mqtt.first?.event.packet else { return XCTFail() }
        XCTAssertEqual(packet.clientIdentifier, "tls")

        try? await client.channel.close()
        try await forwarder.stop()
        try await broker.close()
    }

    func testDefaultsToPort8883WithTLS() throws {
        let interceptor = TLSInterceptor(authority: try .generate())
        let forwarder = MQTTForwarder(group: group, sink: CaptureLog(), brokerHost: "broker.test", tls: .init(interceptor: interceptor))
        XCTAssertEqual(Mirror(reflecting: forwarder).children.first { $0.label == "brokerPort" }?.value as? Int, 8883)
    }
}
