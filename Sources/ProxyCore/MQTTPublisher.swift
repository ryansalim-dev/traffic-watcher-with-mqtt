import Foundation
import MQTTCore
import NIOCore
import NIOPosix
import NIOSSL
import TLSMitm

/// Where the publisher connects, and as whom.
public struct MQTTBrokerTarget: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    /// Off accepts any broker certificate, for test brokers with self-signed certificates.
    public var verifyCertificate: Bool
    public var version: MQTTVersion
    /// Empty asks for a generated one.
    public var clientIdentifier: String
    public var username: String?
    public var password: String?

    public init(host: String, port: Int? = nil, useTLS: Bool = false, verifyCertificate: Bool = true,
                version: MQTTVersion = .v3_1_1, clientIdentifier: String = "", username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port ?? (useTLS ? 8883 : 1883)
        self.useTLS = useTLS
        self.verifyCertificate = verifyCertificate
        self.version = version
        self.clientIdentifier = clientIdentifier
        self.username = username
        self.password = password
    }

    /// `host:port`, the same label the forwarder gives captured packets.
    public var label: String { "\(host):\(port)" }

    /// The identifier sent in CONNECT. Brokers on 3.1.1 may refuse an empty one, so one is made up.
    var effectiveClientIdentifier: String {
        clientIdentifier.isEmpty ? "wiretide-" + UUID().uuidString.prefix(8).lowercased() : clientIdentifier
    }
}

/// A message to publish: what the composer edits and what replay copies from a captured PUBLISH.
public struct MQTTOutgoingMessage: Codable, Equatable, Sendable {
    public struct UserProperty: Codable, Equatable, Hashable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var topic: String
    public var payload: [UInt8]
    public var qos: MQTTQoS
    public var retain: Bool
    // MQTT 5 only; ignored when publishing over 3.1.1.
    public var contentType: String?
    public var responseTopic: String?
    public var correlationData: [UInt8]?
    public var messageExpiryInterval: UInt32?
    public var payloadIsUTF8: Bool
    public var userProperties: [UserProperty]

    public init(topic: String, payload: [UInt8], qos: MQTTQoS = .atMostOnce, retain: Bool = false,
                contentType: String? = nil, responseTopic: String? = nil, correlationData: [UInt8]? = nil,
                messageExpiryInterval: UInt32? = nil, payloadIsUTF8: Bool = false, userProperties: [UserProperty] = []) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
        self.contentType = contentType
        self.responseTopic = responseTopic
        self.correlationData = correlationData
        self.messageExpiryInterval = messageExpiryInterval
        self.payloadIsUTF8 = payloadIsUTF8
        self.userProperties = userProperties
    }

    /// Copies a captured PUBLISH for replay. The topic alias is dropped (it belongs to the original
    /// connection), so `resolvedTopic` supplies the topic when the packet itself had none.
    public init(replaying publish: MQTTPublish, resolvedTopic: String?) {
        self.init(topic: publish.topic.isEmpty ? (resolvedTopic ?? "") : publish.topic, payload: publish.payload,
                  qos: publish.qos, retain: publish.retain)
        for property in publish.properties {
            switch property {
            case .contentType(let v): contentType = v
            case .responseTopic(let v): responseTopic = v
            case .correlationData(let v): correlationData = v
            case .messageExpiryInterval(let v): messageExpiryInterval = v
            case .payloadFormatIndicator(let v): payloadIsUTF8 = v == 1
            case .userProperty(let key, let value): userProperties.append(.init(key: key, value: value))
            default: break
            }
        }
    }

    /// The PUBLISH packet for this message.
    public func packet(version: MQTTVersion, packetIdentifier: UInt16?) -> MQTTPublish {
        var properties: [MQTTProperty] = []
        if version == .v5 {
            if payloadIsUTF8 { properties.append(.payloadFormatIndicator(1)) }
            if let messageExpiryInterval { properties.append(.messageExpiryInterval(messageExpiryInterval)) }
            if let contentType, !contentType.isEmpty { properties.append(.contentType(contentType)) }
            if let responseTopic, !responseTopic.isEmpty { properties.append(.responseTopic(responseTopic)) }
            if let correlationData, !correlationData.isEmpty { properties.append(.correlationData(correlationData)) }
            properties += userProperties.map { .userProperty(key: $0.key, value: $0.value) }
        }
        return MQTTPublish(topic: topic, payload: payload, qos: qos, retain: retain,
                           packetIdentifier: qos == .atMostOnce ? nil : packetIdentifier, properties: properties)
    }

    /// Why the broker would refuse this topic, or nil when it is fine to publish to.
    public var topicProblem: String? {
        if topic.isEmpty { return "Enter a topic." }
        if topic.contains("+") || topic.contains("#") { return "Wildcards (+ and #) are for subscribing, not publishing." }
        if topic.utf8.count > 65_535 { return "The topic is longer than MQTT allows." }
        return nil
    }
}

