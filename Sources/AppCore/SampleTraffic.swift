import Foundation
import MQTTCore
import ProxyCore

/// A realistic mixed capture (HTTP, MQTT, WebSocket, a pinned host) for previews, screenshots
/// and tests. The MQTT events go through the real decoder, so they look exactly like live ones.
public enum SampleTraffic {
    /// - Parameter start: the first event is about 0.1 s after this; the whole capture spans about 3 s.
    public static func events(startingAt start: Date = Date(timeIntervalSinceNow: -3)) -> [CaptureEvent] {
        var events: [CaptureEvent] = []
        var clock = start
        func tick(_ seconds: TimeInterval = 0.137) -> Date {
            clock += seconds
            return clock
        }

        events.append(.tunnelOpened(TunnelInfo(openedAt: tick(), host: "api.example.com", port: 443)))
        events.append(.httpExchange(http(
            at: tick(), duration: 0.084, method: "GET", url: "https://api.example.com/v2/devices?limit=20",
            status: 200, contentType: "application/json",
            body: #"{"devices":[{"id":"thermo-01","name":"Kitchen","online":true,"firmware":"4.2.1"},{"id":"plug-07","name":"Desk lamp","online":false}],"next":null}"#
        )))
        events.append(.httpExchange(http(
            at: tick(), duration: 0.212, method: "POST", url: "https://api.example.com/v2/auth/refresh",
            status: 200, contentType: "application/json", requestBody: #"{"refresh_token":"rt_9f1c…"}"#,
            body: #"{"access_token":"eyJhbGciOi…","expires_in":3600}"#
        )))

        var session = MQTTSession()
        let broker = "broker.example.com:1883"
        let connection = UUID()
        func mqtt(_ bytes: [UInt8], _ direction: MQTTDirection) {
            let decoded = (try? session.receive(bytes, from: direction)) ?? []
            for event in decoded {
                events.append(.mqtt(MQTTCaptureEvent(connectionID: connection, timestamp: tick(0.051), broker: broker, event: event)))
            }
        }
        mqtt(MQTTBytes.connect(clientID: "ios-app-3F2A", keepAlive: 60), .clientToBroker)
        mqtt([0x20, 0x02, 0x00, 0x00], .brokerToClient)
        mqtt(MQTTBytes.subscribe(id: 1, filters: ["home/+/temperature", "home/+/status"]), .clientToBroker)
        mqtt([0x90, 0x04, 0x00, 0x01, 0x01, 0x01], .brokerToClient)

        events.append(.httpExchange(http(
            at: tick(), duration: 0.031, method: "GET", url: "https://cdn.example.com/img/kitchen@3x.png",
            status: 200, contentType: "image/png", bodyBytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 40)
        )))

        let readings: [(String, String, Bool)] = [
            ("home/kitchen/temperature", #"{"celsius":21.4,"humidity":0.43}"#, false),
            ("home/kitchen/status", "online", true),
            ("home/bedroom/temperature", #"{"celsius":19.8,"humidity":0.51}"#, false),
            ("home/garage/status", "offline", true),
            ("home/kitchen/temperature", #"{"celsius":21.6,"humidity":0.42}"#, false),
            ("home/bedroom/temperature", #"{"celsius":19.9,"humidity":0.50}"#, false),
        ]
        for (topic, payload, retain) in readings {
            mqtt(MQTTBytes.publish(topic: topic, payload: Array(payload.utf8), retain: retain), .brokerToClient)
        }
        mqtt(MQTTBytes.publish(topic: "home/kitchen/set", payload: Array(#"{"target":22}"#.utf8), retain: false), .clientToBroker)

        let socket = UUID()
        events.append(.webSocketMessage(WebSocketMessage(
            connectionID: socket, timestamp: tick(), url: "wss://live.example.com/feed", direction: .clientToServer,
            opcode: .text, payload: Array(#"{"op":"subscribe","channel":"prices"}"#.utf8)
        )))
        events.append(.webSocketMessage(WebSocketMessage(
            connectionID: socket, timestamp: tick(), url: "wss://live.example.com/feed", direction: .serverToClient,
            opcode: .text, payload: Array(#"{"channel":"prices","symbol":"ACME","bid":101.25,"ask":101.31}"#.utf8)
        )))

        events.append(.httpExchange(http(
            at: tick(), duration: 1.42, method: "PUT", url: "https://api.example.com/v2/devices/plug-07",
            status: 503, contentType: "text/plain", requestBody: #"{"on":true}"#, body: "upstream unavailable"
        )))
        events.append(.httpExchange(http(
            at: tick(), duration: 0.097, method: "GET", url: "http://config.example.com/flags.json",
            status: 304, contentType: nil, body: ""
        )))
        // Recorded with the time it is stored, so it goes last to keep the timeline in order.
        events.append(.tlsInterceptionFailed(host: "pinned.bank.example", port: 443,
                                              reason: "handshake failed: the client rejected the certificate (bad certificate)"))
        return events
    }

    private static func http(at date: Date, duration: TimeInterval, method: String, url: String, status: Int?,
                             contentType: String?, requestBody: String = "", body: String = "",
                             bodyBytes: [UInt8]? = nil) -> HTTPExchange {
        let response = bodyBytes ?? Array(body.utf8)
        var requestHeaders = [
            CapturedHeader(name: "Host", value: URL(string: url)?.host ?? ""),
            CapturedHeader(name: "User-Agent", value: "ExampleApp/5.3 (iPhone; iOS 26.1)"),
            CapturedHeader(name: "Accept", value: "application/json"),
            CapturedHeader(name: "Authorization", value: "Bearer eyJhbGciOi…"),
        ]
        if !requestBody.isEmpty {
            requestHeaders.append(CapturedHeader(name: "Content-Type", value: "application/json"))
            requestHeaders.append(CapturedHeader(name: "Content-Length", value: String(requestBody.utf8.count)))
        }
        var responseHeaders = [
            CapturedHeader(name: "Date", value: "Sun, 01 Nov 2026 09:20:00 GMT"),
            CapturedHeader(name: "Content-Length", value: String(response.count)),
            CapturedHeader(name: "Cache-Control", value: "private, max-age=0"),
        ]
        if let contentType { responseHeaders.insert(CapturedHeader(name: "Content-Type", value: contentType), at: 1) }
        return HTTPExchange(startedAt: date, duration: duration, method: method, url: url,
                            requestHeaders: requestHeaders, requestBody: Array(requestBody.utf8), statusCode: status,
                            responseHeaders: responseHeaders, responseBody: response)
    }
}

/// Builds MQTT 3.1.1 packets for sample data.
enum MQTTBytes {
    static func connect(clientID: String, keepAlive: UInt16) -> [UInt8] {
        let body = string("MQTT") + [0x04, 0x02, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)] + string(clientID)
        return packet(0x10, body)
    }

    static func subscribe(id: UInt16, filters: [String]) -> [UInt8] {
        var body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)]
        for filter in filters { body += string(filter) + [0x01] }
        return packet(0x82, body)
    }

    static func publish(topic: String, payload: [UInt8], retain: Bool) -> [UInt8] {
        packet(retain ? 0x31 : 0x30, string(topic) + payload)
    }

    static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    static func packet(_ header: UInt8, _ body: [UInt8]) -> [UInt8] {
        var length = body.count
        var encoded: [UInt8] = []
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            encoded.append(byte)
        } while length > 0
        return [header] + encoded + body
    }
}
