import Foundation
import MQTTCore

/// A live tree of MQTT topics seen in PUBLISH packets, like a file browser for a broker.
/// Each node counts messages at and below it and keeps the latest payload published to it.
public struct TopicNode: Identifiable, Equatable, Sendable {
    /// Full topic path of this node, e.g. `home/kitchen/temp`.
    public var id: String
    public var name: String
    public var children: [TopicNode] = []
    /// Messages published exactly to this topic.
    public var messageCount = 0
    /// Messages published to this topic or any topic below it.
    public var totalCount = 0
    public var lastPayload: [UInt8]?
    public var lastUpdated: Date?
    public var retained = false

    /// Children for `OutlineGroup`, nil for leaves so no disclosure arrow is drawn.
    public var outlineChildren: [TopicNode]? { children.isEmpty ? nil : children }
}

public struct TopicTree: Equatable, Sendable {
    public private(set) var roots: [TopicNode] = []

    public init() {}

    public mutating func record(topic: String, payload: [UInt8], retained: Bool, at date: Date) {
        // Topics can begin with "/" (an empty first level) and contain empty levels; keep them visible.
        let levels = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        Self.insert(levels[...], parent: nil, into: &roots, payload: payload, retained: retained, date: date)
    }

    public mutating func record(_ event: MQTTSessionEvent, at date: Date) {
        guard case .publish(let publish) = event.packet, let topic = event.resolvedTopic ?? (publish.topic.isEmpty ? nil : publish.topic) else {
            return
        }
        record(topic: topic, payload: publish.payload, retained: publish.retain, at: date)
    }

    /// The node for an exact topic, if seen.
    public func node(for topic: String) -> TopicNode? {
        var nodes = roots
        var found: TopicNode?
        var path = ""
        for (index, level) in topic.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
            path = index == 0 ? String(level) : path + "/" + level
            guard let match = nodes.first(where: { $0.id == path }) else { return nil }
            found = match
            nodes = match.children
        }
        return found
    }

    private static func insert(_ levels: ArraySlice<String>, parent: String?, into nodes: inout [TopicNode],
                               payload: [UInt8], retained: Bool, date: Date) {
        guard let level = levels.first else { return }
        let id = parent.map { $0 + "/" + level } ?? level
        var index = nodes.firstIndex { $0.id == id }
        if index == nil {
            nodes.append(TopicNode(id: id, name: level.isEmpty ? "(empty)" : level))
            nodes.sort { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
            index = nodes.firstIndex { $0.id == id }
        }
        let rest = levels.dropFirst()
        nodes[index!].totalCount += 1
        if rest.isEmpty {
            nodes[index!].messageCount += 1
            nodes[index!].lastPayload = payload
            nodes[index!].lastUpdated = date
            nodes[index!].retained = retained
        } else {
            insert(rest, parent: id, into: &nodes[index!].children, payload: payload, retained: retained, date: date)
        }
    }
}