/// What happened to one published message.
public struct MQTTPublishOutcome: Equatable, Sendable {
    public var topic: String
    public var qos: MQTTQoS
    public var packetIdentifier: UInt16?
    /// 0 when the broker accepted it (or for QoS 0, where there is no answer). 0x80 and up is a refusal.
    public var reasonCode: UInt8

    public var accepted: Bool { reasonCode < 0x80 }
}

public enum MQTTPublisherError: Error, Equatable, Sendable, CustomStringConvertible {
    case connectionRefused(reasonCode: UInt8, version: MQTTVersion)
    case timedOut(waitingFor: String)
    case connectionClosed
    case disconnectedByBroker(reasonCode: UInt8)
    case unexpectedPacket(MQTTPacketType)
    case invalidMessage(String)

    public var description: String {
        switch self {
        case .connectionRefused(let code, let version):
            "The broker refused the connection: \(MQTTPublisherError.connackReason(code, version: version))"
        case .timedOut(let what): "Timed out waiting for \(what)"
        case .connectionClosed: "The broker closed the connection"
        case .disconnectedByBroker(let code): "The broker disconnected (reason 0x\(String(code, radix: 16, uppercase: true)))"
        case .unexpectedPacket(let type): "The broker sent an unexpected \(type) packet"
        case .invalidMessage(let reason): reason
        }
    }

    static func connackReason(_ code: UInt8, version: MQTTVersion) -> String {
        if version != .v5 {
            switch code {
            case 1: return "unacceptable protocol version"
            case 2: return "client identifier rejected"
            case 3: return "server unavailable"
            case 4: return "bad user name or password"
            case 5: return "not authorized"
            default: return "code \(code)"
            }
        }
        switch code {
        case 0x84: return "unsupported protocol version"
        case 0x85: return "client identifier not valid"
        case 0x86: return "bad user name or password"
        case 0x87: return "not authorized"
        case 0x88: return "server unavailable"
        case 0x89: return "server busy"
        case 0x8A: return "banned"
        default: return "reason 0x\(String(code, radix: 16, uppercase: true))"
        }
    }
}

/// Connects to a broker as a client and publishes messages: the composer's Send and replay of
/// captured messages. Both directions go through the capture sink, so what it sends shows up in
/// the timeline like any other MQTT traffic.
public final class MQTTPublisher: Sendable {
    private let group: EventLoopGroup
    private let sink: CaptureSink?
    private let timeout: TimeAmount

    public init(group: EventLoopGroup, sink: CaptureSink?, timeout: TimeAmount = .seconds(10)) {
        self.group = group
        self.sink = sink
        self.timeout = timeout
    }

