import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import TLSMitm

/// A local HTTP forward proxy. Plain HTTP requests are captured in full. CONNECT requests are
/// decrypted and captured when a `TLSInterceptor` is configured and the host is not bypassed;
/// otherwise they become a byte-for-byte tunnel.
public final class HTTPProxyServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Requests or responses larger than this are rejected rather than buffered.
        public var maximumBodySize: Int = 50 * 1024 * 1024
        /// Enables HTTPS decryption. Nil relays every CONNECT untouched.
        public var interceptor: TLSInterceptor?
        /// How the proxy verifies real servers when it re-encrypts intercepted traffic.
        public var upstreamTLS: TLSConfiguration = .makeClientConfiguration()
        /// Pauses matching exchanges so they can be edited. Nil never pauses.
        public var breakpoints: HTTPBreakpointHandler?
        public init() {}
    }

    private let group: EventLoopGroup
    private let sink: CaptureSink
    private let configuration: Configuration
    private var channel: Channel?

    public init(group: EventLoopGroup, sink: CaptureSink, configuration: Configuration = .init()) {
        self.group = group
        self.sink = sink
        self.configuration = configuration
    }

    /// Starts listening and returns the bound port (pass 0 to pick a free one).
    @discardableResult
    public func start(host: String = "127.0.0.1", port: Int = 0) async throws -> Int {
        let shared = try ProxyContext(sink: sink, configuration: configuration)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try ProxyRequestHandler.install(on: channel.pipeline.syncOperations, shared: shared, origin: nil)
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

/// State shared by every connection of one proxy server.
final class ProxyContext: @unchecked Sendable {
    let sink: CaptureSink
    let configuration: HTTPProxyServer.Configuration
    let upstreamTLS: NIOSSLContext

    init(sink: CaptureSink, configuration: HTTPProxyServer.Configuration) throws {
        self.sink = sink
        self.configuration = configuration
        var upstream = configuration.upstreamTLS
        upstream.applicationProtocols = ["http/1.1"]
        self.upstreamTLS = try NIOSSLContext(configuration: upstream)
    }
}

/// The server behind a decrypted CONNECT tunnel.
struct InterceptedOrigin {
    var host: String
    var port: Int

    func url(for uri: String) -> String {
        let authority = ipAddressBytes(host).map { _ in host.contains(":") ? "[\(host)]" : host } ?? host
        return "https://\(authority)\(port == 443 ? "" : ":\(port)")\(uri.hasPrefix("/") ? uri : "/" + uri)"
    }
}

final class ProxyRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case receiving(head: HTTPRequestHead, body: ByteBuffer, startedAt: Date)
        case forwarding
        case connectingTunnel
        /// HTTP codecs are being removed; raw bytes that arrive meanwhile are held here.
        case switchingToTunnel(pending: [NIOAny])
        case failed
    }

    private let shared: ProxyContext
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let encoder: HTTPResponseEncoder
    /// Set when this handler serves requests decrypted from a CONNECT tunnel.
    private let origin: InterceptedOrigin?
    private var state = State.idle
    /// True once the CONNECT request's `.end` has been read; the codecs must not be swapped earlier.
    private var connectRequestEnded = false
    /// A protocol switch waiting for the CONNECT request's `.end`.
    private var switchAfterConnectEnds: (() -> Void)?
    /// Pipelined requests that arrived while one was being forwarded.
    private var queued: [NIOAny] = []

    private var sink: CaptureSink { shared.sink }
    private var configuration: HTTPProxyServer.Configuration { shared.configuration }

    private init(
        shared: ProxyContext,
        decoder: ByteToMessageHandler<HTTPRequestDecoder>,
        encoder: HTTPResponseEncoder,
        origin: InterceptedOrigin?
    ) {
        self.shared = shared
        self.decoder = decoder
        self.encoder = encoder
        self.origin = origin
    }

    /// Adds an HTTP/1 request decoder, response encoder and proxy handler to the end of `pipeline`.
    static func install(on pipeline: ChannelPipeline.SynchronousOperations, shared: ProxyContext, origin: InterceptedOrigin?) throws {
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let encoder = HTTPResponseEncoder()
        let handler = ProxyRequestHandler(shared: shared, decoder: decoder, encoder: encoder, origin: origin)
        try pipeline.addHandlers([decoder, encoder, handler])
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .switchingToTunnel(var pending):
            pending.append(data)
            state = .switchingToTunnel(pending: pending)
            return
        case .connectingTunnel:
            if case .end = unwrapInboundIn(data) {
                connectRequestEnded = true
                if let pending = switchAfterConnectEnds {
                    switchAfterConnectEnds = nil
                    pending()
                }
            }
            return
        case .failed:
            return // input after an error
        case .forwarding:
            queued.append(data)
            return
        case .idle, .receiving:
            break
        }

        switch (unwrapInboundIn(data), state) {
        case (.head(let head), .idle):
            if head.method == .CONNECT {
                guard origin == nil else {
                    respondWithError(context: context, status: .badRequest, message: "CONNECT inside a tunnel is not supported")
                    state = .failed
                    return
                }
                openTunnel(context: context, head: head)
            } else {
                state = .receiving(head: head, body: context.channel.allocator.buffer(capacity: 0), startedAt: Date())
            }
        case (.body(var chunk), .receiving(let head, var body, let startedAt)):
            body.writeBuffer(&chunk)
            if body.readableBytes > configuration.maximumBodySize {
                respondWithError(context: context, status: .payloadTooLarge, message: "Request body too large")
                state = .failed
                return
            }
            state = .receiving(head: head, body: body, startedAt: startedAt)
        case (.end, .receiving(let head, let body, let startedAt)):
            state = .forwarding
            if head.isWebSocketUpgrade {
                upgradeWebSocket(context: context, head: head, body: body, startedAt: startedAt)
            } else {
                forward(context: context, head: head, body: body, startedAt: startedAt)
            }
        default:
            respondWithError(context: context, status: .badRequest, message: "Unexpected request part")
            state = .failed
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: Plain HTTP

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer, startedAt: Date) {
        let id = UUID()
        let original = HTTPRequestDraft(
            method: head.method.rawValue,
            url: origin?.url(for: head.uri) ?? head.uri,
            headers: head.headers.map { CapturedHeader(name: $0.name, value: $0.value) },
            body: Array(body.readableBytesView)
        )
        var paused: BreakpointStages = []
        let sink = self.sink

        func record(_ request: HTTPRequestDraft, status: Int?, responseHeaders: [CapturedHeader], responseBody: [UInt8], error: String?,
                    timing: HTTPTiming? = nil) {
            sink.record(.httpExchange(HTTPExchange(
                id: id,
                startedAt: startedAt,
                duration: Date().timeIntervalSince(startedAt),
                method: request.method,
                url: request.url,
                requestHeaders: request.headers,
                requestBody: request.body,
                statusCode: status,
                responseHeaders: responseHeaders,
                responseBody: responseBody,
                error: error,
                breakpoint: paused.isEmpty ? nil : paused,
                timing: timing
            )))
        }

        let originalTarget: AbsoluteHTTPTarget
        if let origin {
            originalTarget = AbsoluteHTTPTarget(host: origin.host, port: origin.port, originForm: Self.originForm(of: head.uri))
        } else if let absolute = AbsoluteHTTPTarget(head.uri) {
            originalTarget = absolute
        } else {
            let message = head.uri.lowercased().hasPrefix("https://")
                ? "HTTPS must be sent through CONNECT"
                : "Proxy requests need an absolute http:// URL"
            record(original, status: 400, responseHeaders: [], responseBody: [], error: message)
            respondWithError(context: context, status: .badRequest, message: message, keepAlive: head.isKeepAlive)
            return
        }

        let breakpoints = configuration.breakpoints
        let stages = breakpoints?.stages(method: original.method, url: original.url) ?? []
        let loop = context.eventLoop

        let requestDecision: EventLoopFuture<BreakpointResolution<HTTPRequestDraft>>
        if stages.contains(.request), let breakpoints {
            paused.insert(.request)
            let promise = loop.makePromise(of: BreakpointResolution<HTTPRequestDraft>.self)
            promise.completeWithTask { await breakpoints.editRequest(original) }
            requestDecision = promise.futureResult
        } else {
            requestDecision = loop.makeSucceededFuture(.proceed(original))
        }

        requestDecision.whenSuccess { decision in
            guard case .proceed(let request) = decision else {
                let message = "Aborted at a breakpoint"
                record(original, status: nil, responseHeaders: [], responseBody: [], error: message)
                self.respondWithError(context: context, status: .badGateway, message: message, keepAlive: head.isKeepAlive)
                return
            }

            // An edited URL may point somewhere else entirely, including http <-> https.
            let target: AbsoluteHTTPTarget
            let useTLS: Bool
            if request.url == original.url {
                target = originalTarget
                useTLS = self.origin != nil
            } else if let parsed = AbsoluteHTTPTarget.parse(url: request.url) {
                (target, useTLS) = parsed
            } else {
                let message = "The edited URL isn't an absolute http:// or https:// URL"
                record(request, status: 400, responseHeaders: [], responseBody: [], error: message)
                self.respondWithError(context: context, status: .badRequest, message: message, keepAlive: head.isKeepAlive)
                return
            }

            var requestHeaders = HTTPHeaders(request.headers.map { ($0.name, $0.value) })
            if request.url != original.url, requestHeaders["Host"].first == originalTarget.authority || requestHeaders["Host"].first == originalTarget.host {
                requestHeaders.replaceOrAdd(name: "Host", value: target.authority)
            }
            var upstreamHead = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: target.originForm)
            upstreamHead.headers = requestHeaders.removingHopByHop()
            if !upstreamHead.headers.contains(name: "Host") {
                upstreamHead.headers.add(name: "Host", value: target.authority)
            }
            upstreamHead.headers.replaceOrAdd(name: "Connection", value: "close")
            if !request.body.isEmpty || requestHeaders.contains(name: "Content-Length") || requestHeaders.contains(name: "Transfer-Encoding") {
                upstreamHead.headers.replaceOrAdd(name: "Content-Length", value: String(request.body.count))
            }
            var upstreamBody = context.channel.allocator.buffer(capacity: request.body.count)
            upstreamBody.writeBytes(request.body)

            UpstreamHTTPClient.send(
                head: upstreamHead,
                body: upstreamBody,
                host: target.host,
                port: target.port,
                tls: useTLS ? self.shared.upstreamTLS : nil,
                on: loop,
                maximumBodySize: self.configuration.maximumBodySize
            ).whenComplete { result in
                switch result {
                case .success(let response):
                    let received = HTTPResponseDraft(
                        statusCode: Int(response.head.status.code),
                        headers: response.head.headers.map { CapturedHeader(name: $0.name, value: $0.value) },
                        body: Array(response.body.readableBytesView)
                    )
                    let responseDecision: EventLoopFuture<BreakpointResolution<HTTPResponseDraft>>
                    if stages.contains(.response), let breakpoints {
                        paused.insert(.response)
                        let promise = loop.makePromise(of: BreakpointResolution<HTTPResponseDraft>.self)
                        promise.completeWithTask { await breakpoints.editResponse(received, for: request) }
                        responseDecision = promise.futureResult
                    } else {
                        responseDecision = loop.makeSucceededFuture(.proceed(received))
                    }
                    responseDecision.whenSuccess { decision in
                        guard case .proceed(let final) = decision else {
                            let message = "Response aborted at a breakpoint"
                            record(request, status: nil, responseHeaders: [], responseBody: [], error: message)
                            self.respondWithError(context: context, status: .badGateway, message: message, keepAlive: head.isKeepAlive)
                            return
                        }
                        record(request, status: final.statusCode, responseHeaders: final.headers, responseBody: final.body, error: nil,
                               timing: response.timing)
                        var responseHead = HTTPResponseHead(version: head.version, status: HTTPResponseStatus(statusCode: final.statusCode))
                        responseHead.headers = HTTPHeaders(final.headers.map { ($0.name, $0.value) }).removingHopByHop()
                        responseHead.headers.replaceOrAdd(name: "Content-Length", value: String(final.body.count))
                        if !head.isKeepAlive { responseHead.headers.replaceOrAdd(name: "Connection", value: "close") }
                        var responseBody = context.channel.allocator.buffer(capacity: final.body.count)
                        responseBody.writeBytes(final.body)
                        self.writeResponse(context: context, head: responseHead, body: responseBody, keepAlive: head.isKeepAlive)
                    }
                case .failure(let error):
                    let message = String(describing: error)
                    record(request, status: 502, responseHeaders: [], responseBody: [], error: message)
                    self.respondWithError(context: context, status: .badGateway, message: message, keepAlive: head.isKeepAlive)
                }
            }
        }
    }

    // MARK: WebSocket

    /// Relays a WebSocket upgrade byte for byte after rewriting the request for the upstream,
    /// with a `WebSocketTap` watching both directions.
    private func upgradeWebSocket(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer, startedAt: Date) {
        let exchange = HTTPExchange(
            id: UUID(),
            startedAt: startedAt,
            duration: 0,
            method: head.method.rawValue,
            url: origin?.url(for: head.uri) ?? head.uri,
            requestHeaders: head.headers.map { CapturedHeader(name: $0.name, value: $0.value) },
            requestBody: Array(body.readableBytesView),
            statusCode: nil,
            responseHeaders: [],
            responseBody: [],
            error: nil
        )
        let target: AbsoluteHTTPTarget
        if let origin {
            target = AbsoluteHTTPTarget(host: origin.host, port: origin.port, originForm: Self.originForm(of: head.uri))
        } else if let absolute = AbsoluteHTTPTarget(head.uri) {
            target = absolute
        } else {
            var failed = exchange
            failed.statusCode = 400
            failed.error = "Proxy requests need an absolute http:// URL"
            sink.record(.httpExchange(failed))
            respondWithError(context: context, status: .badRequest, message: failed.error!)
            return
        }

        // Keep the handshake intact but drop proxy headers, and refuse compression so frames stay readable.
        var headers = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "proxy-authorization" || lower == "sec-websocket-extensions" { continue }
            headers.add(name: name, value: value)
        }
        if !headers.contains(name: "Host") { headers.add(name: "Host", value: target.authority) }
        var request = "\(head.method.rawValue) \(target.originForm) HTTP/1.1\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        var requestBuffer = context.channel.allocator.buffer(capacity: request.utf8.count + body.readableBytes)
        requestBuffer.writeString(request)
        var bodyCopy = body
        requestBuffer.writeBuffer(&bodyCopy)

        state = .connectingTunnel
        connectRequestEnded = true
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        let tls = origin == nil ? nil : shared.upstreamTLS
        let host = target.host
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        let sni = ipAddressBytes(host) == nil ? host : nil
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: sni))
                    }
                }
            }
            .connect(host: target.host, port: target.port)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    var failed = exchange
                    failed.statusCode = 502
                    failed.error = String(describing: error)
                    self.sink.record(.httpExchange(failed))
                    context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                    self.respondWithError(context: context, status: .badGateway, message: failed.error!)
                case .success(let upstream):
                    let tap = WebSocketTap(sink: self.sink, request: exchange)
                    let (clientSide, serverSide) = GlueHandler.pair(
                        onReadA: { tap.receiveFromClient($0) },
                        onReadB: { tap.receiveFromServer($0) }
                    )
                    upstream.writeAndFlush(requestBuffer, promise: nil)
                    self.switchProtocols(context: context, answerConnect: false, onFailure: { upstream.close(promise: nil) }) { pipeline in
                        try upstream.pipeline.syncOperations.addHandler(serverSide)
                        try pipeline.addHandler(clientSide)
                    }
                    upstream.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                }
            }
    }

    /// The path and query of a request target, whether origin-form or absolute.
    private static func originForm(of uri: String) -> String {
        AbsoluteHTTPTarget(uri.replacingOccurrences(of: "https://", with: "http://", options: .anchored))?.originForm ?? uri
    }

    private func writeResponse(context: ChannelHandlerContext, head: HTTPResponseHead, body: ByteBuffer, keepAlive: Bool) {
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if body.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        let written = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        guard keepAlive else {
            written.whenComplete { _ in context.close(promise: nil) }
            state = .failed
            return
        }
        state = .idle
        drainQueue(context: context)
    }

    private func drainQueue(context: ChannelHandlerContext) {
        while !queued.isEmpty {
            switch state {
            case .idle, .receiving: channelRead(context: context, data: queued.removeFirst())
            default: return
            }
        }
    }

    private func respondWithError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String, keepAlive: Bool = false) {
        var buffer = context.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        var head = HTTPResponseHead(version: .http1_1, status: status)
        head.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        head.headers.add(name: "Content-Length", value: String(buffer.readableBytes))
        if !keepAlive { head.headers.add(name: "Connection", value: "close") }
        writeResponse(context: context, head: head, body: buffer, keepAlive: keepAlive)
    }

    // MARK: CONNECT tunnels

    private func openTunnel(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let (host, port) = parseAuthority(head.uri) else {
            respondWithError(context: context, status: .badRequest, message: "CONNECT target must be host:port")
            state = .failed
            return
        }
        state = .connectingTunnel

        if let interceptor = configuration.interceptor, interceptor.shouldIntercept(host: host) {
            intercept(context: context, interceptor: interceptor, host: host, port: port)
            return
        }

        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            // Hold upstream reads until the glue is in place so server-first protocols lose nothing.
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                    self.respondWithError(context: context, status: .badGateway, message: String(describing: error))
                case .success(let upstream):
                    self.relay(context: context, upstream: upstream, host: host, port: port)
                }
            }
    }

    /// Decrypts the tunnel with a generated leaf and serves its requests with a new handler.
    private func intercept(context: ChannelHandlerContext, interceptor: TLSInterceptor, host: String, port: Int) {
        let tlsContext: NIOSSLContext
        do {
            tlsContext = try interceptor.serverContext(for: host)
        } catch {
            respondWithError(context: context, status: .badGateway, message: "Could not issue a certificate: \(error)")
            return
        }
        let shared = self.shared
        switchProtocols(context: context, onFailure: {}) { pipeline in
            try pipeline.addHandler(NIOSSLServerHandler(context: tlsContext))
            try pipeline.addHandler(TLSHandshakeReporter(sink: shared.sink, host: host, port: port))
            try ProxyRequestHandler.install(on: pipeline, shared: shared, origin: InterceptedOrigin(host: host, port: port))
        }
    }

    /// Relays the tunnel byte for byte.
    private func relay(context: ChannelHandlerContext, upstream: Channel, host: String, port: Int) {
        let info = TunnelInfo(id: UUID(), openedAt: Date(), host: host, port: port)
        sink.record(.tunnelOpened(info))
        var fromClient = 0
        var fromServer = 0
        let sink = self.sink
        let (clientSide, serverSide) = GlueHandler.pair(
            onReadA: { fromClient += $0.readableBytes },
            onReadB: { fromServer += $0.readableBytes },
            onClose: { sink.record(.tunnelClosed(id: info.id, bytesFromClient: fromClient, bytesFromServer: fromServer)) }
        )
        switchProtocols(context: context, onFailure: { upstream.close(promise: nil) }) { pipeline in
            try upstream.pipeline.syncOperations.addHandler(serverSide)
            try pipeline.addHandler(clientSide)
        }
        upstream.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
    }

    /// Answers the CONNECT with 200 (unless `answerConnect` is false), swaps the HTTP codecs for the handlers `install` adds,
    /// replays any bytes that arrived during the swap, then removes this handler.
    private func switchProtocols(
        context: ChannelHandlerContext,
        answerConnect: Bool = true,
        onFailure: @escaping () -> Void,
        install: @escaping (ChannelPipeline.SynchronousOperations) throws -> Void
    ) {
        guard connectRequestEnded else {
            switchAfterConnectEnds = { [unowned self] in
                self.switchProtocols(context: context, answerConnect: answerConnect, onFailure: onFailure, install: install)
            }
            return
        }
        if answerConnect {
            var head = HTTPResponseHead(version: .http1_1, status: .ok)
            head.headers.add(name: "Content-Length", value: "0")
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }

        state = .switchingToTunnel(pending: [])
        let pipeline = context.pipeline
        pipeline.syncOperations.removeHandler(encoder)
            .flatMap { pipeline.syncOperations.removeHandler(self.decoder) }
            .whenComplete { result in
                do {
                    try result.get()
                    try install(pipeline.syncOperations)
                } catch {
                    onFailure()
                    context.close(promise: nil)
                    return
                }
                if case .switchingToTunnel(let pending) = self.state {
                    for data in pending { context.fireChannelRead(data) }
                    if !pending.isEmpty { context.fireChannelReadComplete() }
                }
                pipeline.syncOperations.removeHandler(self, promise: nil)
                context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
            }
    }
}

