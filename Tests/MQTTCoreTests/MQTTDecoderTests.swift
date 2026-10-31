import XCTest
@testable import MQTTCore

/// Small builders for hand-assembling packets in tests.
private func str(_ s: String) -> [UInt8] {
    let u = Array(s.utf8)
    return cat([UInt8(u.count >> 8), UInt8(u.count & 0xFF)], u)
}

private func varInt(_ value: Int) -> [UInt8] {
    var v = value, out: [UInt8] = []
    repeat {
        var byte = UInt8(v % 128)
        v /= 128
        if v > 0 { byte |= 0x80 }
        out.append(byte)
    } while v > 0
    return out
}

private func packet(_ header: UInt8, _ body: [UInt8]) -> [UInt8] {
    cat([header], varInt(body.count), body)
}

private func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

private func props(_ body: [UInt8]) -> [UInt8] { cat(varInt(body.count), body) }

final class MQTTDecoderTests: XCTestCase {
    func testConnectV311WithWillAndCredentials() throws {
        // flags: username, password, will retain, will QoS 1, will, clean session
        let flags: UInt8 = 0x80 | 0x40 | 0x20 | 0x08 | 0x04 | 0x02
        let body = cat(str("MQTT"), [4, flags, 0x00, 0x3C], str("sensor-1"),
                       str("status"), str("offline"), str("ryan"), str("secret"))
        let decoded = try MQTTPacketDecoder.decode(packet(0x10, body), version: .v3_1_1)

        guard case .connect(let c) = decoded else { return XCTFail("expected CONNECT") }
        XCTAssertEqual(c.version, .v3_1_1)
        XCTAssertEqual(c.keepAlive, 60)
        XCTAssertTrue(c.cleanStart)
        XCTAssertEqual(c.clientIdentifier, "sensor-1")
        XCTAssertEqual(c.will?.topic, "status")
        XCTAssertEqual(c.will?.payload, Array("offline".utf8))
        XCTAssertEqual(c.will?.qos, .atLeastOnce)
        XCTAssertEqual(c.will?.retain, true)
        XCTAssertEqual(c.username, "ryan")
        XCTAssertEqual(c.password, Array("secret".utf8))
    }

    func testConnectV5WithProperties() throws {
        let p = props(cat([0x11, 0, 0, 0x0E, 0x10, 0x26], str("app"), str("demo")))
        let body = cat(str("MQTT"), [5, 0x02, 0x00, 0x1E], p, str(""))
        let decoded = try MQTTPacketDecoder.decode(packet(0x10, body), version: .v3_1_1)

        guard case .connect(let c) = decoded else { return XCTFail("expected CONNECT") }
        XCTAssertEqual(c.version, .v5)
        XCTAssertEqual(c.properties, [.sessionExpiryInterval(3600), .userProperty(key: "app", value: "demo")])
        XCTAssertEqual(c.clientIdentifier, "")
    }

    func testPublishQoS1V311() throws {
        let body = cat(str("home/temp"), [0x00, 0x2A], Array("21.5".utf8))
        let decoded = try MQTTPacketDecoder.decode(packet(0x3B, body), version: .v3_1_1) // DUP, QoS1, retain

        guard case .publish(let p) = decoded else { return XCTFail("expected PUBLISH") }
        XCTAssertTrue(p.duplicate)
        XCTAssertTrue(p.retain)
        XCTAssertEqual(p.qos, .atLeastOnce)
        XCTAssertEqual(p.topic, "home/temp")
        XCTAssertEqual(p.packetIdentifier, 42)
        XCTAssertEqual(p.payload, Array("21.5".utf8))
    }

    func testPublishV5WithContentTypeAndAlias() throws {
        let p = props(cat([0x01, 0x01, 0x03], str("application/json"), [0x23, 0x00, 0x05]))
        let body = cat(str("a/b"), p, Array("{}".utf8))
        let decoded = try MQTTPacketDecoder.decode(packet(0x30, body), version: .v5)

        guard case .publish(let pub) = decoded else { return XCTFail("expected PUBLISH") }
        XCTAssertNil(pub.packetIdentifier)
        XCTAssertEqual(pub.properties, [.payloadFormatIndicator(1), .contentType("application/json"), .topicAlias(5)])
        XCTAssertEqual(pub.topicAlias, 5)
        XCTAssertEqual(pub.payload, Array("{}".utf8))
    }

    func testSubscribeV5Options() throws {
        // QoS 2, no local, retain as published, retain handling 2
        let options: UInt8 = 0x02 | 0x04 | 0x08 | 0x20
        let body = cat([0x00, 0x07], props([0x0B, 0x09]), str("devices/+/state"), [options])
        let decoded = try MQTTPacketDecoder.decode(packet(0x82, body), version: .v5)

        guard case .subscribe(let s) = decoded else { return XCTFail("expected SUBSCRIBE") }
        XCTAssertEqual(s.packetIdentifier, 7)
        XCTAssertEqual(s.properties, [.subscriptionIdentifier(9)])
        XCTAssertEqual(s.subscriptions, [
            MQTTSubscription(topicFilter: "devices/+/state", qos: .exactlyOnce, noLocal: true, retainAsPublished: true, retainHandling: 2),
        ])
    }

