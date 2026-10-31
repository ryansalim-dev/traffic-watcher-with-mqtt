import NIOCore

/// Relays raw bytes between two channels with backpressure. One instance sits in each
/// channel's pipeline; the two must share an event loop.
final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Called with every chunk read on this handler's channel, before it is relayed.
    private let onRead: (ByteBuffer) -> Void
    private let onClose: () -> Void

    private init(onRead: @escaping (ByteBuffer) -> Void, onClose: @escaping () -> Void) {
        self.onRead = onRead
        self.onClose = onClose
    }

    static func pair(
        onReadA: @escaping (ByteBuffer) -> Void = { _ in },
        onReadB: @escaping (ByteBuffer) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) -> (GlueHandler, GlueHandler) {
        var closed = false
        let closeOnce = {
            guard !closed else { return }
            closed = true
            onClose()
        }
        let a = GlueHandler(onRead: onReadA, onClose: closeOnce)
        let b = GlueHandler(onRead: onReadB, onClose: closeOnce)
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onRead(buffer)
        partner?.partnerWrite(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        partner?.partnerClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.isWritable ?? false {
            context.read()
        } else {
            pendingRead = true
        }
    }

    // MARK: Partner calls

    private var isWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerWrite(_ buffer: ByteBuffer) {
        context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    /// Closes after everything already written has gone out.
    private func partnerClose() {
        guard let context else { return }
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(capacity: 0))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}
