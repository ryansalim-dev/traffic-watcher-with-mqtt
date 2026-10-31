import NIOCore
import NIOHTTP1
import NIOPosix

struct UpstreamResponse {
    var head: HTTPResponseHead
    var body: ByteBuffer
}

enum UpstreamError: Error, CustomStringConvertible {
    case connectionClosedEarly
    case bodyTooLarge(Int)

    var description: String {
        switch self {
        case .connectionClosedEarly: "Upstream closed the connection before the response finished"
        case .bodyTooLarge(let limit): "Response body exceeded \(limit) bytes"
        }
    }
}

/// Sends one request on a fresh upstream connection and collects the whole response.
enum UpstreamHTTPClient {
    static func send(
        head: HTTPRequestHead,
        body: ByteBuffer,
        host: String,
        port: Int,
        on eventLoop: EventLoop,
        maximumBodySize: Int
    ) -> EventLoopFuture<UpstreamResponse> {
        let promise = eventLoop.makePromise(of: UpstreamResponse.self)
        ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(ResponseCollector(promise: promise, maximumBodySize: maximumBodySize))
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    promise.fail(error)
                case .success(let channel):
                    channel.write(HTTPClientRequestPart.head(head), promise: nil)
                    if body.readableBytes > 0 {
                        channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    }
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
                }
            }
        return promise.futureResult
    }
}

private final class ResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<UpstreamResponse>
    private let maximumBodySize: Int
    private var head: HTTPResponseHead?
    private var body: ByteBuffer?
    private var done = false

    init(promise: EventLoopPromise<UpstreamResponse>, maximumBodySize: Int) {
        self.promise = promise
        self.maximumBodySize = maximumBodySize
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
            if (body?.readableBytes ?? 0) > maximumBodySize {
                finish(.failure(UpstreamError.bodyTooLarge(maximumBodySize)))
                context.close(promise: nil)
            }
        case .end:
            if let head, let body {
                finish(.success(UpstreamResponse(head: head, body: body)))
            } else {
                finish(.failure(UpstreamError.connectionClosedEarly))
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(UpstreamError.connectionClosedEarly))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    private func finish(_ result: Result<UpstreamResponse, Error>) {
        guard !done else { return }
        done = true
        promise.completeWith(result)
    }
}
