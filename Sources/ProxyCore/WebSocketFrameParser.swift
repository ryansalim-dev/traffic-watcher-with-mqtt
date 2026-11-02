/// RFC 6455 frame opcodes.
public enum WebSocketOpcode: UInt8, Sendable, Codable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool { rawValue & 0x8 != 0 }
}

public enum WebSocketParsingError: Error, Equatable, Sendable {
    case reservedBitsSet
    case invalidOpcode(UInt8)
    case fragmentedControlFrame
    case unexpectedContinuation
    case messageTooLarge(Int)
}

/// Reassembles WebSocket messages from one direction of a connection. Payloads are unmasked,
/// fragmented messages are joined, and control frames are returned as they arrive.
///
/// Compression extensions are not supported: the proxy strips `Sec-WebSocket-Extensions` from the
/// handshake so frames stay readable, and frames with RSV bits set raise `reservedBitsSet`.
struct WebSocketFrameParser {
    struct Message: Equatable {
        var opcode: WebSocketOpcode
        var payload: [UInt8]
    }

    let maximumMessageSize: Int
    private var buffer: [UInt8] = []
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments: [UInt8] = []

    init(maximumMessageSize: Int = 16 * 1024 * 1024) {
        self.maximumMessageSize = maximumMessageSize
    }

    /// One frame as it crossed the wire: its unmasked payload and its exact bytes.
    struct Frame: Equatable {
        var fin: Bool
        var opcode: WebSocketOpcode
        var payload: [UInt8]
        var raw: [UInt8]
    }

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) throws -> [Message] where Bytes.Element == UInt8 {
        let (frames, error) = self.frames(bytes)
        var messages: [Message] = []
        for frame in frames {
            if let message = try assemble(frame) { messages.append(message) }
        }
        if let error { throw error }
        return messages
    }

    /// Splits the stream into complete frames without joining fragments. Frames before a parsing
    /// error are still returned; the bytes from the bad frame on stay buffered (see `takeBuffered`).
    mutating func frames<Bytes: Sequence>(_ bytes: Bytes) -> (frames: [Frame], error: Error?) where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        var offset = 0
        defer { buffer.removeFirst(offset) }
        do {
            while let frame = try nextFrame(at: offset) {
                frames.append(Frame(fin: frame.fin, opcode: frame.opcode, payload: frame.payload,
                                    raw: Array(buffer[offset..<(offset + frame.length)])))
                offset += frame.length
            }
        } catch {
            return (frames, error)
        }
        return (frames, nil)
    }

    /// Bytes received but not yet part of a complete frame, removed from the parser.
    mutating func takeBuffered() -> [UInt8] {
        defer { buffer = [] }
        return buffer
    }

    /// Joins fragments; returns a message once one is complete (control frames at once).
    mutating func assemble(_ frame: Frame) throws -> Message? {
        try assemble(fin: frame.fin, opcode: frame.opcode, payload: frame.payload)
    }

    private func nextFrame(at start: Int) throws -> (fin: Bool, opcode: WebSocketOpcode, payload: [UInt8], length: Int)? {
        let available = buffer.count - start
        guard available >= 2 else { return nil }
        let first = buffer[start], second = buffer[start + 1]
        guard first & 0x70 == 0 else { throw WebSocketParsingError.reservedBitsSet }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw WebSocketParsingError.invalidOpcode(first & 0x0F)
        }
        let fin = first & 0x80 != 0
        if opcode.isControl && !fin { throw WebSocketParsingError.fragmentedControlFrame }

        let masked = second & 0x80 != 0
        var header = 2
        var payloadLength = UInt64(second & 0x7F)
        if payloadLength == 126 {
            guard available >= 4 else { return nil }
            payloadLength = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3])
            header = 4
        } else if payloadLength == 127 {
            guard available >= 10 else { return nil }
            payloadLength = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[start + 2 + $1]) }
            header = 10
        }
        guard payloadLength <= UInt64(maximumMessageSize) else {
            throw WebSocketParsingError.messageTooLarge(maximumMessageSize)
        }
        let maskStart = start + header
        if masked { header += 4 }
        let total = header + Int(payloadLength)
        guard available >= total else { return nil }

        var payload = Array(buffer[(start + header)..<(start + total)])
        if masked {
            let key = buffer[maskStart..<(maskStart + 4)].map { $0 }
            for index in payload.indices { payload[index] ^= key[index & 3] }
        }
        return (fin, opcode, payload, total)
    }

    private mutating func assemble(fin: Bool, opcode: WebSocketOpcode, payload: [UInt8]) throws -> Message? {
        if opcode.isControl { return Message(opcode: opcode, payload: payload) }

        if opcode == .continuation {
            guard let started = fragmentOpcode else { throw WebSocketParsingError.unexpectedContinuation }
            fragments += payload
            guard fragments.count <= maximumMessageSize else { throw WebSocketParsingError.messageTooLarge(maximumMessageSize) }
            guard fin else { return nil }
            defer { fragmentOpcode = nil; fragments = [] }
            return Message(opcode: started, payload: fragments)
        }

        guard fragmentOpcode == nil else { throw WebSocketParsingError.unexpectedContinuation }
        if fin { return Message(opcode: opcode, payload: payload) }
        fragmentOpcode = opcode
        fragments = payload
        return nil
    }
}

extension WebSocketFrameParser {
    /// Encodes one unfragmented frame. Frames from a client must be masked (RFC 6455 §5.3).
    static func encode(opcode: WebSocketOpcode, payload: [UInt8], masked: Bool) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        let maskBit: UInt8 = masked ? 0x80 : 0
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame += [maskBit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(maskBit | 127)
            frame += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        guard masked else { return frame + payload }
        let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += key
        frame.reserveCapacity(frame.count + payload.count)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ key[index & 3]) }
        return frame
    }
}
