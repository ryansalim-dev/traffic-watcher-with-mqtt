/// One decoded control packet along with the exact bytes it came from (for hex views and export).
public struct MQTTFrame: Equatable, Sendable {
    public var packet: MQTTPacket
    public var rawBytes: [UInt8]
}

/// Splits an arbitrary chunked byte stream (one direction of a TCP or WebSocket connection)
/// into MQTT control packets.
public struct MQTTStreamDecoder: Sendable {
    /// Upper bound for a single packet, guarding against garbage streams. MQTT's own limit is 256 MB.
    public static let defaultMaximumPacketSize = 268_435_455

    public var version: MQTTVersion
    public let maximumPacketSize: Int
    private var buffer: [UInt8] = []

    public init(version: MQTTVersion = .v3_1_1, maximumPacketSize: Int = defaultMaximumPacketSize) {
        self.version = version
        self.maximumPacketSize = maximumPacketSize
    }

    /// Bytes received but not yet forming a complete packet.
    public var bufferedByteCount: Int { buffer.count }

    /// Appends `bytes` and returns every packet that is now complete.
    /// A CONNECT packet switches this decoder to the protocol version it declares.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) throws -> [MQTTFrame] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [MQTTFrame] = []
        var consumed = 0
        defer { buffer.removeFirst(consumed) }

        while let packetLength = try nextPacketLength(from: consumed) {
            let raw = Array(buffer[consumed..<(consumed + packetLength)])
            let packet = try MQTTPacketDecoder.decode(raw, version: version)
            if case .connect(let connect) = packet { version = connect.version }
            frames.append(MQTTFrame(packet: packet, rawBytes: raw))
            consumed += packetLength
        }
        return frames
    }

    /// Total length of the packet starting at `start`, or nil if it has not fully arrived.
    private func nextPacketLength(from start: Int) throws -> Int? {
        let available = buffer.count - start
        guard available >= 2 else { return nil }
        var remainingLength = 0
        var multiplier = 1
        for offset in 1...4 {
            guard offset < available else { return nil }
            let byte = buffer[start + offset]
            remainingLength += Int(byte & 0x7F) * multiplier
            if byte & 0x80 == 0 {
                let total = 1 + offset + remainingLength
                guard total <= maximumPacketSize else { throw MQTTDecodingError.packetTooLarge(total) }
                return available >= total ? total : nil
            }
            multiplier *= 128
        }
        throw MQTTDecodingError.malformedRemainingLength
    }
}