/// Sits behind the TLS server handler of an intercepted tunnel and reports clients that refuse
/// the generated certificate.
final class TLSHandshakeReporter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let sink: CaptureSink
    private let host: String
    private let port: Int
    private var handshakeDone = false

    init(sink: CaptureSink, host: String, port: Int) {
        self.sink = sink
        self.host = host
        self.port = port
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { handshakeDone = true }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !handshakeDone {
            handshakeDone = true
            sink.record(.tlsInterceptionFailed(host: host, port: port, reason: String(describing: error)))
        }
        context.close(promise: nil)
    }
}

/// An absolute-form `http://` request target.
struct AbsoluteHTTPTarget: Equatable {
    var host: String
    var port: Int
    var authority: String
    var originForm: String

    init(host: String, port: Int, originForm: String) {
        self.host = host
        self.port = port
        self.authority = "\(host):\(port)"
        self.originForm = originForm
    }

    init?(_ uri: String) {
        self.init(uri, scheme: "http://", defaultPort: 80)
    }

    /// An absolute `http://` or `https://` URL, and whether it needs TLS.
    static func parse(url: String) -> (AbsoluteHTTPTarget, useTLS: Bool)? {
        if let plain = AbsoluteHTTPTarget(url, scheme: "http://", defaultPort: 80) { return (plain, false) }
        if let secure = AbsoluteHTTPTarget(url, scheme: "https://", defaultPort: 443) { return (secure, true) }
        return nil
    }

