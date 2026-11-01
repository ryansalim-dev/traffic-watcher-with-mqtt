import MQTTCore
import NIOCore
import NIOPosix
@testable import ProxyCore
import XCTest

final class MQTTPublisherTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func startBroker(_ broker: RecordingBroker) async throws -> Channel {
        try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(RecordingBrokerHandler(broker: broker))
            }
        }
    }

    func testPublishesAtEveryQoSAndCapturesBothDirections() async throws {
        let broker = RecordingBroker()
        let server = try await startBroker(broker)
        let log = CaptureLog()
        let publisher = MQTTPublisher(group: group, sink: log)
        let target = MQTTBrokerTarget(host: "127.0.0.1", port: server.localAddress!.port!, clientIdentifier: "tester", username: "me", password: "secret")

        let messages = [
            MQTTOutgoingMessage(topic: "a/0", payload: Array("zero".utf8)),
            MQTTOutgoingMessage(topic: "a/1", payload: Array("one".utf8), qos: .atLeastOnce, retain: true),
            MQTTOutgoingMessage(topic: "a/2", payload: Array("two".utf8), qos: .exactlyOnce),
        ]
        let outcomes = try await publisher.publish(messages, to: target)
        XCTAssertEqual(outcomes.map(\.accepted), [true, true, true])
        XCTAssertEqual(outcomes.map(\.packetIdentifier), [nil, 2, 3])

        await eventually("broker saw DISCONNECT") { broker.packets.last?.type == .disconnect }
        let types = broker.packets.map(\.type)
        XCTAssertEqual(types, [.connect, .publish, .publish, .publish, .pubrel, .disconnect])
        guard case .connect(let connect) = broker.packets[0] else { return XCTFail() }
        XCTAssertEqual(connect.clientIdentifier, "tester")
        XCTAssertEqual(connect.username, "me")
        XCTAssertEqual(connect.password, Array("secret".utf8))
        guard case .publish(let retained) = broker.packets[2] else { return XCTFail() }
        XCTAssertTrue(retained.retain)
        XCTAssertEqual(retained.payload, Array("one".utf8))

        // Everything sent and received is in the capture stream, labelled with the broker.
        await eventually("captured DISCONNECT") {
            log.events.contains { if case .mqtt(let m) = $0 { m.event.packet.type == .disconnect } else { false } }
        }
        let captured = log.events.compactMap { event -> MQTTCaptureEvent? in if case .mqtt(let m) = event { m } else { nil } }
        XCTAssertEqual(captured.filter { $0.event.direction == .clientToBroker }.map(\.event.packet.type),
                       [.connect, .publish, .publish, .publish, .pubrel, .disconnect])
        XCTAssertEqual(captured.filter { $0.event.direction == .brokerToClient }.map(\.event.packet.type),
                       [.connack, .puback, .pubrec, .pubcomp])
        XCTAssertEqual(Set(captured.map(\.broker)), [target.label])
        try await server.close()
    }

    func testV5PropertiesAndRefusals() async throws {
        let broker = RecordingBroker()
        broker.refuseTopic = "forbidden"
        let server = try await startBroker(broker)
        let publisher = MQTTPublisher(group: group, sink: nil)
        let target = MQTTBrokerTarget(host: "127.0.0.1", port: server.localAddress!.port!, version: .v5)
        var message = MQTTOutgoingMessage(topic: "ok", payload: Array("{}".utf8), qos: .atLeastOnce, contentType: "application/json",
                                          userProperties: [.init(key: "source", value: "replay")])
        message.payloadIsUTF8 = true
        let refused = MQTTOutgoingMessage(topic: "forbidden", payload: [], qos: .atLeastOnce)
        let outcomes = try await publisher.publish([message, refused], to: target)
        XCTAssertEqual(outcomes.map(\.reasonCode), [0, 0x87])

        await eventually { broker.packets.count >= 3 }
        guard case .publish(let publish) = broker.packets[1] else { return XCTFail() }
        XCTAssertEqual(publish.properties, [.payloadFormatIndicator(1), .contentType("application/json"), .userProperty(key: "source", value: "replay")])
        try await server.close()
    }

    func testRefusedConnectionAndWildcardTopic() async throws {
        let broker = RecordingBroker()
        broker.connackCode = 5
        let server = try await startBroker(broker)
        let publisher = MQTTPublisher(group: group, sink: nil, timeout: .seconds(2))
        let target = MQTTBrokerTarget(host: "127.0.0.1", port: server.localAddress!.port!)
        do {
            try await publisher.publish([MQTTOutgoingMessage(topic: "t", payload: [])], to: target)
            XCTFail("expected a refusal")
        } catch let error as MQTTPublisherError {
            XCTAssertEqual(error, .connectionRefused(reasonCode: 5, version: .v3_1_1))
            XCTAssertTrue(error.description.contains("not authorized"))
        }
        do {
            try await publisher.publish([MQTTOutgoingMessage(topic: "a/#", payload: [])], to: target)
            XCTFail("expected invalid topic")
        } catch let error as MQTTPublisherError {
            guard case .invalidMessage = error else { return XCTFail("\(error)") }
        }
        try await server.close()
    }

    func testTimesOutWhenTheBrokerNeverAnswers() async throws {
        let silent = try await startServer(group: group) { channel in channel.eventLoop.makeSucceededVoidFuture() }
        let publisher = MQTTPublisher(group: group, sink: nil, timeout: .milliseconds(300))
        do {
            try await publisher.publish([MQTTOutgoingMessage(topic: "t", payload: [])],
                                        to: MQTTBrokerTarget(host: "127.0.0.1", port: silent.localAddress!.port!))
            XCTFail("expected a timeout")
        } catch let error as MQTTPublisherError {
            XCTAssertEqual(error, .timedOut(waitingFor: "CONNACK"))
        }
        try await silent.close()
    }

    func testReplayCopiesPropertiesAndResolvesAlias() {
        let captured = MQTTPublish(topic: "", payload: [1], qos: .atLeastOnce, retain: true, packetIdentifier: 9,
                                   properties: [.topicAlias(3), .contentType("x"), .responseTopic("r"), .userProperty(key: "a", value: "b")])
        let message = MQTTOutgoingMessage(replaying: captured, resolvedTopic: "home/x")
        XCTAssertEqual(message.topic, "home/x")
        XCTAssertEqual(message.contentType, "x")
        XCTAssertEqual(message.responseTopic, "r")
        XCTAssertEqual(message.userProperties, [.init(key: "a", value: "b")])
        // The alias belonged to the original connection; v3 drops properties entirely.
        XCTAssertFalse(message.packet(version: .v5, packetIdentifier: 1).properties.contains(.topicAlias(3)))
        XCTAssertEqual(message.packet(version: .v3_1_1, packetIdentifier: 1).properties, [])
    }
}

