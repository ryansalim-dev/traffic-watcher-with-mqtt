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
    /// The latest messages published exactly to this topic, oldest first (at most `historyLimit`).
    public var history: [TopicSample] = []

    public static let historyLimit = 300

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
            nodes[index!].history.append(TopicSample(date: date, payload: payload))
            if nodes[index!].history.count > TopicNode.historyLimit {
                nodes[index!].history.removeFirst(nodes[index!].history.count - TopicNode.historyLimit)
            }
        } else {
            insert(rest, parent: id, into: &nodes[index!].children, payload: payload, retained: retained, date: date)
        }
    }
}

/// One message published to a topic.
public struct TopicSample: Equatable, Sendable {
    public var date: Date
    public var payload: [UInt8]
}

/// A numeric JSON field charted over time, such as `celsius` from `{"celsius":21.6}`.
public struct NumericSeries: Equatable, Sendable, Identifiable {
    public var field: String
    public var points: [Point]
    public var id: String { field }

    public struct Point: Equatable, Sendable {
        public var date: Date
        public var value: Double
    }

    public var latest: Double? { points.last?.value }
    public var minimum: Double? { points.map(\.value).min() }
    public var maximum: Double? { points.map(\.value).max() }

    /// Top-level numeric fields of JSON object payloads (and bare numeric payloads, as "value"),
    /// in the order they first appear. Fields with fewer than two points are left out.
    public static func series(from samples: [TopicSample]) -> [NumericSeries] {
        var order: [String] = []
        var points: [String: [Point]] = [:]
        for sample in samples {
            for (field, value) in numericFields(sample.payload) {
                if points[field] == nil { order.append(field) }
                points[field, default: []].append(Point(date: sample.date, value: value))
            }
        }
        return order.compactMap { field in
            guard let values = points[field], values.count >= 2 else { return nil }
            return NumericSeries(field: field, points: values.sorted { $0.date < $1.date })
        }
    }

    static func numericFields(_ payload: [UInt8]) -> [(String, Double)] {
        guard !payload.isEmpty, payload.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(payload), options: [.fragmentsAllowed]) else { return [] }
        if let dictionary = object as? [String: Any] {
            // JSONSerialization loses key order, so sort for stable output.
            return dictionary.keys.sorted().compactMap { key in number(dictionary[key]).map { (key, $0) } }
        }
        return number(object).map { [("value", $0)] } ?? []
    }

    private static func number(_ value: Any?) -> Double? {
        // Booleans bridge to NSNumber too; skip them.
        #if canImport(Darwin)
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
        #else
        if value is Bool { return nil }
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
        #endif
    }
}
