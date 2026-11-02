import NIOCore
import NIOPosix
import NIOTLS
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Resolves a host with getaddrinfo on NIO's thread pool, like NIO's default resolver, and notes when the
/// answer arrived so the DNS phase can be shown separately from connecting.
final class TimingResolver: Resolver, @unchecked Sendable {
    private let eventLoop: EventLoop
    private let clock: PhaseClock
    private var lookup: EventLoopFuture<[SocketAddress]>?

    init(eventLoop: EventLoop, clock: PhaseClock) {
        self.eventLoop = eventLoop
        self.clock = clock
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        addresses(host: host, port: port).map { $0.filter { $0.protocol == .inet } }
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        addresses(host: host, port: port).map { $0.filter { $0.protocol == .inet6 } }
    }

    func cancelQueries() {}

    /// One lookup answers both the A and the AAAA query.
    private func addresses(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        if let lookup { return lookup }
        let clock = self.clock
        let future = NIOThreadPool.singleton.runIfActive(eventLoop: eventLoop) {
            try Self.resolve(host: host, port: port)
        }
        future.whenComplete { _ in
            if clock.resolved == nil { clock.resolved = .now() }
        }
        lookup = future
        return future
    }

    struct LookupFailed: Error, CustomStringConvertible {
        var host: String
        var code: Int32
        var description: String { "Couldn't resolve \(host) (getaddrinfo error \(code))" }
    }

    static func resolve(host: String, port: Int) throws -> [SocketAddress] {
        var hints = addrinfo()
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_protocol = Int32(IPPROTO_TCP)
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, String(port), &hints, &info)
        guard result == 0, let first = info else { throw LookupFailed(host: host, code: result) }
        defer { freeaddrinfo(first) }

        var addresses: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch entry.pointee.ai_family {
                case AF_INET:
                    let sin = UnsafeRawPointer(address).load(as: sockaddr_in.self)
                    addresses.append(SocketAddress(sin, host: host))
                case AF_INET6:
                    let sin6 = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
                    addresses.append(SocketAddress(sin6, host: host))
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}

/// Notes when the connection opened and when its TLS handshake finished.
final class PhaseRecorder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private let clock: PhaseClock

    init(clock: PhaseClock) {
        self.clock = clock
    }

    func channelActive(context: ChannelHandlerContext) {
        if clock.connected == nil { clock.connected = .now() }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls, clock.secured == nil {
            clock.secured = .now()
        }
        context.fireUserInboundEventTriggered(event)
    }
}
