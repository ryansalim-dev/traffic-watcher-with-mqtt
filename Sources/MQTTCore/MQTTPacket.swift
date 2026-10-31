/// MQTT protocol revision, as carried in the CONNECT protocol level byte.
public enum MQTTVersion: UInt8, Sendable, CustomStringConvertible {
    case v3_1 = 3
    case v3_1_1 = 4
    case v5 = 5

    public var description: String {
        switch self {
        case .v3_1: "3.1"
        case .v3_1_1: "3.1.1"
        case .v5: "5.0"
        }
    }
}

public enum MQTTPacketType: UInt8, Sendable, CaseIterable {
    case connect = 1, connack, publish, puback, pubrec, pubrel, pubcomp
    case subscribe, suback, unsubscribe, unsuback, pingreq, pingresp, disconnect, auth
}

public enum MQTTQoS: UInt8, Sendable {
    case atMostOnce = 0, atLeastOnce, exactlyOnce
}

public struct MQTTWill: Equatable, Sendable {
    public var topic: String
    public var payload: [UInt8]
    public var qos: MQTTQoS
    public var retain: Bool
    public var properties: [MQTTProperty]
}

public struct MQTTConnect: Equatable, Sendable {
    public var protocolName: String
    public var version: MQTTVersion
    public var cleanStart: Bool
    public var keepAlive: UInt16
    public var properties: [MQTTProperty]
    public var clientIdentifier: String
    public var will: MQTTWill?
    public var username: String?
    public var password: [UInt8]?
}

public struct MQTTConnAck: Equatable, Sendable {
    public var sessionPresent: Bool
    /// v3 return code or v5 reason code.
    public var reasonCode: UInt8
    public var properties: [MQTTProperty]
}

public struct MQTTPublish: Equatable, Sendable {
    public var duplicate: Bool
    public var qos: MQTTQoS
    public var retain: Bool
    /// Topic as sent on the wire; may be empty in v5 when a topic alias is used.
    public var topic: String
    public var packetIdentifier: UInt16?
    public var properties: [MQTTProperty]
    public var payload: [UInt8]

    public var topicAlias: UInt16? {
        properties.lazy.compactMap { if case .topicAlias(let v) = $0 { v } else { nil } }.first
    }
}

/// PUBACK, PUBREC, PUBREL and PUBCOMP share one shape.
public struct MQTTPublishAcknowledgement: Equatable, Sendable {
    public var packetIdentifier: UInt16
    public var reasonCode: UInt8
    public var properties: [MQTTProperty]
}

public struct MQTTSubscription: Equatable, Sendable {
    public var topicFilter: String
    public var qos: MQTTQoS
    /// v5 only, false otherwise.
    public var noLocal: Bool
    public var retainAsPublished: Bool
    public var retainHandling: UInt8
}

public struct MQTTSubscribe: Equatable, Sendable {
    public var packetIdentifier: UInt16
    public var properties: [MQTTProperty]
    public var subscriptions: [MQTTSubscription]
}

/// SUBACK and UNSUBACK.
public struct MQTTSubscribeAcknowledgement: Equatable, Sendable {
    public var packetIdentifier: UInt16
    public var properties: [MQTTProperty]
    public var reasonCodes: [UInt8]
}

public struct MQTTUnsubscribe: Equatable, Sendable {
    public var packetIdentifier: UInt16
    public var properties: [MQTTProperty]
    public var topicFilters: [String]
}

/// DISCONNECT and AUTH.
public struct MQTTReasonPacket: Equatable, Sendable {
    public var reasonCode: UInt8
    public var properties: [MQTTProperty]
}

public enum MQTTPacket: Equatable, Sendable {
    case connect(MQTTConnect)
    case connack(MQTTConnAck)
    case publish(MQTTPublish)
    case puback(MQTTPublishAcknowledgement)
    case pubrec(MQTTPublishAcknowledgement)
    case pubrel(MQTTPublishAcknowledgement)
    case pubcomp(MQTTPublishAcknowledgement)
    case subscribe(MQTTSubscribe)
    case suback(MQTTSubscribeAcknowledgement)
    case unsubscribe(MQTTUnsubscribe)
    case unsuback(MQTTSubscribeAcknowledgement)
    case pingreq
    case pingresp
    case disconnect(MQTTReasonPacket)
    case auth(MQTTReasonPacket)

    public var type: MQTTPacketType {
        switch self {
        case .connect: .connect
        case .connack: .connack
        case .publish: .publish
        case .puback: .puback
        case .pubrec: .pubrec
        case .pubrel: .pubrel
        case .pubcomp: .pubcomp
        case .subscribe: .subscribe
        case .suback: .suback
        case .unsubscribe: .unsubscribe
        case .unsuback: .unsuback
        case .pingreq: .pingreq
        case .pingresp: .pingresp
        case .disconnect: .disconnect
        case .auth: .auth
        }
    }
}
