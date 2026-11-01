import Foundation
import MQTTCore
import ProxyCore

extension CaptureStore {
    /// HTTP(S) exchanges of a session as a HAR 1.2 document, readable by browsers and most tools.
    public func exportHAR(session: UUID) throws -> Data {
        let entries = try events(in: session, kinds: ["http"], limit: .max).compactMap { stored -> HAR.Entry? in
            guard case .httpExchange(let e) = stored.event else { return nil }
            return HAR.Entry(e)
        }
        let har = HAR(log: .init(
            version: "1.2",
            creator: .init(name: "Wiretide", version: "0.1"),
            entries: entries
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(har)
    }

    /// MQTT packets of a session as JSON Lines: one object per packet with its decoded fields
    /// and the raw bytes in hex, so it can be grepped, diffed or replayed later.
    public func exportMQTTJSONLines(session: UUID) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = Data()
        for stored in try events(in: session, kinds: ["mqtt"], limit: .max) {
            guard case .mqtt(let m) = stored.event else { continue }
            output += try encoder.encode(MQTTLine(m))
            output.append(0x0A)
        }
        return output
    }
}

private struct MQTTLine: Encodable {
    var timestamp: String
    var connection: String
    var broker: String
    var direction: String
    var version: String
    var type: String
    var topic: String?
    var qos: UInt8?
    var retain: Bool?
    var packetIdentifier: UInt16?
    var clientIdentifier: String?
    var payload: String?
    var payloadHex: String?
    var raw: String

    init(_ m: MQTTCaptureEvent) {
        timestamp = ISO8601DateFormatter.withFractionalSeconds.string(from: m.timestamp)
        connection = m.connectionID.uuidString
        broker = m.broker
        direction = m.event.direction.rawValue
        version = m.event.version.description
        type = "\(m.event.packet.type)".uppercased()
        raw = m.event.frame.rawBytes.hex
        switch m.event.packet {
        case .publish(let p):
            topic = m.event.resolvedTopic ?? p.topic
            qos = p.qos.rawValue
            retain = p.retain
            packetIdentifier = p.packetIdentifier
            payload = String(bytes: p.payload, encoding: .utf8)
            payloadHex = p.payload.hex
        case .connect(let c):
            clientIdentifier = c.clientIdentifier
        case .subscribe(let s):
            packetIdentifier = s.packetIdentifier
            topic = s.subscriptions.map(\.topicFilter).joined(separator: ",")
        default:
            break
        }
    }
}

/// The subset of HAR 1.2 that captured exchanges fill in.
struct HAR: Codable {
    var log: Log

    struct Log: Codable {
        var version: String
        var creator: Creator
        var entries: [Entry]
    }

    struct Creator: Codable {
        var name: String
        var version: String
    }

    struct Header: Codable, Equatable {
        var name: String
        var value: String
    }

    struct Entry: Codable {
        var startedDateTime: String
        var time: Double
        var request: Request
        var response: Response
        var cache: [String: String] = [:]
        var timings: Timings
        var comment: String?

        init(_ e: HTTPExchange) {
            startedDateTime = ISO8601DateFormatter.withFractionalSeconds.string(from: e.startedAt)
            time = (e.duration * 1000).rounded()
            let requestHeaders = e.requestHeaders.map { Header(name: $0.name, value: $0.value) }
            let queryString = URLComponents(string: e.url)?.queryItems?.map { Header(name: $0.name, value: $0.value ?? "") } ?? []
            request = Request(
                method: e.method,
                url: e.url,
                httpVersion: "HTTP/1.1",
                headers: requestHeaders,
                queryString: queryString,
                headersSize: -1,
                bodySize: e.requestBody.count,
                postData: e.requestBody.isEmpty ? nil : PostData(
                    mimeType: Self.contentType(e.requestHeaders),
                    text: String(bytes: e.requestBody, encoding: .utf8) ?? Data(e.requestBody).base64EncodedString()
                )
            )
            let text = String(bytes: e.responseBody, encoding: .utf8)
            response = Response(
                status: e.statusCode ?? 0,
                statusText: "",
                httpVersion: "HTTP/1.1",
                headers: e.responseHeaders.map { Header(name: $0.name, value: $0.value) },
                content: Content(
                    size: e.responseBody.count,
                    mimeType: Self.contentType(e.responseHeaders),
                    text: e.responseBody.isEmpty ? nil : (text ?? Data(e.responseBody).base64EncodedString()),
                    encoding: e.responseBody.isEmpty || text != nil ? nil : "base64"
                ),
                redirectURL: e.responseHeaders.first { $0.name.lowercased() == "location" }?.value ?? "",
                headersSize: -1,
                bodySize: e.responseBody.count
            )
            timings = Timings(send: 0, wait: time, receive: 0)
            comment = e.error
        }

        static func contentType(_ headers: [CapturedHeader]) -> String {
            headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
        }
    }

    struct Request: Codable {
        var method: String
        var url: String
        var httpVersion: String
        var cookies: [Header] = []
        var headers: [Header]
        var queryString: [Header]
        var headersSize: Int
        var bodySize: Int
        var postData: PostData?

        init(method: String, url: String, httpVersion: String, headers: [Header], queryString: [Header], headersSize: Int, bodySize: Int, postData: PostData?) {
            self.method = method
            self.url = url
            self.httpVersion = httpVersion
            self.headers = headers
            self.queryString = queryString
            self.headersSize = headersSize
            self.bodySize = bodySize
            self.postData = postData
        }
    }

    struct PostData: Codable {
        var mimeType: String
        var text: String
    }

    struct Response: Codable {
        var status: Int
        var statusText: String
        var httpVersion: String
        var cookies: [Header] = []
        var headers: [Header]
        var content: Content
        var redirectURL: String
        var headersSize: Int
        var bodySize: Int

        init(status: Int, statusText: String, httpVersion: String, headers: [Header], content: Content, redirectURL: String, headersSize: Int, bodySize: Int) {
            self.status = status
            self.statusText = statusText
            self.httpVersion = httpVersion
            self.headers = headers
            self.content = content
            self.redirectURL = redirectURL
            self.headersSize = headersSize
            self.bodySize = bodySize
        }
    }

    struct Content: Codable {
        var size: Int
        var mimeType: String
        var text: String?
        var encoding: String?
    }

    struct Timings: Codable {
        var send: Double
        var wait: Double
        var receive: Double
    }
}

extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
