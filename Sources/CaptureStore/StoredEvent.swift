import Foundation
import MQTTCore
import ProxyCore

/// Codable mirror of `CaptureEvent`. MQTT packets are stored as their raw bytes plus the protocol
/// version and decoded again on load, so the database holds exactly what crossed the wire.
enum StoredEvent: Codable {
    case httpExchange(HTTPExchange)
    case tunnelOpened(TunnelInfo)
    case tunnelClosed(id: UUID, bytesFromClient: Int, bytesFromServer: Int)
    case mqtt(StoredMQTT)
    case mqttDecodingFailed(connectionID: UUID, reason: String)
    case tlsInterceptionFailed(host: String, port: Int, reason: String)
    case webSocketMessage(WebSocketMessage)
    case webSocketDecodingFailed(connectionID: UUID, reason: String)

    struct StoredMQTT: Codable {
        var connectionID: UUID
        var timestamp: Date
        var broker: String
        var direction: MQTTDirection
        var version: MQTTVersion
        var rawBytes: Data
        var resolvedTopic: String?
    }

    init(_ event: CaptureEvent) {
        switch event {
        case .httpExchange(let e): self = .httpExchange(e)
        case .tunnelOpened(let e): self = .tunnelOpened(e)
        case .tunnelClosed(let id, let up, let down): self = .tunnelClosed(id: id, bytesFromClient: up, bytesFromServer: down)
        case .mqtt(let e):
            self = .mqtt(StoredMQTT(
                connectionID: e.connectionID,
                timestamp: e.timestamp,
                broker: e.broker,
                direction: e.event.direction,
                version: e.event.version,
                rawBytes: Data(e.event.frame.rawBytes),
                resolvedTopic: e.event.resolvedTopic
            ))
        case .mqttDecodingFailed(let id, let reason): self = .mqttDecodingFailed(connectionID: id, reason: reason)
        case .tlsInterceptionFailed(let host, let port, let reason): self = .tlsInterceptionFailed(host: host, port: port, reason: reason)
        case .webSocketMessage(let m): self = .webSocketMessage(m)
        case .webSocketDecodingFailed(let id, let reason): self = .webSocketDecodingFailed(connectionID: id, reason: reason)
        }
    }

    func captureEvent() throws -> CaptureEvent {
        switch self {
        case .httpExchange(let e): return .httpExchange(e)
        case .tunnelOpened(let e): return .tunnelOpened(e)
        case .tunnelClosed(let id, let up, let down): return .tunnelClosed(id: id, bytesFromClient: up, bytesFromServer: down)
        case .mqtt(let m):
            let raw = [UInt8](m.rawBytes)
            let packet = try MQTTPacketDecoder.decode(raw, version: m.version)
            return .mqtt(MQTTCaptureEvent(
                connectionID: m.connectionID,
                timestamp: m.timestamp,
                broker: m.broker,
                event: MQTTSessionEvent(
                    direction: m.direction,
                    version: m.version,
                    frame: MQTTFrame(packet: packet, rawBytes: raw),
                    resolvedTopic: m.resolvedTopic
                )
            ))
        case .mqttDecodingFailed(let id, let reason): return .mqttDecodingFailed(connectionID: id, reason: reason)
        case .tlsInterceptionFailed(let host, let port, let reason): return .tlsInterceptionFailed(host: host, port: port, reason: reason)
        case .webSocketMessage(let m): return .webSocketMessage(m)
        case .webSocketDecodingFailed(let id, let reason): return .webSocketDecodingFailed(connectionID: id, reason: reason)
        }
    }
}

/// Columns derived from an event for listing, filtering and full-text search.
struct EventIndex {
    var kind: String
    var timestamp: Date
    var host: String
    var summary: String
    var searchText: String

    /// Bodies and payloads beyond this many bytes are left out of the search index.
    static let searchableBodyLimit = 64 * 1024

    init(_ event: CaptureEvent, recordedAt now: Date) {
        switch event {
        case .httpExchange(let e):
            kind = "http"
            timestamp = e.startedAt
            host = Self.host(of: e.url)
            summary = "\(e.method) \(e.url) \(e.statusCode.map(String.init) ?? "-")"
            let headers = (e.requestHeaders + e.responseHeaders).map { "\($0.name): \($0.value)" }
            searchText = ([summary, e.error ?? ""] + headers + [Self.text(e.requestBody), Self.text(e.responseBody)]).joined(separator: "\n")
        case .tunnelOpened(let t):
            kind = "tunnel"
            timestamp = t.openedAt
            host = t.host
            summary = "CONNECT \(t.host):\(t.port)"
            searchText = summary
        case .tunnelClosed(let id, let up, let down):
            kind = "tunnel"
            timestamp = now
            host = ""
            summary = "Tunnel closed (\(up) bytes up, \(down) down)"
            searchText = "\(summary) \(id.uuidString)"
        case .mqtt(let m):
            kind = "mqtt"
            timestamp = m.timestamp
            host = Self.host(of: m.broker)
            let packet = m.event.packet
            var parts = ["\(packet.type)".uppercased(), m.broker]
            var payload: [UInt8] = []
            switch packet {
            case .connect(let c): parts += ["client \(c.clientIdentifier)", c.username ?? "", c.will?.topic ?? ""]
            case .publish(let p): parts.append(m.event.resolvedTopic ?? p.topic); payload = p.payload
            case .subscribe(let s): parts += s.subscriptions.map(\.topicFilter)
            case .unsubscribe(let u): parts += u.topicFilters
            default: break
            }
            summary = parts.prefix(3).filter { !$0.isEmpty }.joined(separator: " ")
            searchText = (parts + [Self.text(payload)]).joined(separator: "\n")
        case .mqttDecodingFailed(_, let reason):
            kind = "mqtt"
            timestamp = now
            host = ""
            summary = "MQTT decoding stopped: \(reason)"
            searchText = summary
        case .tlsInterceptionFailed(let h, let port, let reason):
            kind = "tls"
            timestamp = now
            host = h
            summary = "Client rejected certificate for \(h):\(port)"
            searchText = "\(summary)\n\(reason)"
        case .webSocketMessage(let m):
            kind = "websocket"
            timestamp = m.timestamp
            host = Self.host(of: m.url)
            summary = "\(m.direction == .clientToServer ? "→" : "←") \(m.opcode) \(m.url)"
            searchText = "\(summary)\n\(Self.text(m.payload))"
        case .webSocketDecodingFailed(_, let reason):
            kind = "websocket"
            timestamp = now
            host = ""
            summary = "WebSocket decoding stopped: \(reason)"
            searchText = summary
        }
    }

    /// The payload as text when it is valid UTF-8, else empty.
    static func text(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty, bytes.count <= searchableBodyLimit else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    static func host(of url: String) -> String {
        if let components = URLComponents(string: url), let host = components.host { return host }
        // "host:port" brokers
        return String(url.split(separator: ":").first ?? "")
    }
}
