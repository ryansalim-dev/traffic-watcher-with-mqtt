import Foundation
import MQTTCore
import ProxyCore

/// How a body or payload is best shown.
public enum BodyPresentation: Equatable, Sendable {
    case empty
    case json(String)
    case text(String)
    case binary(hexDump: String)
}

public enum Formatting {
    /// Picks JSON (pretty-printed), plain text or a hex dump for `bytes`.
    public static func present(_ bytes: [UInt8], contentType: String? = nil, maximumBytes: Int = 1_000_000) -> BodyPresentation {
        guard !bytes.isEmpty else { return .empty }
        let slice = Array(bytes.prefix(maximumBytes))
        let looksJSON = contentType?.lowercased().contains("json") ?? false
            || slice.first(where: { !$0.isWhitespaceByte }).map { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") } ?? false
        if looksJSON, let pretty = prettyJSON(slice) {
            return .json(pretty)
        }
        if let text = String(bytes: slice, encoding: .utf8), !text.containsControlCharacters {
            return .text(text)
        }
        return .binary(hexDump: hexDump(slice))
    }

    public static func prettyJSON(_ bytes: [UInt8]) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Classic 16-bytes-per-line dump: offset, hex in two groups of 8, printable ASCII.
    public static func hexDump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let line = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = line.enumerated().map { index, byte in
                (index == 8 ? " " : "") + String(format: "%02x", byte)
            }.joined(separator: " ")
            let padded = hex.padding(toLength: 48, withPad: " ", startingAt: 0)
            let ascii = String(line.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  ", offset) + padded + "  |" + ascii + "|"
        }.joined(separator: "\n")
    }

    public static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }
}

/// One labelled value in an inspector.
public struct DetailRow: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public enum MQTTDescriber {
    /// Field-by-field description of a packet for the inspector.
    public static func rows(for event: MQTTSessionEvent) -> [DetailRow] {
        var rows = [
            DetailRow("Type", "\(event.packet.type)".uppercased()),
            DetailRow("Direction", event.direction == .clientToBroker ? "Client → Broker" : "Broker → Client"),
            DetailRow("Protocol", "MQTT \(event.version)"),
            DetailRow("Size", Formatting.byteCount(event.frame.rawBytes.count)),
        ]
        switch event.packet {
        case .connect(let c):
            rows += [
                DetailRow("Client ID", c.clientIdentifier.isEmpty ? "(empty, broker assigns)" : c.clientIdentifier),
                DetailRow("Clean start", c.cleanStart ? "Yes" : "No"),
                DetailRow("Keep alive", "\(c.keepAlive) s"),
            ]
            if let username = c.username { rows.append(DetailRow("Username", username)) }
            if c.password != nil { rows.append(DetailRow("Password", "••••••")) }
            if let will = c.will {
                rows.append(DetailRow("Will", "\(will.topic) (QoS \(will.qos.rawValue)\(will.retain ? ", retained" : ""))"))
            }
            rows += properties(c.properties)
        case .connack(let a):
            rows += [DetailRow("Session present", a.sessionPresent ? "Yes" : "No"),
                     DetailRow("Result", reasonName(a.reasonCode, connack: true, version: event.version))]
            rows += properties(a.properties)
        case .publish(let p):
            rows.append(DetailRow("Topic", event.resolvedTopic ?? p.topic))
            if p.topic.isEmpty, let alias = p.topicAlias { rows.append(DetailRow("Topic alias", "\(alias)")) }
            rows += [DetailRow("QoS", "\(p.qos.rawValue)"), DetailRow("Retain", p.retain ? "Yes" : "No")]
            if p.duplicate { rows.append(DetailRow("Duplicate", "Yes")) }
            if let id = p.packetIdentifier { rows.append(DetailRow("Packet ID", "\(id)")) }
            rows.append(DetailRow("Payload", Formatting.byteCount(p.payload.count)))
            rows += properties(p.properties)
        case .puback(let a), .pubrec(let a), .pubrel(let a), .pubcomp(let a):
            rows += [DetailRow("Packet ID", "\(a.packetIdentifier)"), DetailRow("Reason", reasonName(a.reasonCode, version: event.version))]
            rows += properties(a.properties)
        case .subscribe(let s):
            rows.append(DetailRow("Packet ID", "\(s.packetIdentifier)"))
            rows += s.subscriptions.enumerated().map { index, sub in
                DetailRow("Filter \(index + 1)", "\(sub.topicFilter) (QoS \(sub.qos.rawValue)\(sub.noLocal ? ", no local" : ""))")
            }
            rows += properties(s.properties)
        case .suback(let a), .unsuback(let a):
            rows.append(DetailRow("Packet ID", "\(a.packetIdentifier)"))
            rows += a.reasonCodes.enumerated().map { DetailRow("Result \($0 + 1)", reasonName($1, version: event.version)) }
            rows += properties(a.properties)
        case .unsubscribe(let u):
            rows.append(DetailRow("Packet ID", "\(u.packetIdentifier)"))
            rows += u.topicFilters.enumerated().map { DetailRow("Filter \($0 + 1)", $1) }
            rows += properties(u.properties)
        case .disconnect(let r), .auth(let r):
            rows.append(DetailRow("Reason", reasonName(r.reasonCode, version: event.version)))
            rows += properties(r.properties)
        case .pingreq, .pingresp:
            break
        }
        return rows
    }

