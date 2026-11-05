import Foundation
import Licensing

/// The short "this needs Pro" prompt shown when a free-tier limit is reached. Whatever the user
/// already had keeps working; the prompt only explains why the new thing didn't take effect.
public struct ProLimitPrompt: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// A rule or script was turned on past the limit for its kind, and was switched off again.
        case ruleLimit(RuleKind, limit: Int)
        /// This session's free replays are used up.
        case replayLimit(Int)
        /// The message was changed after it was filled in from a capture.
        case editedReplay
        /// A new message, not a captured one.
        case newMessage
        /// A message from a saved session rather than the one recording now.
        case savedSessionReplay
    }

    public enum RuleKind: String, Sendable {
        case breakpoint, mapLocal, mapRemote, rewrite, mqttRewrite, script

        /// "Map Local rule", "script"… for sentences.
        public var noun: String {
            switch self {
            case .breakpoint: "breakpoint"
            case .mapLocal: "Map Local rule"
            case .mapRemote: "Map Remote rule"
            case .rewrite: "Rewrite rule"
            case .mqttRewrite: "MQTT Rewrite rule"
            case .script: "script"
            }
        }

        public var pluralNoun: String {
            switch self {
            case .breakpoint: "breakpoints"
            case .mapLocal: "Map Local rules"
            case .mapRemote: "Map Remote rules"
            case .rewrite: "Rewrite rules"
            case .mqttRewrite: "MQTT Rewrite rules"
            case .script: "scripts"
            }
        }
    }

    public let id: UUID
    public let reason: Reason

    public init(_ reason: Reason) {
        id = UUID()
        self.reason = reason
    }

    public var title: String {
        switch reason {
        case .ruleLimit(let kind, let limit):
            limit == 1 ? "Wiretide Free runs 1 \(kind.noun) at a time" : "Wiretide Free runs \(limit) \(kind.pluralNoun) at a time"
        case .replayLimit(let limit):
            "You’ve used this session’s \(limit) free replays"
        case .editedReplay:
            "Editing before you resend is part of Pro"
        case .newMessage:
            "Writing new MQTT messages is part of Pro"
        case .savedSessionReplay:
            "Replaying saved sessions is part of Pro"
        }
    }

    public var message: String {
        switch reason {
        case .ruleLimit(let kind, let limit):
            let others = limit == 1 ? "the one that’s on" : "one that’s on"
            return "The new \(kind.noun) is saved and switched off. Turn off \(others) to use it instead, or get Pro to run as many as you need."
        case .replayLimit:
            return "Free resends captured messages exactly as they arrived. Starting a new session gives you more, and Pro replays without limits."
        case .editedReplay:
            return "Free resends captured messages exactly as they arrived. Pro lets you change the topic, payload, QoS and properties first."
        case .newMessage:
            return "Free can resend messages from the live capture. Pro writes new messages from scratch and sends them as often as you like."
        case .savedSessionReplay:
            return "Free resends messages from the session recording now. Pro replays anything you’ve saved."
        }
    }
}

/// Which enabled rules take effect under a free-tier limit, and turning back ones that go past it.
/// Rules count per group (a kind of rule), in list order, so the rules that were already on keep
/// working and a downgrade never silently changes which ones run.
enum RuleLimit {
    /// The ids of the enabled items that take effect: with a limit, the first `limit` enabled items
    /// of each group in list order; without one, every enabled item.
    static func running<Item: Identifiable, Group: Hashable>(_ items: [Item], limit: Int?, isEnabled: (Item) -> Bool,
                                                            group: (Item) -> Group) -> Set<Item.ID> {
        var counts: [Group: Int] = [:]
        var ids = Set<Item.ID>()
        for item in items where isEnabled(item) {
            let key = group(item)
            if let limit, counts[key, default: 0] >= limit { continue }
            counts[key, default: 0] += 1
            ids.insert(item.id)
        }
        return ids
    }

    /// Switches off items that this change turned on (added enabled, duplicated, or enabled) while
    /// their group was already at the limit. Items that were on before are left alone, even past the
    /// limit (after a downgrade), so nothing the user had is switched off for them.
    /// - Returns: the group of the last item switched off, or nil when nothing was.
    static func refuse<Item: Identifiable, Group: Hashable>(old: [Item], new: inout [Item], limit: Int?,
                                                           isEnabled: WritableKeyPath<Item, Bool>,
                                                           group: (Item) -> Group) -> Group? {
        guard let limit else { return nil }
        let wasOn = Set(old.lazy.filter { $0[keyPath: isEnabled] }.map(\.id))
        var counts: [Group: Int] = [:]
        for item in new where item[keyPath: isEnabled] { counts[group(item), default: 0] += 1 }
        var refused: Group?
        for index in new.indices where new[index][keyPath: isEnabled] && !wasOn.contains(new[index].id) {
            let key = group(new[index])
            guard counts[key, default: 0] > limit else { continue }
            new[index][keyPath: isEnabled] = false
            counts[key, default: 0] -= 1
            refused = key
        }
        return refused
    }
}
