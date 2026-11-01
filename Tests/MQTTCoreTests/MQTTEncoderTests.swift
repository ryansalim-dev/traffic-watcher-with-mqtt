import XCTest
@testable import MQTTCore

final class MQTTEncoderTests: XCTestCase {
    private func roundTrip(_ packet: MQTTPacket, _ version: MQTTVersion, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try MQTTPacketEncoder.encode(packet, version: version)
        XCTAssertEqual(try MQTTPacketDecoder.decode(bytes, version: version), packet, file: file, line: line)
    }

    func testConnectRoundTripsInBothVersions() throws {
        let will = MQTTWill(topic: "status/dev1", payload: Array("offline".utf8), qos: .atLeastOnce, retain: true, properties: [])
        try roundTrip(.connect(MQTTConnect(version: .v3_1_1, clientIdentifier: "dev1", keepAlive: 30,
                                           username: "u", password: Array("p".utf8), will: will)), .v3_1_1)
        var v5Will = will
        v5Will.properties = [.willDelayInterval(5)]
        try roundTrip(.connect(MQTTConnect(version: .v5, clientIdentifier: "", cleanStart: false, keepAlive: 0,
                                           properties: [.sessionExpiryInterval(60), .receiveMaximum(10)], will: v5Will)), .v5)
        try roundTrip(.connect(MQTTConnect(version: .v3_1, clientIdentifier: "old")), .v3_1)
    }

    func testConnectMatchesTheSpecExample() throws {
        // MQTT 3.1.1 CONNECT, clean session, keep alive 60, client "a".
        let bytes = try MQTTPacketEncoder.encode(.connect(MQTTConnect(version: .v3_1_1, clientIdentifier: "a")), version: .v3_1_1)
        XCTAssertEqual(bytes, [0x10, 0x0D, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C, 0x00, 0x01, 0x61])
    }

    func testPublishRoundTripsAtEveryQoS() throws {
        try roundTrip(.publish(MQTTPublish(topic: "a/b", payload: [1, 2, 3])), .v3_1_1)
        try roundTrip(.publish(MQTTPublish(topic: "a/b", payload: Array("hi".utf8), qos: .atLeastOnce, retain: true, packetIdentifier: 7)), .v3_1_1)
        try roundTrip(.publish(MQTTPublish(topic: "a/b", payload: [], qos: .exactlyOnce, packetIdentifier: 65535,
                                           properties: [.payloadFormatIndicator(1), .contentType("application/json"),
                                                        .responseTopic("reply"), .correlationData([9, 9]),
                                                        .messageExpiryInterval(30), .userProperty(key: "k", value: "v")],
                                           duplicate: true)), .v5)
    }

    func testLargePayloadUsesMultiByteLength() throws {
        let payload = [UInt8](repeating: 0x41, count: 20_000)
        let bytes = try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "t", payload: payload)), version: .v3_1_1)
        XCTAssertEqual(Array(bytes[1...3]), [0xA3, 0x9C, 0x01]) // 20003 as a variable byte integer
        var decoder = MQTTStreamDecoder()
        XCTAssertEqual(try decoder.feed(bytes).map(\.packet), [.publish(MQTTPublish(topic: "t", payload: payload))])
    }

    func testAcknowledgementsPingAndDisconnect() throws {
        for version in [MQTTVersion.v3_1_1, .v5] {
            try roundTrip(.puback(MQTTPublishAcknowledgement(packetIdentifier: 1)), version)
            try roundTrip(.pubrec(MQTTPublishAcknowledgement(packetIdentifier: 2)), version)
            try roundTrip(.pubrel(MQTTPublishAcknowledgement(packetIdentifier: 3)), version)
            try roundTrip(.pubcomp(MQTTPublishAcknowledgement(packetIdentifier: 4)), version)
            try roundTrip(.pingreq, version)
            try roundTrip(.disconnect(MQTTReasonPacket()), version)
        }
        try roundTrip(.puback(MQTTPublishAcknowledgement(packetIdentifier: 5, reasonCode: 0x87, properties: [.reasonString("nope")])), .v5)
        try roundTrip(.disconnect(MQTTReasonPacket(reasonCode: 0x04)), .v5)
        XCTAssertEqual(try MQTTPacketEncoder.encode(.pubrel(MQTTPublishAcknowledgement(packetIdentifier: 3)), version: .v3_1_1),
                       [0x62, 0x02, 0x00, 0x03])
    }

    func testRejectsInvalidPackets() {
        XCTAssertThrowsError(try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "t", payload: [], qos: .atLeastOnce)), version: .v5))
        XCTAssertThrowsError(try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "t", payload: [], packetIdentifier: 1)), version: .v5))
        XCTAssertThrowsError(try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: String(repeating: "x", count: 70_000), payload: [])), version: .v5))
        XCTAssertThrowsError(try MQTTPacketEncoder.encode(.pingresp, version: .v5))
    }
}
