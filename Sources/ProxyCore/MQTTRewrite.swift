import Foundation
import MQTTCore

/// A rewrite rule for MQTT PUBLISH packets relayed by the forwarders. Packets whose topic matches
/// the filter, in the chosen direction, have their topic, payload or retain flag changed before the
/// other side sees them.
public struct MQTTRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Sendable {
        case both, clientToBroker, brokerToClient

        public var title: String {
            switch self {
            case .both: "Both directions"
            case .clientToBroker: "App → broker"
            case .brokerToClient: "Broker → app"
            }
        }

        func includes(_ direction: MQTTDirection) -> Bool {
            switch self {
            case .both: true
            case .clientToBroker: direction == .clientToBroker
            case .brokerToClient: direction == .brokerToClient
            }
        }
    }

    public var id: UUID
    public var isEnabled: Bool
    public var name: String
    /// An MQTT topic filter: `+` matches one level, a trailing `#` any number.
    public var topicFilter: String
    public var direction: Direction
    public var operations: [MQTTRewriteOperation]

    public init(id: UUID = UUID(), isEnabled: Bool = true, name: String = "", topicFilter: String,
                direction: Direction = .both, operations: [MQTTRewriteOperation] = []) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.topicFilter = topicFilter
        self.direction = direction
        self.operations = operations
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return topicFilter.isEmpty ? "Untitled rule" : topicFilter
    }

    public func matches(topic: String, direction: MQTTDirection) -> Bool {
        isEnabled && self.direction.includes(direction) && MQTTTopicFilter.matches(topicFilter, topic: topic)
    }

    private enum CodingKeys: String, CodingKey { case id, isEnabled, name, topicFilter, direction, operations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        topicFilter = try container.decodeIfPresent(String.self, forKey: .topicFilter) ?? ""
        direction = try container.decodeIfPresent(Direction.self, forKey: .direction) ?? .both
        operations = try container.decodeIfPresent([MQTTRewriteOperation].self, forKey: .operations) ?? []
    }
}

/// One edit to a PUBLISH:
///
/// | target  | set                          | remove          | replace                         |
/// |---------|------------------------------|-----------------|---------------------------------|
/// | topic   | topic = value                | –               | find → value in the topic       |
/// | payload | payload = value              | empty payload   | find → value in the payload text |
/// | json    | key path `name` = JSON value | key path `name` | –                               |
/// | retain  | retain flag = value (true/false) | –           | –                               |
public struct MQTTRewriteOperation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case topic, payload, json, retain

        public var title: String {
            switch self {
            case .topic: "Topic"
            case .payload: "Payload"
            case .json: "JSON value"
            case .retain: "Retain"
            }
        }

        public var actions: [RewriteOperation.Action] {
            switch self {
            case .topic: [.set, .replace]
            case .payload: [.set, .remove, .replace]
            case .json: [.set, .remove]
            case .retain: [.set]
            }
        }
    }

    public var id: UUID
    public var target: Target
    public var action: RewriteOperation.Action
    /// JSON key path for `json`.
    public var name: String
    public var value: String
    public var find: String
    public var useRegex: Bool

    public init(id: UUID = UUID(), target: Target, action: RewriteOperation.Action = .set, name: String = "",
                value: String = "", find: String = "", useRegex: Bool = false) {
        self.id = id
        self.target = target
        self.action = action
        self.name = name
        self.value = value
        self.find = find
        self.useRegex = useRegex
    }

    private enum CodingKeys: String, CodingKey { case id, target, action, name, value, find, useRegex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .payload
        action = try container.decodeIfPresent(RewriteOperation.Action.self, forKey: .action) ?? .set
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
    }
}

/// MQTT topic filter matching (`+` one level, `#` the rest, including the parent level).
public enum MQTTTopicFilter {
    public static func matches(_ filter: String, topic: String) -> Bool {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return false }
        let filterLevels = filter.split(separator: "/", omittingEmptySubsequences: false)
        let topicLevels = topic.split(separator: "/", omittingEmptySubsequences: false)
        // Topics starting with $ (broker internals) only match filters that name them explicitly.
        if topic.hasPrefix("$"), let first = filterLevels.first, first == "#" || first == "+" { return false }
        for (index, level) in filterLevels.enumerated() {
            if level == "#" { return index == filterLevels.count - 1 }
            guard index < topicLevels.count else { return false }
            if level != "+" && level != topicLevels[index] { return false }
        }
        return filterLevels.count == topicLevels.count
    }
}

public enum MQTTRewriter {
    /// Applies the matching rules to a PUBLISH. `resolvedTopic` is the topic after any v5 alias.
    /// Returns the new packet, its topic for display, and the names of the rules that changed it;
    /// nil when nothing changed.
    public static func rewrite(_ publish: MQTTPublish, resolvedTopic: String, direction: MQTTDirection,
                               rules: [MQTTRule]) -> (publish: MQTTPublish, topic: String, applied: [String])? {
        var packet = publish
        var topic = resolvedTopic
        var applied: [String] = []
        for rule in rules where rule.matches(topic: resolvedTopic, direction: direction) {
            let before = (packet, topic)
            for operation in rule.operations {
                apply(operation, to: &packet, topic: &topic)
            }
            if before.0 != packet || before.1 != topic { applied.append(rule.displayName) }
        }
        guard !applied.isEmpty else { return nil }
        return (packet, topic, applied)
    }

