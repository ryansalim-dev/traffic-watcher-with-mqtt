import Foundation
import MQTTCore
import NIOCore
import NIOPosix
import NIOSSL
import TLSMitm

/// Listens locally and relays every connection to one MQTT broker, decoding both directions.
///
/// Raw MQTT clients ignore HTTP proxy settings, so the app under test points at this
/// forwarder (for example `localhost:18830`) instead of the broker.
public final class MQTTForwarder: @unchecked Sendable {
    /// MQTT over TLS (usually port 8883): the forwarder terminates TLS from the app with a leaf from
    /// `interceptor` and opens its own TLS connection to the broker.
    public struct TLS: Sendable {
        public var interceptor: TLSInterceptor
        /// How the broker's certificate is verified.
        public var upstream: TLSConfiguration
        /// Names the presented leaf is valid for, besides the broker host itself. The app usually
        /// connects to `localhost` or `127.0.0.1`, so both are included by default.
        public var additionalHostnames: [String]

        public init(
            interceptor: TLSInterceptor,
            upstream: TLSConfiguration = .makeClientConfiguration(),
            additionalHostnames: [String] = ["localhost", "127.0.0.1"]
        ) {
            self.interceptor = interceptor
            self.upstream = upstream
            self.additionalHostnames = additionalHostnames
        }
    }

    private let group: EventLoopGroup
    private let sink: CaptureSink
    private let brokerHost: String
    private let brokerPort: Int
    private let tls: TLS?
    private var channel: Channel?

    public init(group: EventLoopGroup, sink: CaptureSink, brokerHost: String, brokerPort: Int? = nil, tls: TLS? = nil) {
        self.group = group
        self.sink = sink
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort ?? (tls == nil ? 1883 : 8883)
        self.tls = tls
    }

    /// Starts listening and returns the bound port (pass 0 to pick a free one).
    @discardableResult
    public func start(host: String = "127.0.0.1", port: Int = 0) async throws -> Int {
        let sink = self.sink
        let brokerHost = self.brokerHost
        let brokerPort = self.brokerPort
        var serverTLS: NIOSSLContext?
        var clientTLS: NIOSSLContext?
        if let tls {
            serverTLS = try tls.interceptor.serverContext(forHosts: [brokerHost] + tls.additionalHostnames.filter { $0 != brokerHost })
            clientTLS = try NIOSSLContext(configuration: tls.upstream)
        }
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Hold client reads until the broker connection and glue exist.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { client in
                ClientBootstrap(group: client.eventLoop)
                    .connectTimeout(.seconds(15))
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelInitializer { broker in
                        broker.eventLoop.makeCompletedFuture {
                            if let clientTLS {
                                let sni = ipAddressBytes(brokerHost) == nil ? brokerHost : nil
                                try broker.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: clientTLS, serverHostname: sni))
                            }
                        }
                    }
                    .connect(host: brokerHost, port: brokerPort)
                    .flatMapThrowing { broker in
                        let tap = MQTTTap(sink: sink, broker: "\(brokerHost):\(brokerPort)")
                        let (clientSide, brokerSide) = GlueHandler.pair(
                            onReadA: { tap.receive($0, from: .clientToBroker) },
                            onReadB: { tap.receive($0, from: .brokerToClient) },
                            onClose: { broker.close(promise: nil) }
                        )
                        if let serverTLS {
                            try client.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverTLS))
                        }
                        try client.pipeline.syncOperations.addHandler(clientSide)
                        try broker.pipeline.syncOperations.addHandler(brokerSide)
                        broker.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                        client.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                    }
            }
            .bind(host: host, port: port)
            .get()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() async throws {
        try await channel?.close().get()
        channel = nil
    }
}

/// Feeds relayed bytes through an `MQTTSession`. Confined to one event loop.
final class MQTTTap {
    let connectionID = UUID()
    private let sink: CaptureSink
    private let broker: String
    private var session = MQTTSession()
    private var failed = false

    init(sink: CaptureSink, broker: String) {
        self.sink = sink
        self.broker = broker
    }

    func receive(_ buffer: ByteBuffer, from direction: MQTTDirection) {
        guard !failed else { return }
        do {
            let now = Date()
            for event in try session.receive(buffer.readableBytesView, from: direction) {
                sink.record(.mqtt(MQTTCaptureEvent(connectionID: connectionID, timestamp: now, broker: broker, event: event)))
            }
        } catch {
            failed = true
            sink.record(.mqttDecodingFailed(connectionID: connectionID, reason: String(describing: error)))
        }
    }
}
