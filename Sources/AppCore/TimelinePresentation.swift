import Foundation
import MQTTCore
import ProxyCore

/// What a timeline row's status dot and code say about how it went.
public enum RowTone: Sendable, Equatable {
    case success, redirect, clientError, failure, mqtt, webSocket, neutral
}

/// One-click filters shown above the timeline, on top of the sidebar section and search.
public enum QuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all, json, media, errors, publish

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .json: "JSON"
        case .media: "Media"
        case .errors: "Errors"
        case .publish: "Publish"
        }
    }

    public func includes(_ row: TrafficRow) -> Bool {
        switch self {
        case .all:
            return true
        case .json:
            switch row.event {
            case .httpExchange(let exchange):
                return exchange.contentType?.contains("json") == true
            case .mqtt(let capture):
                if case .publish(let publish) = capture.event.packet { return Formatting.prettyJSON(publish.payload) != nil }
                return false
            case .webSocketMessage(let message):
                return Formatting.prettyJSON(message.payload) != nil
            default:
                return false
            }
        case .media:
            guard case .httpExchange(let exchange) = row.event, let type = exchange.contentType else { return false }
            return ["image/", "video/", "audio/", "font/"].contains { type.hasPrefix($0) }
        case .errors:
            return row.isIssue || (row.statusCode ?? 0) >= 400
        case .publish:
            guard case .mqtt(let capture) = row.event, case .publish = capture.event.packet else { return false }
            return true
        }
    }
}

extension HTTPExchange {
    /// The response's media type, lowercased and without parameters.
    var contentType: String? {
        responseHeaders.first { $0.name.lowercased() == "content-type" }?.value
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

extension TrafficRow {
    /// The short label in the row's type pill: the HTTP method, MQTT packet type or WebSocket opcode.
    public var pill: String {
        switch event {
        case .httpExchange(let exchange): exchange.method.uppercased()
        case .tlsInterceptionFailed: "TLS"
        default: badge
        }
    }

    public var statusCode: Int? {
        if case .httpExchange(let exchange) = event { exchange.statusCode } else { nil }
    }

    /// How long an HTTP exchange took; nil for everything else.
    public var duration: TimeInterval? {
        if case .httpExchange(let exchange) = event { exchange.duration } else { nil }
    }

    /// What follows the host in the timeline: the path and query for HTTP, the summary otherwise.
    public var detail: String {
        switch event {
        case .httpExchange(let exchange):
            return Self.pathAndQuery(of: exchange.url)
        case .webSocketMessage(let message):
            let arrow = message.direction == .clientToServer ? "→" : "←"
            let text = String(bytes: message.payload.prefix(80), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? Formatting.byteCount(message.payload.count)
            return "\(Self.pathAndQuery(of: message.url))  \(arrow) \(text)"
        default:
            return summary
        }
    }

    public var tone: RowTone {
        if isIssue { return .failure }
        switch kind {
        case .http:
            switch statusCode ?? 0 {
            case 200..<300: return .success
            case 300..<400: return .redirect
            case 400..<500: return .clientError
            default: return .failure
            }
        case .mqtt: return .mqtt
        case .webSocket: return .webSocket
        case .tunnel, .tls: return .neutral
        }
    }

    static func pathAndQuery(of url: String) -> String {
        let withoutScheme = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
        guard let slash = withoutScheme.firstIndex(of: "/") else { return "/" }
        return String(withoutScheme[slash...])
    }
}

/// Counts of events per time bucket, oldest first, for the toolbar's activity sparkline.
public enum ActivityHistogram {
    public static func counts(of times: [Date], buckets: Int, bucketLength: TimeInterval, endingAt end: Date) -> [Int] {
        guard buckets > 0, bucketLength > 0 else { return [] }
        var counts = Array(repeating: 0, count: buckets)
        let start = end.addingTimeInterval(-Double(buckets) * bucketLength)
        for time in times.reversed() {
            if time < start { break }
            guard time <= end else { continue }
            let index = min(buckets - 1, Int(time.timeIntervalSince(start) / bucketLength))
            counts[index] += 1
        }
        return counts
    }
}

/// A host seen in the current session, with how many events it had.
public struct HostCount: Identifiable, Equatable, Sendable {
    public var host: String
    public var count: Int
    public var id: String { host }
}
