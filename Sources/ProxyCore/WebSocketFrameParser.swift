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

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) throws -> [Message] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var messages: [Message] = []
        var offset = 0
        defer { buffer.removeFirst(offset) }

        while let frame = try nextFrame(at: offset) {
            offset += frame.length
            if let message = try assemble(fin: frame.fin, opcode: frame.opcode, payload: frame.payload) {
                messages.append(message)
            }
        }
        return messages
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
