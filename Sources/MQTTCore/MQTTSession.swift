/// Which side of the connection sent a packet.
public enum MQTTDirection: String, Sendable, Equatable, Codable {
    case clientToBroker
    case brokerToClient
}

/// A decoded packet in the context of its connection.
public struct MQTTSessionEvent: Equatable, Sendable {
    public var direction: MQTTDirection
    /// Protocol version the frame was decoded with, needed to decode `frame.rawBytes` again.
    public var version: MQTTVersion
    public var frame: MQTTFrame
    /// For PUBLISH: the topic after resolving a v5 topic alias, so the UI never shows an empty topic.
    public var resolvedTopic: String?

    public var packet: MQTTPacket { frame.packet }

    public init(direction: MQTTDirection, version: MQTTVersion, frame: MQTTFrame, resolvedTopic: String?) {
        self.direction = direction
        self.version = version
        self.frame = frame
        self.resolvedTopic = resolvedTopic
    }
}

/// Tracks one MQTT connection seen by the proxy: both byte streams, the negotiated version,
/// the client identity and v5 topic aliases (which are scoped per direction).
public struct MQTTSession: Sendable {
    public private(set) var version: MQTTVersion = .v3_1_1
    public private(set) var clientIdentifier: String?
    private var clientDecoder = MQTTStreamDecoder()
    private var brokerDecoder = MQTTStreamDecoder()
    private var clientAliases: [UInt16: String] = [:]
    private var brokerAliases: [UInt16: String] = [:]

    public init() {}

    public mutating func receive<Bytes: Sequence>(_ bytes: Bytes, from direction: MQTTDirection) throws -> [MQTTSessionEvent]
    where Bytes.Element == UInt8 {
        let frames: [MQTTFrame]
        switch direction {
        case .clientToBroker:
            frames = try clientDecoder.feed(bytes)
        case .brokerToClient:
            brokerDecoder.version = version
            frames = try brokerDecoder.feed(bytes)
        }

        return frames.map { frame in
            var resolvedTopic: String?
            switch frame.packet {
            case .connect(let connect):
                version = connect.version
                clientIdentifier = connect.clientIdentifier
                clientAliases.removeAll()
                brokerAliases.removeAll()
            case .publish(let publish):
                resolvedTopic = resolveTopic(publish, direction: direction)
            default:
                break
            }
            return MQTTSessionEvent(direction: direction, version: version, frame: frame, resolvedTopic: resolvedTopic)
        }
    }

    private mutating func resolveTopic(_ publish: MQTTPublish, direction: MQTTDirection) -> String? {
        guard let alias = publish.topicAlias else { return publish.topic }
        switch (direction, publish.topic.isEmpty) {
        case (.clientToBroker, true): return clientAliases[alias]
        case (.brokerToClient, true): return brokerAliases[alias]
        case (.clientToBroker, false): clientAliases[alias] = publish.topic
        case (.brokerToClient, false): brokerAliases[alias] = publish.topic
        }
        return publish.topic
    }
}
