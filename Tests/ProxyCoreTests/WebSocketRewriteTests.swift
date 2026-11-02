import Foundation
import MQTTCore
import NIOCore
import NIOPosix
@testable import ProxyCore
import XCTest

/// MQTT rewrite rules on sockets that negotiated an `mqtt` subprotocol.
final class WebSocketTapRewriteTests: XCTestCase {
    private let handshake = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n".utf8)
    private let connect: [UInt8] = [0x10, 0x10, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x04] + Array("wsid".utf8)
    private let connack: [UInt8] = [0x20, 0x02, 0x00, 0x00]

    private func publish(_ topic: String, _ payload: String) throws -> [UInt8] {
        try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: topic, payload: Array(payload.utf8))), version: .v3_1_1)
    }

    private func makeTap(rules: [MQTTRule] = [], subprotocol: Bool = true) -> (WebSocketTap, CaptureLog, LiveRules) {
        let log = CaptureLog()
        let live = LiveRules()
        live.update(http: [], mqtt: rules)
        let request = HTTPExchange(startedAt: Date(), duration: 0, method: "GET", url: "ws://broker.test/mqtt",
                                   requestHeaders: [], requestBody: [], statusCode: nil, responseHeaders: [], responseBody: [])
        return (WebSocketTap(sink: log, request: request, rules: live), log, live)
    }

    /// Upgrades, then exchanges CONNECT and CONNACK so the MQTT session knows its version.
    private func upgraded(rules: [MQTTRule] = []) throws -> (WebSocketTap, CaptureLog, LiveRules) {
        let (tap, log, live) = makeTap(rules: rules)
        XCTAssertEqual(tap.receiveFromServer(handshake), handshake)
        let connectFrame = wsFrame(0x2, connect, mask: [1, 2, 3, 4])
        XCTAssertEqual(tap.receiveFromClient(connectFrame), connectFrame)
        XCTAssertEqual(tap.receiveFromServer(wsFrame(0x2, connack)), wsFrame(0x2, connack))
        return (tap, log, live)
    }

    private func messages(_ bytes: [UInt8]) throws -> [WebSocketFrameParser.Message] {
        var parser = WebSocketFrameParser()
        return try parser.feed(bytes)
    }

    private func mqttEvents(_ log: CaptureLog) -> [MQTTCaptureEvent] {
        log.events.compactMap { if case .mqtt(let e) = $0 { e } else { nil } }
    }

    func testRewritesClientPublishIntoANewMaskedFrame() throws {
        let rule = MQTTRule(name: "Shout", topicFilter: "a/#", operations: [MQTTRewriteOperation(target: .payload, action: .set, value: "HELLO")])
        let (tap, log, _) = try upgraded(rules: [rule])

        let output = tap.receiveFromClient(wsFrame(0x2, try publish("a/b", "hi"), mask: [9, 9, 9, 9]))
        XCTAssertEqual(output[1] & 0x80, 0x80, "frames toward the server stay masked")
        XCTAssertEqual(try messages(output), [.init(opcode: .binary, payload: try publish("a/b", "HELLO"))])

        let recorded = mqttEvents(log)
        XCTAssertEqual(recorded.map(\.event.packet.type), [.connect, .connack, .publish])
        XCTAssertEqual(recorded.last?.rewrittenBy, ["Shout"])
        XCTAssertEqual(recorded.last?.broker, "ws://broker.test/mqtt")
    }

    func testRewritesBrokerPublishUnmaskedAndKeepsTheOtherDirection() throws {
        let rule = MQTTRule(topicFilter: "#", direction: .brokerToClient, operations: [MQTTRewriteOperation(target: .payload, action: .set, value: "mocked")])
        let (tap, _, _) = try upgraded(rules: [rule])

        let fromClient = wsFrame(0x2, try publish("t", "real"), mask: [5, 6, 7, 8])
        XCTAssertEqual(tap.receiveFromClient(fromClient), fromClient, "the rule only covers broker to client")

        let output = tap.receiveFromServer(wsFrame(0x2, try publish("t", "real")))
        XCTAssertEqual(output, wsFrame(0x2, try publish("t", "mocked")))
    }

    func testUntouchedTrafficKeepsItsExactBytes() throws {
        let (tap, log, live) = try upgraded()
        let ping = wsFrame(0x9, [1], mask: [3, 3, 3, 3])
        let text = wsFrame(0x1, Array("hello".utf8), mask: [7, 1, 7, 1])
        let packet = try publish("a/b", "hi")
        let binary = wsFrame(0x2, packet, mask: [4, 4, 4, 4])
        XCTAssertEqual(tap.receiveFromClient(ping + text + binary), ping + text + binary)

        // A fragmented binary message is held until its last frame, then forwarded as it came.
        let first = wsFrame(0x2, Array(packet[..<3]), fin: false, mask: [1, 1, 1, 1])
        let last = wsFrame(0x0, Array(packet[3...]), mask: [2, 2, 2, 2])
        XCTAssertEqual(tap.receiveFromClient(first + ping), ping, "control frames may interleave and go at once")
        XCTAssertEqual(tap.receiveFromClient(last), first + last)

        // Partial frames wait for the rest.
        XCTAssertEqual(tap.receiveFromClient(Array(binary[..<4])), [])
        XCTAssertEqual(tap.receiveFromClient(Array(binary[4...])), binary)

        // A rule that matches nothing changes nothing.
        live.update(http: [], mqtt: [MQTTRule(topicFilter: "other/#", operations: [MQTTRewriteOperation(target: .payload, value: "x")])])
        XCTAssertEqual(tap.receiveFromClient(binary), binary)
        XCTAssertEqual(mqttEvents(log).filter { $0.event.packet.type == .publish }.count, 4)
    }

    func testPacketSplitAcrossMessagesIsSentWhole() throws {
        let rule = MQTTRule(topicFilter: "a/#", operations: [MQTTRewriteOperation(target: .payload, action: .set, value: "HELLO")])
        let (tap, log, _) = try upgraded(rules: [rule])
        let packet = try publish("a/b", "hi")
        XCTAssertEqual(tap.receiveFromClient(wsFrame(0x2, Array(packet[..<4]), mask: [1, 2, 3, 4])), [], "held inside the relay")
        let output = tap.receiveFromClient(wsFrame(0x2, Array(packet[4...]), mask: [4, 3, 2, 1]))
        XCTAssertEqual(try messages(output), [.init(opcode: .binary, payload: try publish("a/b", "HELLO"))])
        XCTAssertEqual(mqttEvents(log).last?.rewrittenBy?.isEmpty, false)
    }

    func testClientFramesSentBeforeTheUpgradeAreCapturedButNotRewritten() throws {
        let rule = MQTTRule(topicFilter: "#", operations: [MQTTRewriteOperation(target: .payload, action: .set, value: "x")])
        let (tap, log, _) = makeTap(rules: [rule])
        let early = wsFrame(0x2, connect, mask: [1, 2, 3, 4]) + wsFrame(0x2, try publish("a", "b"), mask: [1, 2, 3, 4])
        XCTAssertEqual(tap.receiveFromClient(early), early, "forwarded at once, before the socket is known to be MQTT")

        // The 101 and the CONNACK arrive in one read; the head goes out untouched.
        XCTAssertEqual(tap.receiveFromServer(Array(handshake[..<10])), Array(handshake[..<10]))
        let rest = Array(handshake[10...]) + wsFrame(0x2, connack)
        XCTAssertEqual(tap.receiveFromServer(rest), rest)

        let later = wsFrame(0x2, try publish("a", "c"), mask: [6, 6, 6, 6])
        XCTAssertEqual(tap.receiveFromClient(later), later, "this direction stays byte for byte")
        XCTAssertEqual(mqttEvents(log).map(\.event.packet.type), [.connack, .connect, .publish, .publish])
        XCTAssertEqual(tap.receiveFromServer(wsFrame(0x2, try publish("a", "d"))), wsFrame(0x2, try publish("a", "x")),
                       "the server side is still rewritten")
    }

    func testBadFramesFallBackToPassthroughWithoutLosingBytes() throws {
        let (tap, log, _) = try upgraded()
        let waiting = Array(wsFrame(0x2, try publish("a", "b"))[..<3])
        XCTAssertEqual(tap.receiveFromServer(waiting), [], "an incomplete frame is held")

        let good = wsFrame(0x2, try publish("a", "b"), mask: [1, 1, 1, 1])
        let bad: [UInt8] = [0xC2, 0x80, 0, 0, 0, 0] // RSV1 set: compressed
        XCTAssertEqual(tap.receiveFromClient(good + bad + [1, 2]), good + bad + [1, 2])
        XCTAssertEqual(tap.receiveFromClient([3]), [3])
        XCTAssertEqual(tap.receiveFromServer([9]), waiting + [9], "the other side releases what it held")
        XCTAssertTrue(log.events.contains { if case .webSocketDecodingFailed = $0 { true } else { false } })
    }

    func testOtherSocketsAreForwardedChunkForChunk() throws {
        let (tap, log, _) = makeTap()
        let head = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8)
        XCTAssertEqual(tap.receiveFromServer(head), head)
        let frame = wsFrame(0x1, Array("hello".utf8), mask: [1, 2, 3, 4])
        XCTAssertEqual(tap.receiveFromClient(Array(frame[..<3])), Array(frame[..<3]))
        XCTAssertEqual(tap.receiveFromClient(Array(frame[3...])), Array(frame[3...]))
        let messages = log.events.compactMap { if case .webSocketMessage(let m) = $0 { m } else { nil } }
        XCTAssertEqual(messages.map { String(decoding: $0.payload, as: UTF8.self) }, ["hello"])
    }

    func testEncodesFramesTheParserReads() throws {
        for size in [0, 125, 126, 70_000] {
            let payload = (0..<size).map { UInt8($0 & 0xFF) }
            for masked in [false, true] {
                let frame = WebSocketFrameParser.encode(opcode: .binary, payload: payload, masked: masked)
                XCTAssertEqual(frame[1] & 0x80 != 0, masked)
                XCTAssertEqual(try messages(frame), [.init(opcode: .binary, payload: payload)], "size \(size)")
            }
        }
        var parser = WebSocketFrameParser()
        let (frames, error) = parser.frames(wsFrame(0x2, [1]) + [0xC2, 0x00, 7])
        XCTAssertEqual(frames.map(\.payload), [[1]])
        XCTAssertEqual(error as? WebSocketParsingError, .reservedBitsSet)
        XCTAssertEqual(parser.takeBuffered(), [0xC2, 0x00, 7])
    }
}

