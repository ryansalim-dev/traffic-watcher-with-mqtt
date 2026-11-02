import Foundation
import MQTTCore
import NIOCore

/// Watches both byte streams of a proxied WebSocket upgrade and decides what is forwarded. It
/// records the handshake as an `HTTPExchange`, then decodes frames: sockets whose negotiated
/// subprotocol starts with `mqtt` run through an `MQTTRelay` (capture plus MQTT rewrite rules),
/// and any other socket produces `webSocketMessage` events and is forwarded byte for byte.
///
/// On an MQTT socket only complete frames are forwarded. Binary messages whose MQTT bytes a rule
/// changed are sent as one new frame (masked toward the server, as RFC 6455 requires); everything
/// else (control frames, text, untouched binary messages) goes out exactly as it came in.
/// Confined to one event loop.
final class WebSocketTap {
    private enum State {
        case awaitingHandshake(response: [UInt8])
        case frames
        /// Not upgraded, or parsing failed: bytes are relayed but no longer inspected.
        case passthrough
    }

    /// Per-direction framing state for an MQTT socket.
    private struct Stream {
        var parser = WebSocketFrameParser()
        /// Opcode of the data message in progress (for continuation frames).
        var messageOpcode: WebSocketOpcode?
        /// Raw frames of a fragmented binary message, held until its last frame.
        var heldFrames: [UInt8] = []
        /// Bytes went out before the socket was known to be MQTT, so this direction is captured
        /// but forwarded unchanged (rewriting it would split or repeat frames).
        var forwardRaw = false
        /// Parsing stopped on the other side; this side still owes the bytes it held back.
        var needsFlush = false
    }

    let connectionID = UUID()
    private let sink: CaptureSink
    private let url: String
    private let request: HTTPExchange
    private let rules: LiveRules?
    private let scripts: LiveScripts?
    private var state = State.awaitingHandshake(response: [])
    private var client = Stream()
    private var server = Stream()
    private var clientBacklog: [UInt8] = []
    private var relay: MQTTRelay?

    /// - Parameter request: the handshake as captured so far (response fields are filled in here).
    /// - Parameter rules: MQTT rewrite rules, read for every packet.
    /// - Parameter scripts: scripts with `onPublish`, run after the rules.
    init(sink: CaptureSink, request: HTTPExchange, rules: LiveRules? = nil, scripts: LiveScripts? = nil) {
        self.sink = sink
        self.url = request.url
        self.request = request
        self.rules = rules
        self.scripts = scripts
    }

    /// Takes bytes read from the client and returns the bytes to write to the server.
    func receiveFromClient(_ bytes: [UInt8]) -> [UInt8] {
        switch state {
        case .awaitingHandshake:
            // Frames sent before the 101 arrives go out as they are and are decoded once it does.
            clientBacklog += bytes
            return bytes
        case .frames:
            return process(bytes, direction: .clientToServer)
        case .passthrough:
            return flush(.clientToServer) + bytes
        }
    }

    /// Takes bytes read from the server and returns the bytes to write to the client.
    func receiveFromServer(_ bytes: [UInt8]) -> [UInt8] {
        switch state {
        case .awaitingHandshake(var response):
            let previous = response.count
            response += bytes
            guard let end = headerEnd(response) else {
                state = response.count > 64 * 1024 ? .passthrough : .awaitingHandshake(response: response)
                return bytes
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
                clientBacklog = []
                return bytes
            }
            let subprotocol = head.headers.first { $0.name.lowercased() == "sec-websocket-protocol" }?.value ?? ""
            if subprotocol.lowercased().hasPrefix("mqtt") {
                relay = MQTTRelay(sink: sink, broker: url, rules: rules, scripts: scripts)
            }
            state = .frames
            let headLength = end + 4 - previous
            var output = Array(bytes[..<headLength])
            output += process(Array(bytes[headLength...]), direction: .serverToClient)

            let backlog = clientBacklog
            clientBacklog = []
            if !backlog.isEmpty {
                client.forwardRaw = true
                _ = process(backlog, direction: .clientToServer)
            }
            return output
        case .frames:
            return process(bytes, direction: .serverToClient)
        case .passthrough:
            return flush(.serverToClient) + bytes
        }
    }

