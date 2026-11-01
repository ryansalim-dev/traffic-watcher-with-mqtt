/// Encodes the control packets a client sends: CONNECT, PUBLISH, the publish acknowledgements,
/// PINGREQ and DISCONNECT. Used by the publisher to talk to brokers; the decoder reads them back.
public enum MQTTPacketEncoder {
    public enum EncodingError: Error, Equatable, Sendable, CustomStringConvertible {
        case stringTooLong(String)
        case binaryTooLong(Int)
        case packetTooLarge(Int)
        /// QoS 1 and 2 publishes need a packet identifier, QoS 0 must not have one.
        case packetIdentifierMismatch
        case unsupported(MQTTPacketType)

        public var description: String {
            switch self {
            case .stringTooLong(let s): "String is longer than 65,535 bytes: \(s.prefix(40))…"
            case .binaryTooLong(let n): "Binary field of \(n) bytes is longer than 65,535 bytes"
            case .packetTooLarge(let n): "Packet of \(n) bytes is larger than MQTT allows"
            case .packetIdentifierMismatch: "QoS 1 and 2 need a packet identifier; QoS 0 must not have one"
            case .unsupported(let type): "Encoding \(type) is not supported"
            }
        }
    }

    /// Encodes `packet` as `version` (ignored for CONNECT, which carries its own).
    public static func encode(_ packet: MQTTPacket, version: MQTTVersion) throws -> [UInt8] {
        let v5 = version == .v5
        var body = ByteWriter()
        let header: UInt8
        switch packet {
        case .connect(let connect):
            header = 0x10
            try encodeConnect(connect, into: &body)
        case .publish(let publish):
            guard (publish.qos == .atMostOnce) == (publish.packetIdentifier == nil) else {
                throw EncodingError.packetIdentifierMismatch
            }
            header = 0x30 | (publish.duplicate ? 0x08 : 0) | (publish.qos.rawValue << 1) | (publish.retain ? 0x01 : 0)
            try body.writeString(publish.topic)
            if let id = publish.packetIdentifier { body.writeUInt16(id) }
            if v5 { try body.writeProperties(publish.properties) }
            body.bytes += publish.payload
        case .puback(let ack), .pubrec(let ack), .pubrel(let ack), .pubcomp(let ack):
            switch packet {
            case .puback: header = 0x40
            case .pubrec: header = 0x50
            case .pubrel: header = 0x62 // PUBREL has fixed flags 0010
            default: header = 0x70
            }
            body.writeUInt16(ack.packetIdentifier)
            if v5 && (ack.reasonCode != 0 || !ack.properties.isEmpty) {
                body.writeUInt8(ack.reasonCode)
                if !ack.properties.isEmpty { try body.writeProperties(ack.properties) }
            }
        case .pingreq:
            header = 0xC0
        case .disconnect(let reason):
            header = 0xE0
            if v5 && (reason.reasonCode != 0 || !reason.properties.isEmpty) {
                body.writeUInt8(reason.reasonCode)
                if !reason.properties.isEmpty { try body.writeProperties(reason.properties) }
            }
        default:
            throw EncodingError.unsupported(packet.type)
        }
        let length = body.bytes.count
        guard length <= 268_435_455 else { throw EncodingError.packetTooLarge(length) }
        var packetBytes = ByteWriter()
        packetBytes.writeUInt8(header)
        packetBytes.writeVariableByteInteger(UInt32(length))
        packetBytes.bytes += body.bytes
        return packetBytes.bytes
    }

    private static func encodeConnect(_ connect: MQTTConnect, into body: inout ByteWriter) throws {
        let v5 = connect.version == .v5
        try body.writeString(connect.protocolName)
        body.writeUInt8(connect.version.rawValue)
        var flags: UInt8 = connect.cleanStart ? 0x02 : 0
        if let will = connect.will {
            flags |= 0x04 | (will.qos.rawValue << 3) | (will.retain ? 0x20 : 0)
        }
        if connect.username != nil { flags |= 0x80 }
        if connect.password != nil { flags |= 0x40 }
        body.writeUInt8(flags)
        body.writeUInt16(connect.keepAlive)
        if v5 { try body.writeProperties(connect.properties) }
        try body.writeString(connect.clientIdentifier)
        if let will = connect.will {
            if v5 { try body.writeProperties(will.properties) }
            try body.writeString(will.topic)
            try body.writeBinary(will.payload)
        }
        if let username = connect.username { try body.writeString(username) }
        if let password = connect.password { try body.writeBinary(password) }
    }
}

extension MQTTConnect {
    public init(version: MQTTVersion, clientIdentifier: String, cleanStart: Bool = true, keepAlive: UInt16 = 60,
                username: String? = nil, password: [UInt8]? = nil, properties: [MQTTProperty] = [], will: MQTTWill? = nil) {
        self.init(protocolName: version == .v3_1 ? "MQIsdp" : "MQTT", version: version, cleanStart: cleanStart,
                  keepAlive: keepAlive, properties: properties, clientIdentifier: clientIdentifier,
                  will: will, username: username, password: password)
    }
}

