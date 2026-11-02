import Dispatch
import NIOCore

/// Relays raw bytes between two channels with backpressure. One instance sits in each
/// channel's pipeline; the two must share an event loop.
final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Lets a pair run its transforms on a serial queue instead of the event loop, for transforms
    /// that may block (user scripts can take up to their time limit). The event loop is shared by
    /// many connections, so a slow transform there would stall all of them.
    ///
    /// Both directions share the queue, so the transforms (and whatever state they share) still
    /// run one at a time and in the order the bytes were read. Results come back to the event loop
    /// in that same order. While a chunk is on the queue, later chunks follow it there.
    final class Offload: @unchecked Sendable {
        /// Asked before each chunk; false keeps the transform on the event loop when nothing is queued.
        let isNeeded: () -> Bool
        let queue: DispatchQueue
        /// Chunks handed to the queue whose result hasn't been written yet. Event-loop confined.
        fileprivate var inFlight = 0
        /// Reads stop while this many chunks are queued, so a slow script holds the sender back.
        fileprivate let limit: Int

        init(limit: Int = 8, isNeeded: @escaping () -> Bool) {
            self.isNeeded = isNeeded
            self.limit = limit
            queue = DispatchQueue(label: "app.wiretide.glue", qos: .userInitiated)
        }
    }

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Called with every chunk read on this handler's channel, before it is relayed.
    private let onRead: (ByteBuffer) -> Void
    /// Turns each chunk read into what is written to the partner; nil relays it as it is.
    private let transform: ((ByteBuffer) -> ByteBuffer)?
    private let offload: Offload?
    private let onClose: () -> Void

    private init(onRead: @escaping (ByteBuffer) -> Void, transform: ((ByteBuffer) -> ByteBuffer)?, offload: Offload?,
                 onClose: @escaping () -> Void) {
        self.onRead = onRead
        self.transform = transform
        self.offload = offload
        self.onClose = onClose
    }

    static func pair(
        onReadA: @escaping (ByteBuffer) -> Void = { _ in },
        onReadB: @escaping (ByteBuffer) -> Void = { _ in },
        transformA: ((ByteBuffer) -> ByteBuffer)? = nil,
        transformB: ((ByteBuffer) -> ByteBuffer)? = nil,
        offload: Offload? = nil,
        onClose: @escaping () -> Void = {}
    ) -> (GlueHandler, GlueHandler) {
        var closed = false
        let closeOnce = {
            guard !closed else { return }
            closed = true
            onClose()
        }
        let a = GlueHandler(onRead: onReadA, transform: transformA, offload: offload, onClose: closeOnce)
        let b = GlueHandler(onRead: onReadB, transform: transformB, offload: offload, onClose: closeOnce)
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
        guard let transform else {
            partner?.partnerWrite(buffer)
            return
        }
        if let offload, offload.inFlight > 0 || offload.isNeeded() {
            transformOffLoop(buffer, transform: transform, offload: offload, loop: context.eventLoop)
            return
        }
        let output = transform(buffer)
        if output.readableBytes > 0 { partner?.partnerWrite(output) }
    }

    /// Runs `transform` on the offload queue and writes its result once it comes back.
    private func transformOffLoop(_ buffer: ByteBuffer, transform: @escaping (ByteBuffer) -> ByteBuffer,
                                  offload: Offload, loop: EventLoop) {
        offload.inFlight += 1
        // A copy the job owns outright: NIO reuses the storage of the buffers it reads into.
        let job = OffloadJob(handler: self, transform: transform, input: ByteBuffer(bytes: buffer.readableBytesView))
        offload.queue.async {
            job.run()
            loop.execute { job.finish(offload) }
        }
    }

    /// Runs `body` on the event loop after every chunk already handed to the offload queue has been written.
    private func afterQueuedOutput(_ body: @escaping () -> Void) {
        guard let offload, offload.inFlight > 0, let loop = context?.eventLoop else { return body() }
        let job = OffloadJob(handler: self, transform: nil, input: nil, then: body)
        offload.queue.async { loop.execute { job.finish(nil) } }
    }

    /// Back on the event loop with a chunk's result.
    fileprivate func finished(_ output: ByteBuffer?, offload: Offload) {
        offload.inFlight -= 1
        if let output, output.readableBytes > 0 {
            partner?.partnerWrite(output)
            partner?.partnerFlush()
        }
        if offload.inFlight < offload.limit {
            resumeReading()
            partner?.resumeReading()
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        let partner = self.partner
        afterQueuedOutput { partner?.partnerClose() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.resumeReading()
        }
    }

    func read(context: ChannelHandlerContext) {
        if canRead {
            context.read()
        } else {
            pendingRead = true
        }
    }

    // MARK: Partner calls

    private var isWritable: Bool { context?.channel.isWritable ?? false }

    /// The partner can take more, and the offload queue isn't backed up.
    private var canRead: Bool {
        (partner?.isWritable ?? false) && (offload.map { $0.inFlight < $0.limit } ?? true)
    }

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

    private func resumeReading() {
        if pendingRead, canRead {
            pendingRead = false
            context?.read()
        }
    }
}

/// One chunk on its way through the offload queue. The queue only calls `transform`, whose state
/// nothing else touches while chunks are queued; the handler is used back on the event loop.
private final class OffloadJob: @unchecked Sendable {
    private let handler: GlueHandler
    private let transform: ((ByteBuffer) -> ByteBuffer)?
    private let input: ByteBuffer?
    private let then: (() -> Void)?
    private var output: ByteBuffer?

    init(handler: GlueHandler, transform: ((ByteBuffer) -> ByteBuffer)?, input: ByteBuffer?, then: (() -> Void)? = nil) {
        self.handler = handler
        self.transform = transform
        self.input = input
        self.then = then
    }

    /// On the queue.
    func run() {
        if let transform, let input { output = transform(input) }
    }

    /// On the event loop.
    func finish(_ offload: GlueHandler.Offload?) {
        if let offload { handler.finished(output, offload: offload) }
        then?()
    }
}