    /// Opens one connection, publishes `messages` in order with `interval` between them, waits for
    /// each acknowledgement QoS asks for, then disconnects.
    /// - Parameter progress: called after each message with how many are done.
    @discardableResult
    public func publish(_ messages: [MQTTOutgoingMessage], to target: MQTTBrokerTarget, interval: Duration = .zero,
                        progress: (@Sendable (Int) -> Void)? = nil) async throws -> [MQTTPublishOutcome] {
        for message in messages {
            if let problem = message.topicProblem { throw MQTTPublisherError.invalidMessage(problem) }
        }
        let connection = try await MQTTClientConnection.open(target: target, group: group, sink: sink, timeout: timeout)
        do {
            let outcomes = try await run(messages, on: connection, version: target.version, interval: interval, progress: progress)
            try? await connection.send(.disconnect(MQTTReasonPacket()))
            await connection.close()
            return outcomes
        } catch {
            await connection.close()
            throw error
        }
    }

    private func run(_ messages: [MQTTOutgoingMessage], on connection: MQTTClientConnection, version: MQTTVersion,
                     interval: Duration, progress: (@Sendable (Int) -> Void)?) async throws -> [MQTTPublishOutcome] {
        var outcomes: [MQTTPublishOutcome] = []
        var nextIdentifier: UInt16 = 1
        for (index, message) in messages.enumerated() {
            if index > 0, interval > .zero { try await Task.sleep(for: interval) }
            try Task.checkCancellation()
            let identifier = nextIdentifier
            nextIdentifier = nextIdentifier == .max ? 1 : nextIdentifier + 1
            let publish = message.packet(version: version, packetIdentifier: identifier)
            try await connection.send(.publish(publish))
            var outcome = MQTTPublishOutcome(topic: message.topic, qos: message.qos, packetIdentifier: publish.packetIdentifier, reasonCode: 0)
            switch message.qos {
            case .atMostOnce:
                break
            case .atLeastOnce:
                outcome.reasonCode = try await connection.awaitAcknowledgement(.puback, identifier: identifier).reasonCode
            case .exactlyOnce:
                let received = try await connection.awaitAcknowledgement(.pubrec, identifier: identifier)
                outcome.reasonCode = received.reasonCode
                if received.reasonCode < 0x80 {
                    try await connection.send(.pubrel(MQTTPublishAcknowledgement(packetIdentifier: identifier)))
                    let completed = try await connection.awaitAcknowledgement(.pubcomp, identifier: identifier)
                    outcome.reasonCode = max(outcome.reasonCode, completed.reasonCode)
                }
            }
            outcomes.append(outcome)
            progress?(index + 1)
        }
        return outcomes
    }
}

/// One client connection: writes encoded packets and hands back decoded ones, both through an `MQTTTap`.
final class MQTTClientConnection: @unchecked Sendable {
    private let channel: Channel
    private let handler: NIOLoopBound<MQTTClientHandler>
    private let version: MQTTVersion
    private let timeout: TimeAmount

    private init(channel: Channel, handler: NIOLoopBound<MQTTClientHandler>, version: MQTTVersion, timeout: TimeAmount) {
        self.channel = channel
        self.handler = handler
        self.version = version
        self.timeout = timeout
    }

