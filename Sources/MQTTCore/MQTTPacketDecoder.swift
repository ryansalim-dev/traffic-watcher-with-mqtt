/// Decodes one complete MQTT control packet (fixed header included).
public enum MQTTPacketDecoder {
    /// Decodes `bytes`, which must hold exactly one control packet.
    /// - Parameter version: the session's protocol version; v5 enables property blocks.
    ///   A CONNECT packet ignores this and uses the level it carries.
    public static func decode(_ bytes: [UInt8], version: MQTTVersion) throws -> MQTTPacket {
        var reader = ByteReader(bytes)
        let header = try reader.readUInt8()
        let length = Int(try reader.readVariableByteInteger())
        guard reader.remaining == length else { throw MQTTDecodingError.unexpectedEndOfPacket }
        guard let type = MQTTPacketType(rawValue: header >> 4) else {
            throw MQTTDecodingError.invalidPacketType(header >> 4)
        }
        if type == .auth && version != .v5 { throw MQTTDecodingError.invalidPacketType(header >> 4) }
        let flags = header & 0x0F
        let v5 = version == .v5

        switch type {
        case .connect:
            return .connect(try decodeConnect(&reader))
        case .connack:
            let ackFlags = try reader.readUInt8()
            let code = try reader.readUInt8()
            let properties = v5 && !reader.isAtEnd ? try reader.readProperties() : []
            return .connack(.init(sessionPresent: ackFlags & 0x01 != 0, reasonCode: code, properties: properties))
        case .publish:
            return .publish(try decodePublish(&reader, flags: flags, v5: v5))
        case .puback, .pubrec, .pubrel, .pubcomp:
            let ack = try decodePublishAcknowledgement(&reader, v5: v5)
            switch type {
            case .puback: return .puback(ack)
            case .pubrec: return .pubrec(ack)
            case .pubrel: return .pubrel(ack)
            default: return .pubcomp(ack)
            }
        case .subscribe:
            let id = try reader.readUInt16()
            let properties = v5 ? try reader.readProperties() : []
            var subscriptions: [MQTTSubscription] = []
            while !reader.isAtEnd {
                let filter = try reader.readString()
                let options = try reader.readUInt8()
                subscriptions.append(.init(
                    topicFilter: filter,
                    qos: MQTTQoS(rawValue: options & 0x03) ?? .atMostOnce,
                    noLocal: v5 && options & 0x04 != 0,
                    retainAsPublished: v5 && options & 0x08 != 0,
                    retainHandling: v5 ? (options >> 4) & 0x03 : 0
                ))
            }
            return .subscribe(.init(packetIdentifier: id, properties: properties, subscriptions: subscriptions))
        case .suback, .unsuback:
            let id = try reader.readUInt16()
            let properties = v5 ? try reader.readProperties() : []
            let ack = MQTTSubscribeAcknowledgement(packetIdentifier: id, properties: properties, reasonCodes: reader.readRest())
            return type == .suback ? .suback(ack) : .unsuback(ack)
        case .unsubscribe:
            let id = try reader.readUInt16()
            let properties = v5 ? try reader.readProperties() : []
            var filters: [String] = []
            while !reader.isAtEnd { filters.append(try reader.readString()) }
            return .unsubscribe(.init(packetIdentifier: id, properties: properties, topicFilters: filters))
        case .pingreq:
            return .pingreq
        case .pingresp:
            return .pingresp
        case .disconnect, .auth:
            // v5: reason code and properties are both optional (absent means 0x00 Success).
            let code: UInt8 = v5 && !reader.isAtEnd ? try reader.readUInt8() : 0
            let properties = v5 && !reader.isAtEnd ? try reader.readProperties() : []
            let packet = MQTTReasonPacket(reasonCode: code, properties: properties)
            return type == .disconnect ? .disconnect(packet) : .auth(packet)
        }
    }

    private static func decodeConnect(_ reader: inout ByteReader) throws -> MQTTConnect {
        let protocolName = try reader.readString()
        let level = try reader.readUInt8()
        guard let version = MQTTVersion(rawValue: level) else {
            throw MQTTDecodingError.unsupportedProtocolLevel(level)
        }
        let v5 = version == .v5
        let flags = try reader.readUInt8()
        let keepAlive = try reader.readUInt16()
        let properties = v5 ? try reader.readProperties() : []
        let clientIdentifier = try reader.readString()

        var will: MQTTWill?
        if flags & 0x04 != 0 {
            let willProperties = v5 ? try reader.readProperties() : []
            let topic = try reader.readString()
            let payload = try reader.readBinary()
            will = MQTTWill(
                topic: topic,
                payload: payload,
                qos: MQTTQoS(rawValue: (flags >> 3) & 0x03) ?? .atMostOnce,
                retain: flags & 0x20 != 0,
                properties: willProperties
            )
        }
        let username = flags & 0x80 != 0 ? try reader.readString() : nil
        let password = flags & 0x40 != 0 ? try reader.readBinary() : nil

        return MQTTConnect(
            protocolName: protocolName,
            version: version,
            cleanStart: flags & 0x02 != 0,
            keepAlive: keepAlive,
            properties: properties,
            clientIdentifier: clientIdentifier,
            will: will,
            username: username,
            password: password
        )
    }

    private static func decodePublish(_ reader: inout ByteReader, flags: UInt8, v5: Bool) throws -> MQTTPublish {
        let qos = MQTTQoS(rawValue: (flags >> 1) & 0x03) ?? .atMostOnce
        let topic = try reader.readString()
        let id = qos == .atMostOnce ? nil : try reader.readUInt16()
        let properties = v5 ? try reader.readProperties() : []
        return MQTTPublish(
            duplicate: flags & 0x08 != 0,
            qos: qos,
            retain: flags & 0x01 != 0,
            topic: topic,
            packetIdentifier: id,
            properties: properties,
            payload: reader.readRest()
        )
    }

    private static func decodePublishAcknowledgement(_ reader: inout ByteReader, v5: Bool) throws -> MQTTPublishAcknowledgement {
        let id = try reader.readUInt16()
        let code: UInt8 = v5 && !reader.isAtEnd ? try reader.readUInt8() : 0
        let properties = v5 && !reader.isAtEnd ? try reader.readProperties() : []
        return .init(packetIdentifier: id, reasonCode: code, properties: properties)
    }
}
