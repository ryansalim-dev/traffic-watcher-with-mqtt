/// An MQTT 5 property. Unknown identifiers are rejected, as the spec requires.
public enum MQTTProperty: Equatable, Sendable {
    case payloadFormatIndicator(UInt8)
    case messageExpiryInterval(UInt32)
    case contentType(String)
    case responseTopic(String)
    case correlationData([UInt8])
    case subscriptionIdentifier(UInt32)
    case sessionExpiryInterval(UInt32)
    case assignedClientIdentifier(String)
    case serverKeepAlive(UInt16)
    case authenticationMethod(String)
    case authenticationData([UInt8])
    case requestProblemInformation(UInt8)
    case willDelayInterval(UInt32)
    case requestResponseInformation(UInt8)
    case responseInformation(String)
    case serverReference(String)
    case reasonString(String)
    case receiveMaximum(UInt16)
    case topicAliasMaximum(UInt16)
    case topicAlias(UInt16)
    case maximumQoS(UInt8)
    case retainAvailable(UInt8)
    case userProperty(key: String, value: String)
    case maximumPacketSize(UInt32)
    case wildcardSubscriptionAvailable(UInt8)
    case subscriptionIdentifierAvailable(UInt8)
    case sharedSubscriptionAvailable(UInt8)

    /// Human-readable name for inspectors.
    public var name: String {
        switch self {
        case .payloadFormatIndicator: "Payload Format Indicator"
        case .messageExpiryInterval: "Message Expiry Interval"
        case .contentType: "Content Type"
        case .responseTopic: "Response Topic"
        case .correlationData: "Correlation Data"
        case .subscriptionIdentifier: "Subscription Identifier"
        case .sessionExpiryInterval: "Session Expiry Interval"
        case .assignedClientIdentifier: "Assigned Client Identifier"
        case .serverKeepAlive: "Server Keep Alive"
        case .authenticationMethod: "Authentication Method"
        case .authenticationData: "Authentication Data"
        case .requestProblemInformation: "Request Problem Information"
        case .willDelayInterval: "Will Delay Interval"
        case .requestResponseInformation: "Request Response Information"
        case .responseInformation: "Response Information"
        case .serverReference: "Server Reference"
        case .reasonString: "Reason String"
        case .receiveMaximum: "Receive Maximum"
        case .topicAliasMaximum: "Topic Alias Maximum"
        case .topicAlias: "Topic Alias"
        case .maximumQoS: "Maximum QoS"
        case .retainAvailable: "Retain Available"
        case .userProperty: "User Property"
        case .maximumPacketSize: "Maximum Packet Size"
        case .wildcardSubscriptionAvailable: "Wildcard Subscription Available"
        case .subscriptionIdentifierAvailable: "Subscription Identifier Available"
        case .sharedSubscriptionAvailable: "Shared Subscription Available"
        }
    }
}

extension ByteReader {
    /// Reads a v5 property block: a Variable Byte Integer length followed by properties.
    mutating func readProperties() throws -> [MQTTProperty] {
        let length = Int(try readVariableByteInteger())
        guard remaining >= length else { throw MQTTDecodingError.unexpectedEndOfPacket }
        let end = index + length
        var properties: [MQTTProperty] = []
        while index < end {
            properties.append(try readProperty())
        }
        guard index == end else { throw MQTTDecodingError.unexpectedEndOfPacket }
        return properties
    }

    private mutating func readProperty() throws -> MQTTProperty {
        let identifier = try readVariableByteInteger()
        switch identifier {
        case 0x01: return .payloadFormatIndicator(try readUInt8())
        case 0x02: return .messageExpiryInterval(try readUInt32())
        case 0x03: return .contentType(try readString())
        case 0x08: return .responseTopic(try readString())
        case 0x09: return .correlationData(try readBinary())
        case 0x0B: return .subscriptionIdentifier(try readVariableByteInteger())
        case 0x11: return .sessionExpiryInterval(try readUInt32())
        case 0x12: return .assignedClientIdentifier(try readString())
        case 0x13: return .serverKeepAlive(try readUInt16())
        case 0x15: return .authenticationMethod(try readString())
        case 0x16: return .authenticationData(try readBinary())
        case 0x17: return .requestProblemInformation(try readUInt8())
        case 0x18: return .willDelayInterval(try readUInt32())
        case 0x19: return .requestResponseInformation(try readUInt8())
        case 0x1A: return .responseInformation(try readString())
        case 0x1C: return .serverReference(try readString())
        case 0x1F: return .reasonString(try readString())
        case 0x21: return .receiveMaximum(try readUInt16())
        case 0x22: return .topicAliasMaximum(try readUInt16())
        case 0x23: return .topicAlias(try readUInt16())
        case 0x24: return .maximumQoS(try readUInt8())
        case 0x25: return .retainAvailable(try readUInt8())
        case 0x26: return .userProperty(key: try readString(), value: try readString())
        case 0x27: return .maximumPacketSize(try readUInt32())
        case 0x28: return .wildcardSubscriptionAvailable(try readUInt8())
        case 0x29: return .subscriptionIdentifierAvailable(try readUInt8())
        case 0x2A: return .sharedSubscriptionAvailable(try readUInt8())
        default: throw MQTTDecodingError.unknownPropertyIdentifier(UInt8(truncatingIfNeeded: identifier))
        }
    }
}