    private init?(_ uri: String, scheme prefix: String, defaultPort: Int) {
        guard uri.lowercased().hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[..<authorityEnd])
        guard let (host, port) = parseAuthority(authority, defaultPort: defaultPort) else { return nil }
        var path = String(rest[authorityEnd...])
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        if path.isEmpty || path.hasPrefix("?") { path = "/" + path }
        self.host = host
        self.port = port
        self.authority = authority
        self.originForm = path
    }
}

/// Parses `host:port`, `[v6]:port`, or a bare host when `defaultPort` is given.
func parseAuthority(_ authority: String, defaultPort: Int? = nil) -> (String, Int)? {
    var hostPart = Substring(authority)
    var portPart: Substring?
    if hostPart.hasPrefix("[") {
        guard let close = hostPart.firstIndex(of: "]") else { return nil }
        let after = hostPart[hostPart.index(after: close)...]
        if after.hasPrefix(":") { portPart = after.dropFirst() } else if !after.isEmpty { return nil }
        hostPart = hostPart[hostPart.index(after: hostPart.startIndex)..<close]
    } else if let colon = hostPart.lastIndex(of: ":") {
        portPart = hostPart[hostPart.index(after: colon)...]
        hostPart = hostPart[..<colon]
    }
    guard !hostPart.isEmpty else { return nil }
    let port: Int
    if let portPart {
        guard let parsed = Int(portPart), (1...65535).contains(parsed) else { return nil }
        port = parsed
    } else if let defaultPort {
        port = defaultPort
    } else {
        return nil
    }
    return (String(hostPart), port)
}

extension HTTPRequestHead {
    var isWebSocketUpgrade: Bool {
        method == .GET && headers["upgrade"].contains { $0.lowercased() == "websocket" }
    }
}

extension HTTPHeaders {
    private static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    /// Drops hop-by-hop headers, including any named by the Connection header.
    func removingHopByHop() -> HTTPHeaders {
        let listed = Set(self["connection"].flatMap { $0.split(separator: ",") }.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        var result = HTTPHeaders()
        for (name, value) in self where !Self.hopByHop.contains(name.lowercased()) && !listed.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }
        return result
    }
}
