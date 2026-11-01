import Foundation
import MQTTCore
import NIOCore

/// Watches both byte streams of a proxied WebSocket upgrade. It records the handshake as an
/// `HTTPExchange`, then decodes frames: sockets whose negotiated subprotocol starts with `mqtt`
/// are fed to an `MQTTSession`, and any other socket produces `webSocketMessage` events.
/// Confined to one event loop.
final class WebSocketTap {
    private enum State {
        case awaitingHandshake(response: [UInt8])
        case frames
        /// Not upgraded, or parsing failed: bytes are relayed but no longer inspected.
        case passthrough
    }

    let connectionID = UUID()
    private let sink: CaptureSink
    private let url: String
    private let request: HTTPExchange
    private var state = State.awaitingHandshake(response: [])
    private var clientParser = WebSocketFrameParser()
    private var serverParser = WebSocketFrameParser()
    private var clientBacklog: [UInt8] = []
    private var mqtt: MQTTTap?

    /// - Parameter request: the handshake as captured so far (response fields are filled in here).
    init(sink: CaptureSink, request: HTTPExchange) {
        self.sink = sink
        self.url = request.url
        self.request = request
    }

    func receiveFromClient(_ buffer: ByteBuffer) {
        switch state {
        case .awaitingHandshake:
            clientBacklog += buffer.readableBytesView
        case .frames:
            decode(Array(buffer.readableBytesView), direction: .clientToServer)
        case .passthrough:
            break
        }
    }

    func receiveFromServer(_ buffer: ByteBuffer) {
        switch state {
        case .awaitingHandshake(var response):
            response += buffer.readableBytesView
            guard let end = headerEnd(response) else {
                state = response.count > 64 * 1024 ? .passthrough : .awaitingHandshake(response: response)
                return
            }
            let head = parseResponseHead(response[..<end])
            var exchange = request
            exchange.statusCode = head.status
            exchange.responseHeaders = head.headers
            exchange.duration = Date().timeIntervalSince(request.startedAt)
            if head.status != 101 { exchange.error = "Server declined the WebSocket upgrade" }
            sink.record(.httpExchange(exchange))

            guard head.status == 101 else {
                state = .passthrough
                return
            }
            let subprotocol = head.headers.first { $0.name.lowercased() == "sec-websocket-protocol" }?.value ?? ""
            if subprotocol.lowercased().hasPrefix("mqtt") {
                mqtt = MQTTTap(sink: sink, broker: url)
            }
            state = .frames
            decode(Array(response[(end + 4)...]), direction: .serverToClient)
            let backlog = clientBacklog
            clientBacklog = []
            decode(backlog, direction: .clientToServer)
        case .frames:
            decode(Array(buffer.readableBytesView), direction: .serverToClient)
        case .passthrough:
            break
        }
    }

    private func decode(_ bytes: [UInt8], direction: WebSocketDirection) {
        guard case .frames = state, !bytes.isEmpty else { return }
        let messages: [WebSocketFrameParser.Message]
        do {
            messages = direction == .clientToServer ? try clientParser.feed(bytes) : try serverParser.feed(bytes)
        } catch {
            state = .passthrough
            sink.record(.webSocketDecodingFailed(connectionID: connectionID, reason: String(describing: error)))
            return
        }
        let now = Date()
        for message in messages {
            if let mqtt {
                // MQTT rides in binary messages; control frames are transport noise here.
                if message.opcode == .binary {
                    var buffer = ByteBuffer()
                    buffer.writeBytes(message.payload)
                    mqtt.receive(buffer, from: direction == .clientToServer ? .clientToBroker : .brokerToClient)
                }
            } else {
                sink.record(.webSocketMessage(WebSocketMessage(
                    connectionID: connectionID,
                    timestamp: now,
                    url: url,
                    direction: direction,
                    opcode: message.opcode,
                    payload: message.payload
                )))
            }
        }
    }
}

/// Index of the `\r\n\r\n` that ends an HTTP head, if present.
func headerEnd(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for index in 0...(bytes.count - 4)
    where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
        return index
    }
    return nil
}

/// Parses a status line and headers such as `HTTP/1.1 101 Switching Protocols`.
func parseResponseHead(_ bytes: ArraySlice<UInt8>) -> (status: Int?, headers: [CapturedHeader]) {
    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
    let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
    let status = statusParts.count >= 2 ? Int(statusParts[1]) : nil
    let headers = lines.dropFirst().compactMap { line -> CapturedHeader? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return CapturedHeader(
            name: String(line[..<colon]),
            value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        )
    }
    return (status, headers)
}