    static func apply(_ operation: MQTTRewriteOperation, to publish: inout MQTTPublish, topic: inout String) {
        switch operation.target {
        case .topic:
            let new: String
            switch operation.action {
            case .set: new = operation.value.trimmingCharacters(in: .whitespaces)
            case .replace: new = TextReplace.replace(in: topic, find: operation.find, with: operation.value, regex: operation.useRegex)
            case .remove: return
            }
            // Publishing to a wildcard or empty topic is a protocol error; keep the old one.
            guard !new.isEmpty, !new.contains("+"), !new.contains("#") else { return }
            topic = new
            // An alias-only packet (empty topic on the wire) keeps using its alias: the packet that set
            // the alias was rewritten the same way, so the receiver already maps it to the new topic.
            if !publish.topic.isEmpty || publish.topicAlias == nil { publish.topic = new }
        case .payload:
            var headers: [CapturedHeader] = []
            let asOperation = RewriteOperation(target: .body, action: operation.action, value: operation.value,
                                               find: operation.find, useRegex: operation.useRegex)
            BodyRewrite.apply(asOperation, body: &publish.payload, headers: &headers)
        case .json:
            var headers: [CapturedHeader] = []
            let asOperation = RewriteOperation(target: .json, action: operation.action, name: operation.name, value: operation.value)
            BodyRewrite.applyJSON(asOperation, body: &publish.payload, headers: &headers)
        case .retain:
            switch operation.value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": publish.retain = true
            case "false", "0", "no", "off": publish.retain = false
            default: break
            }
        }
    }
}

/// One direction-aware relay of an MQTT connection: splits each direction's bytes into packets,
/// rewrites PUBLISH packets that match a rule, runs scripts on them, and records what was actually forwarded.
/// Confined to one event loop.
///
/// Bytes are forwarded packet by packet, so a packet is held only until its last byte arrives.
/// If the stream stops decoding as MQTT, everything is relayed untouched from then on.
final class MQTTRelay {
    let connectionID = UUID()
    private let sink: CaptureSink
    private let broker: String
    private let rules: LiveRules?
    private let scripts: LiveScripts?
    private var session = MQTTSession()
    private var failed = false
    /// Bytes received per direction that haven't been forwarded yet (an incomplete packet).
    private var pending: [MQTTDirection: [UInt8]] = [:]

    init(sink: CaptureSink, broker: String, rules: LiveRules?, scripts: LiveScripts? = nil) {
        self.sink = sink
        self.broker = broker
        self.rules = rules
        self.scripts = scripts
    }

    /// Takes bytes read from one side and returns the bytes to write to the other.
    func relay(_ bytes: [UInt8], from direction: MQTTDirection) -> [UInt8] {
        // After a decoding failure everything passes through, starting with whatever this direction
        // still held of an incomplete packet.
        guard !failed else { return takePending(from: direction) + bytes }
        pending[direction, default: []] += bytes
        let events: [MQTTSessionEvent]
        do {
            events = try session.receive(bytes, from: direction)
        } catch {
            failed = true
            sink.record(.mqttDecodingFailed(connectionID: connectionID, reason: String(describing: error)))
            return pending.removeValue(forKey: direction) ?? []
        }
        guard !events.isEmpty else { return [] }

        let consumed = events.reduce(0) { $0 + $1.frame.rawBytes.count }
        if var unsent = pending[direction] {
            unsent.removeFirst(min(consumed, unsent.count))
            pending[direction] = unsent
        }
        let active = rules?.mqtt ?? []
        let scripting = scripts?.snapshot
        let now = Date()
        var output: [UInt8] = []
        output.reserveCapacity(consumed)
        for var event in events {
            var applied: [String]?
            var scripted: [String]?
            if case .publish(let original) = event.packet {
                var publish = original
                let originalTopic = event.resolvedTopic ?? original.topic
                var topic = originalTopic
                if !active.isEmpty,
                   let rewritten = MQTTRewriter.rewrite(publish, resolvedTopic: topic, direction: direction, rules: active) {
                    publish = rewritten.publish
                    topic = rewritten.topic
                    applied = rewritten.applied
                }
                // Scripts match the topic as the rules left it, and see the packet after the rules.
                if let scripting, case let matched = scripting.scripts(topic: topic, direction: direction), !matched.isEmpty {
                    let result = ScriptRunner.runPublish(publish, resolvedTopic: topic, direction: direction, broker: broker,
                                                         clientID: session.clientIdentifier, scripts: matched, engine: scripting.engine)
                    scripts?.log(result.logs)
                    if !result.applied.isEmpty {
                        publish = result.publish
                        topic = result.topic
                        scripted = result.applied
                    }
                }
                if publish != original || topic != originalTopic {
                    if let bytes = try? MQTTPacketEncoder.encode(.publish(publish), version: event.version) {
                        event.frame = MQTTFrame(packet: .publish(publish), rawBytes: bytes)
                        event.resolvedTopic = topic
                    } else {
                        // The change couldn't be encoded, so the original is what goes on.
                        applied = nil
                        scripted = nil
                    }
                }
            }
            output += event.frame.rawBytes
            sink.record(.mqtt(MQTTCaptureEvent(connectionID: connectionID, timestamp: now, broker: broker, event: event,
                                               rewrittenBy: applied, scriptedBy: scripted)))
        }
        return output
    }

    /// Hands back the bytes of an incomplete packet held for `direction`, for a caller that stops relaying.
    func takePending(from direction: MQTTDirection) -> [UInt8] {
        pending.removeValue(forKey: direction) ?? []
    }
}