final class WebSocketRewriteProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() { group = MultiThreadedEventLoopGroup(numberOfThreads: 2) }
    override func tearDown() { try? group.syncShutdownGracefully() }

    func testProxyRewritesMQTTInsideWebSocketFrames() async throws {
        let server = FakeWebSocketServerHandler(subprotocol: "mqtt")
        let upstream = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(server) }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let live = LiveRules()
        live.update(http: [], mqtt: [MQTTRule(name: "Mock reading", topicFilter: "sensors/#", operations: [
            MQTTRewriteOperation(target: .payload, action: .set, value: "42"),
        ])])
        var configuration = HTTPProxyServer.Configuration()
        configuration.rules = live
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        let proxyPort = try await proxy.start()

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("GET http://127.0.0.1:\(port)/mqtt HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n")
        await eventually("101 relayed") { client.text.contains("\r\n\r\n") }

        let connect: [UInt8] = [0x10, 0x10, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x04] + Array("wsid".utf8)
        let original = try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "sensors/t", payload: Array("21".utf8))), version: .v3_1_1)
        try await client.send(wsFrame(0x2, connect, mask: [1, 2, 3, 4]) + wsFrame(0x2, original, mask: [5, 6, 7, 8]))

        let expected = try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "sensors/t", payload: Array("42".utf8))), version: .v3_1_1)
        await eventually("rewritten publish reached the server") { server.binaryPayloads.contains(expected) }
        XCTAssertEqual(server.binaryPayloads, [connect, expected])
        await eventually("events") { self.publishes(log).count == 1 }
        XCTAssertEqual(publishes(log).first?.rewrittenBy, ["Mock reading"])

        try? await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }

    private func publishes(_ log: CaptureLog) -> [MQTTCaptureEvent] {
        log.events.compactMap { if case .mqtt(let e) = $0, e.event.packet.type == .publish { e } else { nil } }
    }
}
