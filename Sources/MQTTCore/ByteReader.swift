/// Errors raised while decoding MQTT control packets.
public enum MQTTDecodingError: Error, Equatable, Sendable {
    case malformedRemainingLength
    case malformedVariableByteInteger
    case unexpectedEndOfPacket
    case invalidPacketType(UInt8)
    case invalidUTF8String
    case unknownPropertyIdentifier(UInt8)
    case unsupportedProtocolLevel(UInt8)
    case packetTooLarge(Int)
}

/// Cursor over a fixed slice of bytes with MQTT primitive readers.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var index: Int
    private let end: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.index = start
        self.end = end ?? bytes.count
    }

    var remaining: Int { end - index }
    var isAtEnd: Bool { index >= end }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw MQTTDecodingError.unexpectedEndOfPacket }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw MQTTDecodingError.unexpectedEndOfPacket }
        defer { index += 2 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw MQTTDecodingError.unexpectedEndOfPacket }
        defer { index += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[index + $1]) }
    }

    /// MQTT Variable Byte Integer: 1 to 4 bytes, 7 bits each, little-endian groups.
    mutating func readVariableByteInteger() throws -> UInt32 {
        var value: UInt32 = 0
        var multiplier: UInt32 = 1
        for _ in 0..<4 {
            let byte = try readUInt8()
            value += UInt32(byte & 0x7F) * multiplier
            if byte & 0x80 == 0 { return value }
            multiplier *= 128
        }
        throw MQTTDecodingError.malformedVariableByteInteger
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw MQTTDecodingError.unexpectedEndOfPacket }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    mutating func readRest() -> [UInt8] {
        defer { index = end }
        return Array(bytes[index..<end])
    }

    /// Two-byte length prefixed binary data.
    mutating func readBinary() throws -> [UInt8] {
        try readBytes(Int(readUInt16()))
    }

    /// Two-byte length prefixed UTF-8 string.
    mutating func readString() throws -> String {
        let raw = try readBinary()
        guard let string = decodeStrictUTF8(raw) else {
            throw MQTTDecodingError.invalidUTF8String
        }
        return string
    }
}

/// Decodes UTF-8, returning nil on any invalid sequence instead of repairing it.
func decodeStrictUTF8(_ bytes: [UInt8]) -> String? {
    var iterator = bytes.makeIterator()
    var decoder = UTF8()
    var scalars = String.UnicodeScalarView()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar): scalars.append(scalar)
        case .emptyInput: return String(scalars)
        case .error: return nil
        }
    }
}