    static func open(target: MQTTBrokerTarget, group: EventLoopGroup, sink: CaptureSink?, timeout: TimeAmount) async throws -> MQTTClientConnection {
        var sslContext: NIOSSLContext?
        if target.useTLS {
            var configuration = TLSConfiguration.makeClientConfiguration()
            if !target.verifyCertificate { configuration.certificateVerification = .none }
            sslContext = try NIOSSLContext(configuration: configuration)
        }
        let host = target.host
        let version = target.version
        let label = target.label
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        let sni = ipAddressBytes(host) == nil ? host : nil
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: sni))
                    }
                    let tap = sink.map { MQTTTap(sink: $0, broker: label) }
                    try channel.pipeline.syncOperations.addHandler(MQTTClientHandler(version: version, tap: tap))
                }
            }
            .connect(host: target.host, port: target.port)
            .get()
        let handler = try await channel.eventLoop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: MQTTClientHandler.self), eventLoop: channel.eventLoop)
        }.get()
        let connection = MQTTClientConnection(channel: channel, handler: handler, version: version, timeout: timeout)
        do {
            let username: String? = target.username?.isEmpty == false ? target.username : nil
            let password: [UInt8]? = target.password?.isEmpty == false ? Array(target.password!.utf8) : nil
            let connect = MQTTConnect(version: version, clientIdentifier: target.effectiveClientIdentifier, cleanStart: true,
                                      keepAlive: 0, username: username, password: password)
            try await connection.send(.connect(connect))
            guard case .connack(let ack) = try await connection.next(waitingFor: "CONNACK") else {
                throw MQTTPublisherError.unexpectedPacket(.connack)
            }
            guard ack.reasonCode == 0 else {
                throw MQTTPublisherError.connectionRefused(reasonCode: ack.reasonCode, version: version)
            }
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    func send(_ packet: MQTTPacket) async throws {
        let bytes = try MQTTPacketEncoder.encode(packet, version: version)
        let handler = self.handler
        let channel = self.channel
        try await channel.eventLoop.flatSubmit {
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            handler.value.tap?.receive(buffer, from: .clientToBroker)
            return channel.writeAndFlush(buffer)
        }.get()
    }

    /// The next packet from the broker. A broker DISCONNECT becomes an error.
    func next(waitingFor what: String) async throws -> MQTTPacket {
        let handler = self.handler
        let timeout = self.timeout
        let loop = channel.eventLoop
        let packet = try await loop.flatSubmit {
            handler.value.next(on: loop, timeout: timeout, waitingFor: what)
        }.get()
        if case .disconnect(let reason) = packet { throw MQTTPublisherError.disconnectedByBroker(reasonCode: reason.reasonCode) }
        return packet
    }

    /// Waits for the acknowledgement of `type` for `identifier`, skipping anything unrelated (PINGRESP, say).
    func awaitAcknowledgement(_ type: MQTTPacketType, identifier: UInt16) async throws -> MQTTPublishAcknowledgement {
        while true {
            let packet = try await next(waitingFor: "\(type)".uppercased())
            switch packet {
            case .puback(let ack) where type == .puback && ack.packetIdentifier == identifier: return ack
            case .pubrec(let ack) where type == .pubrec && ack.packetIdentifier == identifier: return ack
            case .pubcomp(let ack) where type == .pubcomp && ack.packetIdentifier == identifier: return ack
            default: continue
            }
        }
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Decodes broker → client bytes into packets and queues them for `next`. Confined to the channel's event loop.
final class MQTTClientHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    let tap: MQTTTap?
    private var decoder: MQTTStreamDecoder
    private var queue: [MQTTPacket] = []
    private var waiter: EventLoopPromise<MQTTPacket>?
    private var failure: Error?

    init(version: MQTTVersion, tap: MQTTTap?) {
        self.tap = tap
        decoder = MQTTStreamDecoder(version: version)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        tap?.receive(buffer, from: .brokerToClient)
        do {
            for frame in try decoder.feed(buffer.readableBytesView) { deliver(frame.packet) }
        } catch {
            fail(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(MQTTPublisherError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func next(on loop: EventLoop, timeout: TimeAmount, waitingFor what: String) -> EventLoopFuture<MQTTPacket> {
        if !queue.isEmpty { return loop.makeSucceededFuture(queue.removeFirst()) }
        if let failure { return loop.makeFailedFuture(failure) }
        let promise = loop.makePromise(of: MQTTPacket.self)
        waiter = promise
        let timer = loop.scheduleTask(in: timeout) { [weak self] in
            guard let self, let waiter = self.waiter else { return }
            self.waiter = nil
            waiter.fail(MQTTPublisherError.timedOut(waitingFor: what))
        }
        promise.futureResult.whenComplete { _ in timer.cancel() }
        return promise.futureResult
    }

    private func deliver(_ packet: MQTTPacket) {
        if let waiter {
            self.waiter = nil
            waiter.succeed(packet)
        } else {
            queue.append(packet)
        }
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        if let waiter {
            self.waiter = nil
            waiter.fail(error)
        }
    }
}