/// What the recording broker received, and how it answers.
final class RecordingBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var _packets: [MQTTPacket] = []
    var connackCode: UInt8 = 0
    var refuseTopic: String?

    var packets: [MQTTPacket] { lock.withLock { _packets } }
    func append(_ packet: MQTTPacket) { lock.withLock { _packets.append(packet) } }
}

/// A broker good enough for a publisher: CONNACK, PUBACK, PUBREC/PUBCOMP.
final class RecordingBrokerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let broker: RecordingBroker
    private var decoder = MQTTStreamDecoder()
    private var version = MQTTVersion.v3_1_1

    init(broker: RecordingBroker) { self.broker = broker }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let frames = try? decoder.feed(buffer.readableBytesView) else { return context.close(promise: nil) }
        for frame in frames {
            broker.append(frame.packet)
            switch frame.packet {
            case .connect(let connect):
                version = connect.version
                let code = broker.connackCode
                let bytes: [UInt8] = version == .v5 ? [0x20, 0x03, 0x00, code, 0x00] : [0x20, 0x02, 0x00, code]
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: bytes)), promise: nil)
            case .publish(let publish):
                guard let id = publish.packetIdentifier else { continue }
                let code: UInt8 = publish.topic == broker.refuseTopic ? 0x87 : 0
                reply(publish.qos == .atLeastOnce ? .puback(.init(packetIdentifier: id, reasonCode: code))
                                                   : .pubrec(.init(packetIdentifier: id, reasonCode: code)), context: context)
            case .pubrel(let rel):
                reply(.pubcomp(.init(packetIdentifier: rel.packetIdentifier)), context: context)
            case .disconnect:
                context.close(promise: nil)
            default:
                break
            }
        }
    }

    private func reply(_ packet: MQTTPacket, context: ChannelHandlerContext) {
        let bytes = (try? MQTTPacketEncoder.encode(packet, version: version)) ?? []
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: bytes)), promise: nil)
    }
}