    static func properties(_ properties: [MQTTProperty]) -> [DetailRow] {
        properties.map { property in
            let value: String = switch property {
            case .payloadFormatIndicator(let v): v == 1 ? "UTF-8" : "Bytes"
            case .messageExpiryInterval(let v), .sessionExpiryInterval(let v), .willDelayInterval(let v): "\(v) s"
            case .subscriptionIdentifier(let v), .maximumPacketSize(let v): "\(v)"
            case .contentType(let v), .responseTopic(let v), .assignedClientIdentifier(let v), .authenticationMethod(let v),
                 .responseInformation(let v), .serverReference(let v), .reasonString(let v): v
            case .correlationData(let v), .authenticationData(let v): v.hex
            case .serverKeepAlive(let v): "\(v) s"
            case .receiveMaximum(let v), .topicAliasMaximum(let v), .topicAlias(let v): "\(v)"
            case .requestProblemInformation(let v), .requestResponseInformation(let v), .maximumQoS(let v), .retainAvailable(let v),
                 .wildcardSubscriptionAvailable(let v), .subscriptionIdentifierAvailable(let v), .sharedSubscriptionAvailable(let v): "\(v)"
            case .userProperty(let key, let value): "\(key) = \(value)"
            }
            return DetailRow(property.name, value)
        }
    }

    /// Human-readable MQTT reason or return code.
    public static func reasonName(_ code: UInt8, connack: Bool = false, version: MQTTVersion) -> String {
        if version != .v5 {
            guard connack else { return code == 0x80 ? "Failure (0x80)" : "Granted QoS \(code)" }
            let names = ["Accepted", "Unacceptable protocol version", "Identifier rejected", "Server unavailable",
                         "Bad username or password", "Not authorized"]
            return code < names.count ? names[Int(code)] : "Unknown (\(code))"
        }
        let names: [UInt8: String] = [
            0x00: "Success", 0x01: "Granted QoS 1", 0x02: "Granted QoS 2", 0x04: "Disconnect with will",
            0x10: "No matching subscribers", 0x11: "No subscription existed", 0x18: "Continue authentication",
            0x80: "Unspecified error", 0x81: "Malformed packet", 0x82: "Protocol error", 0x83: "Implementation specific error",
            0x84: "Unsupported protocol version", 0x85: "Client identifier not valid", 0x86: "Bad user name or password",
            0x87: "Not authorized", 0x88: "Server unavailable", 0x89: "Server busy", 0x8A: "Banned",
            0x8B: "Server shutting down", 0x8C: "Bad authentication method", 0x8D: "Keep alive timeout",
            0x8E: "Session taken over", 0x8F: "Topic filter invalid", 0x90: "Topic name invalid",
            0x91: "Packet identifier in use", 0x92: "Packet identifier not found", 0x93: "Receive maximum exceeded",
            0x94: "Topic alias invalid", 0x95: "Packet too large", 0x96: "Message rate too high", 0x97: "Quota exceeded",
            0x98: "Administrative action", 0x99: "Payload format invalid", 0x9A: "Retain not supported",
            0x9B: "QoS not supported", 0x9C: "Use another server", 0x9D: "Server moved",
            0x9E: "Shared subscriptions not supported", 0x9F: "Connection rate exceeded", 0xA0: "Maximum connect time",
            0xA1: "Subscription identifiers not supported", 0xA2: "Wildcard subscriptions not supported",
        ]
        return "\(names[code] ?? "Unknown") (0x\(String(format: "%02X", code)))"
    }
}

private extension UInt8 {
    var isWhitespaceByte: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

private extension String {
    var containsControlCharacters: Bool {
        unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
