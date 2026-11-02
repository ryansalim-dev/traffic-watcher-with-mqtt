import Foundation
import MQTTCore
import ProxyCore

extension TopicTree {
    /// The tree narrowed to topics whose path contains `query` (case-insensitive), with their ancestors kept
    /// so the hierarchy still reads. An empty query returns everything.
    public func filtered(matching query: String) -> [TopicNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return roots }
        func keep(_ node: TopicNode) -> TopicNode? {
            if node.id.range(of: query, options: [.caseInsensitive]) != nil { return node }
            let children = node.children.compactMap(keep)
            guard !children.isEmpty else { return nil }
            var copy = node
            copy.children = children
            return copy
        }
        return roots.compactMap(keep)
    }

    /// Every topic that has had a message published to it exactly, in tree order.
    public var leafTopics: [String] {
        var topics: [String] = []
        func walk(_ nodes: [TopicNode]) {
            for node in nodes {
                if node.messageCount > 0 { topics.append(node.id) }
                walk(node.children)
            }
        }
        walk(roots)
        return topics
    }
}

/// Messages per second of an MQTT broker over a recent window.
public struct BrokerRate: Equatable, Sendable {
    public var broker: String
    public var perSecond: Double
}

extension CaptureViewModel {
    /// The captured PUBLISH packets to `topic`, newest last.
    public func publishes(onTopic topic: String) -> [MQTTCaptureEvent] {
        rows.compactMap { row in
            guard case .mqtt(let capture) = row.event, case .publish(let publish) = capture.event.packet,
                  (capture.event.resolvedTopic ?? publish.topic) == topic else { return nil }
            return capture
        }
    }

    /// Fills the composer with the latest message on `topic`. False when none was captured.
    @discardableResult
    public func prepareReplayOfLatest(onTopic topic: String) -> Bool {
        guard let latest = publishes(onTopic: topic).last else { return false }
        composer.prepareReplay(of: latest, forwarders: configuration.forwarders)
        return true
    }

    /// MQTT packets per second through `broker` (as `host:port`) over the last `window` seconds.
    public func messagesPerSecond(broker: String, window: TimeInterval = 10, now: Date = Date()) -> Double {
        let start = now.addingTimeInterval(-window)
        var count = 0
        for row in rows.reversed() {
            if row.time < start { break }
            if row.time <= now, case .mqtt(let capture) = row.event, capture.broker == broker { count += 1 }
        }
        return Double(count) / window
    }

    /// Other topics seen in this session, for the composer's suggestions.
    public func topicSuggestions(excluding topic: String, limit: Int = 4) -> [String] {
        Array(topicTree.leafTopics.filter { $0 != topic }.prefix(limit))
    }
}

public enum RateFormat {
    /// "0.9/s", "12/s" or "4/min" for slow topics.
    public static func perSecond(_ value: Double) -> String {
        if value <= 0 { return "0/s" }
        if value < 0.1 { return "\(Int((value * 60).rounded()))/min" }
        if value < 10 { return String(format: "%.1f/s", value) }
        return "\(Int(value.rounded()))/s"
    }
}
