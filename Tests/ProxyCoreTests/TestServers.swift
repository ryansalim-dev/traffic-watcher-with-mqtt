import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

/// Raw TCP client that records everything it receives.
final class RawClient: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [UInt8] = []
    private var closed = false
    let channel: Channel

    private init(channel: Channel) { self.channel = channel }

    static func connect(port: Int, group: EventLoopGroup) async throws -> RawClient {
        let box = Box()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Recorder(box: box))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        let client = RawClient(channel: channel)
        box.client = client
        return client
    }

    func send(_ bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    func send(_ text: String) async throws { try await send(Array(text.utf8)) }

    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return received }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    fileprivate func append(_ buffer: ByteBuffer) {
        lock.lock(); defer { lock.unlock() }
        received += buffer.readableBytesView
    }

    fileprivate func markClosed() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }

    final class Box: @unchecked Sendable { weak var client: RawClient? }

    private final class Recorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let box: Box
        var early: [ByteBuffer] = []
        init(box: Box) { self.box = box }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            if let client = box.client {
                early.forEach(client.append); early = []
                client.append(buffer)
            } else {
                early.append(buffer)
            }
        }
        func channelInactive(context: ChannelHandlerContext) { box.client?.markClosed() }
    }
}

/// Polls `condition` until it holds or the timeout passes.
func eventually(timeout: TimeInterval = 5, _ message: String = "", _ condition: () -> Bool,
                file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

/// Replies to every request with its method and path, plus an `X-Upstream` header.
final class UpstreamHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head; body = ""
        case .body(let chunk): body += String(buffer: chunk)
        case .end:
            guard let head else { return }
            let text = "\(head.method.rawValue) \(head.uri) host=\(head.headers["Host"].first ?? "") body=\(body)"
            var response = HTTPResponseHead(version: .http1_1, status: .created)
            response.headers.add(name: "X-Upstream", value: "1")
            response.headers.add(name: "Content-Length", value: String(text.utf8.count))
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// Writes back every byte it reads.
final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Answers any MQTT CONNECT with a fixed CONNACK and any PINGREQ with PINGRESP.
final class FakeBrokerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return }
        switch first >> 4 {
        case 1: context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [0x20, 0x02, 0x00, 0x00])), promise: nil)
        case 12: context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [0xD0, 0x00])), promise: nil)
        default: break
        }
    }
}

func startServer(group: EventLoopGroup, _ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
    try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer(initializer)
        .bind(host: "127.0.0.1", port: 0)
        .get()
}