extension MQTTPublish {
    public init(topic: String, payload: [UInt8], qos: MQTTQoS = .atMostOnce, retain: Bool = false,
                packetIdentifier: UInt16? = nil, properties: [MQTTProperty] = [], duplicate: Bool = false) {
        self.init(duplicate: duplicate, qos: qos, retain: retain, topic: topic,
                  packetIdentifier: packetIdentifier, properties: properties, payload: payload)
    }
}

extension MQTTPublishAcknowledgement {
    public init(packetIdentifier: UInt16, reasonCode: UInt8 = 0) {
        self.init(packetIdentifier: packetIdentifier, reasonCode: reasonCode, properties: [])
    }
}

extension MQTTReasonPacket {
    public init(reasonCode: UInt8 = 0) {
        self.init(reasonCode: reasonCode, properties: [])
    }
}

/// Big-endian writer mirroring `ByteReader`.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }

    mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func writeUInt32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func writeVariableByteInteger(_ value: UInt32) {
        var value = value
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
    }

    mutating func writeString(_ string: String) throws {
        let utf8 = Array(string.utf8)
        guard utf8.count <= 65_535 else { throw MQTTPacketEncoder.EncodingError.stringTooLong(string) }
        writeUInt16(UInt16(utf8.count))
        bytes += utf8
    }

    mutating func writeBinary(_ data: [UInt8]) throws {
        guard data.count <= 65_535 else { throw MQTTPacketEncoder.EncodingError.binaryTooLong(data.count) }
        writeUInt16(UInt16(data.count))
        bytes += data
    }

    mutating func writeProperties(_ properties: [MQTTProperty]) throws {
        var block = ByteWriter()
        for property in properties { try block.writeProperty(property) }
        writeVariableByteInteger(UInt32(block.bytes.count))
        bytes += block.bytes
    }

    private mutating func writeProperty(_ property: MQTTProperty) throws {
        switch property {
        case .payloadFormatIndicator(let v): writeVariableByteInteger(0x01); writeUInt8(v)
        case .messageExpiryInterval(let v): writeVariableByteInteger(0x02); writeUInt32(v)
        case .contentType(let v): writeVariableByteInteger(0x03); try writeString(v)
        case .responseTopic(let v): writeVariableByteInteger(0x08); try writeString(v)
        case .correlationData(let v): writeVariableByteInteger(0x09); try writeBinary(v)
        case .subscriptionIdentifier(let v): writeVariableByteInteger(0x0B); writeVariableByteInteger(v)
        case .sessionExpiryInterval(let v): writeVariableByteInteger(0x11); writeUInt32(v)
        case .assignedClientIdentifier(let v): writeVariableByteInteger(0x12); try writeString(v)
        case .serverKeepAlive(let v): writeVariableByteInteger(0x13); writeUInt16(v)
        case .authenticationMethod(let v): writeVariableByteInteger(0x15); try writeString(v)
        case .authenticationData(let v): writeVariableByteInteger(0x16); try writeBinary(v)
        case .requestProblemInformation(let v): writeVariableByteInteger(0x17); writeUInt8(v)
        case .willDelayInterval(let v): writeVariableByteInteger(0x18); writeUInt32(v)
        case .requestResponseInformation(let v): writeVariableByteInteger(0x19); writeUInt8(v)
        case .responseInformation(let v): writeVariableByteInteger(0x1A); try writeString(v)
        case .serverReference(let v): writeVariableByteInteger(0x1C); try writeString(v)
        case .reasonString(let v): writeVariableByteInteger(0x1F); try writeString(v)
        case .receiveMaximum(let v): writeVariableByteInteger(0x21); writeUInt16(v)
        case .topicAliasMaximum(let v): writeVariableByteInteger(0x22); writeUInt16(v)
        case .topicAlias(let v): writeVariableByteInteger(0x23); writeUInt16(v)
        case .maximumQoS(let v): writeVariableByteInteger(0x24); writeUInt8(v)
        case .retainAvailable(let v): writeVariableByteInteger(0x25); writeUInt8(v)
        case .userProperty(let key, let value): writeVariableByteInteger(0x26); try writeString(key); try writeString(value)
        case .maximumPacketSize(let v): writeVariableByteInteger(0x27); writeUInt32(v)
        case .wildcardSubscriptionAvailable(let v): writeVariableByteInteger(0x28); writeUInt8(v)
        case .subscriptionIdentifierAvailable(let v): writeVariableByteInteger(0x29); writeUInt8(v)
        case .sharedSubscriptionAvailable(let v): writeVariableByteInteger(0x2A); writeUInt8(v)
        }
    }
}