    func testSubAckV311() throws {
        let decoded = try MQTTPacketDecoder.decode(packet(0x90, [0x00, 0x07, 0x00, 0x01, 0x80]), version: .v3_1_1)
        XCTAssertEqual(decoded, .suback(.init(packetIdentifier: 7, properties: [], reasonCodes: [0x00, 0x01, 0x80])))
    }

    func testShortPubAckV5DefaultsToSuccess() throws {
        let decoded = try MQTTPacketDecoder.decode(packet(0x40, [0x00, 0x2A]), version: .v5)
        XCTAssertEqual(decoded, .puback(.init(packetIdentifier: 42, reasonCode: 0, properties: [])))
    }

    func testDisconnectV5WithReasonString() throws {
        let body = cat([0x8E], props(cat([0x1F], str("session taken over"))))
        let decoded = try MQTTPacketDecoder.decode(packet(0xE0, body), version: .v5)
        XCTAssertEqual(decoded, .disconnect(.init(reasonCode: 0x8E, properties: [.reasonString("session taken over")])))
    }

    func testPingPackets() throws {
        XCTAssertEqual(try MQTTPacketDecoder.decode([0xC0, 0x00], version: .v3_1_1), .pingreq)
        XCTAssertEqual(try MQTTPacketDecoder.decode([0xD0, 0x00], version: .v3_1_1), .pingresp)
    }

    func testRejectsInvalidUTF8Topic() {
        let body: [UInt8] = [0x00, 0x02, 0xC3, 0x28]
        XCTAssertThrowsError(try MQTTPacketDecoder.decode(packet(0x30, body), version: .v3_1_1)) {
            XCTAssertEqual($0 as? MQTTDecodingError, .invalidUTF8String)
        }
    }

    func testRejectsAuthBeforeV5() {
        XCTAssertThrowsError(try MQTTPacketDecoder.decode([0xF0, 0x00], version: .v3_1_1))
    }
}

final class MQTTStreamDecoderTests: XCTestCase {
    func testReassemblesPacketsSplitAcrossChunks() throws {
        let publish = packet(0x30, cat(str("t"), Array(repeating: 0x41, count: 200))) // 2-byte remaining length
        let stream = cat(publish, [0xC0, 0x00], publish)
        var decoder = MQTTStreamDecoder()
        var frames: [MQTTFrame] = []
        for byte in stream { frames += try decoder.feed([byte]) }

        XCTAssertEqual(frames.map(\.packet.type), [.publish, .pingreq, .publish])
        XCTAssertEqual(frames[0].rawBytes, publish)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testSwitchesToV5AfterConnectInSameChunk() throws {
        let connect = packet(0x10, cat(str("MQTT"), [5, 0x02, 0, 0], props([]), str("c")))
        let publish = packet(0x30, cat(str("x"), props([0x23, 0x00, 0x01]), [0x01]))
        var decoder = MQTTStreamDecoder()
        let frames = try decoder.feed(connect + publish)

        XCTAssertEqual(decoder.version, .v5)
        guard case .publish(let p) = frames.last?.packet else { return XCTFail("expected PUBLISH") }
        XCTAssertEqual(p.topicAlias, 1)
        XCTAssertEqual(p.payload, [0x01])
    }

    func testRejectsOversizedPacket() {
        var decoder = MQTTStreamDecoder(maximumPacketSize: 16)
        XCTAssertThrowsError(try decoder.feed(packet(0x30, cat(str("t"), Array(repeating: 0, count: 32)))))
    }
}

final class MQTTSessionTests: XCTestCase {
    func testResolvesTopicAliasesPerDirection() throws {
        var session = MQTTSession()
        _ = try session.receive(packet(0x10, cat(str("MQTT"), [5, 0x02, 0, 0], props([]), str("phone"))), from: .clientToBroker)
        XCTAssertEqual(session.version, .v5)
        XCTAssertEqual(session.clientIdentifier, "phone")

        // Broker reply is parsed as v5 because the session learned the version from CONNECT.
        let connack = try session.receive(packet(0x20, cat([0x00, 0x00], props([0x22, 0x00, 0x0A]))), from: .brokerToClient)
        XCTAssertEqual(connack.first?.packet, .connack(.init(sessionPresent: false, reasonCode: 0, properties: [.topicAliasMaximum(10)])))

        let first = try session.receive(packet(0x30, cat(str("car/speed"), props([0x23, 0x00, 0x03]), [0x10])), from: .clientToBroker)
        let second = try session.receive(packet(0x30, cat(str(""), props([0x23, 0x00, 0x03]), [0x11])), from: .clientToBroker)
        let otherSide = try session.receive(packet(0x30, cat(str(""), props([0x23, 0x00, 0x03]), [0x12])), from: .brokerToClient)

        XCTAssertEqual(first.first?.resolvedTopic, "car/speed")
        XCTAssertEqual(second.first?.resolvedTopic, "car/speed")
        XCTAssertNil(otherSide.first?.resolvedTopic, "aliases are not shared across directions")
    }
}