    private func process(_ bytes: [UInt8], direction: WebSocketDirection) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        guard let relay else {
            record(bytes, direction: direction)
            return bytes
        }
        var stream = direction == .clientToServer ? client : server
        defer {
            if direction == .clientToServer { client = stream } else { server = stream }
        }
        if stream.forwardRaw {
            _ = mqttOutput(bytes, stream: &stream, relay: relay, direction: direction)
            return bytes
        }
        return mqttOutput(bytes, stream: &stream, relay: relay, direction: direction)
    }

    private func mqttOutput(_ bytes: [UInt8], stream: inout Stream, relay: MQTTRelay, direction: WebSocketDirection) -> [UInt8] {
        let mqttDirection: MQTTDirection = direction == .clientToServer ? .clientToBroker : .brokerToClient
        let (frames, parseError) = stream.parser.frames(bytes)
        var output: [UInt8] = []
        var failure: Error? = parseError
        for frame in frames {
            let message: WebSocketFrameParser.Message?
            do {
                message = try stream.parser.assemble(frame)
            } catch {
                failure = error
                // This frame and everything after it go out untouched.
                output += frame.raw
                break
            }
            if frame.opcode.isControl {
                output += frame.raw
                continue
            }
            if frame.opcode != .continuation { stream.messageOpcode = frame.opcode }
            guard stream.messageOpcode == .binary else {
                // MQTT rides in binary messages; text is forwarded as it is.
                output += frame.raw
                continue
            }
            stream.heldFrames += frame.raw
            guard let message else { continue }
            let relayed = relay.relay(message.payload, from: mqttDirection)
            if relayed == message.payload {
                output += stream.heldFrames
            } else if !relayed.isEmpty {
                output += WebSocketFrameParser.encode(opcode: .binary, payload: relayed, masked: direction == .clientToServer)
            }
            stream.heldFrames = []
        }
        if let failure {
            output += release(&stream, relay: relay, direction: direction)
            state = .passthrough
            if direction == .clientToServer { server.needsFlush = true } else { client.needsFlush = true }
            sink.record(.webSocketDecodingFailed(connectionID: connectionID, reason: String(describing: failure)))
        }
        return output
    }

    /// Everything a stream still holds, in order, so the connection can carry on uninspected.
    private func release(_ stream: inout Stream, relay: MQTTRelay?, direction: WebSocketDirection) -> [UInt8] {
        var output: [UInt8] = []
        if let relay {
            let pending = relay.takePending(from: direction == .clientToServer ? .clientToBroker : .brokerToClient)
            if !pending.isEmpty, !stream.forwardRaw {
                output += WebSocketFrameParser.encode(opcode: .binary, payload: pending, masked: direction == .clientToServer)
            }
        }
        if !stream.forwardRaw {
            output += stream.heldFrames
            output += stream.parser.takeBuffered()
        }
        stream.heldFrames = []
        return output
    }

    private func flush(_ direction: WebSocketDirection) -> [UInt8] {
        if direction == .clientToServer {
            guard client.needsFlush else { return [] }
            client.needsFlush = false
            return release(&client, relay: relay, direction: direction)
        } else {
            guard server.needsFlush else { return [] }
            server.needsFlush = false
            return release(&server, relay: relay, direction: direction)
        }
    }

    /// Records the messages of a socket that isn't MQTT.
    private func record(_ bytes: [UInt8], direction: WebSocketDirection) {
        let messages: [WebSocketFrameParser.Message]
        do {
            messages = direction == .clientToServer ? try client.parser.feed(bytes) : try server.parser.feed(bytes)
        } catch {
            state = .passthrough
            sink.record(.webSocketDecodingFailed(connectionID: connectionID, reason: String(describing: error)))
            return
        }
        let now = Date()
        for message in messages {
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
