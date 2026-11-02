import Foundation
import MQTTCore
import Observation
import ProxyCore

/// What the map and rewrite rules window saves between launches.
public struct RewriteSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var http: [HTTPRule]
    public var mqtt: [MQTTRule]

    public init(isEnabled: Bool = true, http: [HTTPRule] = [], mqtt: [MQTTRule] = []) {
        self.isEnabled = isEnabled
        self.http = http
        self.mqtt = mqtt
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, http, mqtt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        http = try container.decodeIfPresent([HTTPRule].self, forKey: .http) ?? []
        mqtt = try container.decodeIfPresent([MQTTRule].self, forKey: .mqtt) ?? []
    }
}

/// Owns the Map Local, Map Remote and Rewrite rules (Pro). Edits reach the proxy at once through
/// `rules`; without Pro, or with the master switch off, the rules are kept but change nothing.
@MainActor
@Observable
public final class RewriteCenter {
    public var httpRules: [HTTPRule] {
        didSet { changed() }
    }
    public var mqttRules: [MQTTRule] {
        didSet { changed() }
    }
    /// The master switch in the toolbar and the rules window.
    public var isEnabled: Bool {
        didSet { changed() }
    }
    /// Whether the license allows map and rewrite.
    public var isAllowed = false {
        didSet { push() }
    }
    /// The rule open in the rules window.
    public var selection: RuleSelection?
    /// Shows the rules window; set by the timeline's context menu.
    public var isPresented = false

    /// Hand this to the capture engine (or use the engine's own and pass it here).
    public let rules: LiveRules
    private let save: ((RewriteSettings) -> Void)?

    public enum RuleSelection: Hashable, Sendable {
        case http(UUID)
        case mqtt(UUID)
    }

    public init(settings: RewriteSettings = .init(), rules: LiveRules = LiveRules(), save: ((RewriteSettings) -> Void)? = nil) {
        httpRules = settings.http
        mqttRules = settings.mqtt
        isEnabled = settings.isEnabled
        self.rules = rules
        self.save = save
        push()
    }

    /// True when enabled rules actually change traffic.
    public var isActive: Bool { isEnabled && isAllowed }

    /// Enabled rules, for the toolbar's count.
    public var enabledCount: Int { httpRules.filter(\.isEnabled).count + mqttRules.filter(\.isEnabled).count }

    public var settings: RewriteSettings { RewriteSettings(isEnabled: isEnabled, http: httpRules, mqtt: mqttRules) }

    private func changed() {
        push()
        save?(settings)
    }

    private func push() {
        if isActive {
            rules.update(http: httpRules, mqtt: mqttRules)
        } else {
            rules.update(http: [], mqtt: [])
        }
    }

    // MARK: Adding rules

    /// A new, empty rule of `kind`, selected.
    @discardableResult
    public func addHTTPRule(kind: HTTPRule.Kind, pattern: String = "", method: String? = nil) -> HTTPRule {
        var rule = HTTPRule(pattern: pattern, method: method, kind: kind)
        if kind == .rewrite {
            rule.operations = [RewriteOperation(phase: .response, target: .header, action: .set, name: "X-Wiretide", value: "rewritten")]
        }
        httpRules.append(rule)
        selection = .http(rule.id)
        return rule
    }

    @discardableResult
    public func addMQTTRule(topicFilter: String = "") -> MQTTRule {
        let rule = MQTTRule(topicFilter: topicFilter, operations: [MQTTRewriteOperation(target: .payload, action: .replace)])
        mqttRules.append(rule)
        selection = .mqtt(rule.id)
        return rule
    }

    /// Map Local for this exchange's URL, answering with the response that was captured, so it can be edited into a mock.
    @discardableResult
    public func addMapLocal(from exchange: HTTPExchange) -> HTTPRule {
        let skipped: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection", "date", "keep-alive"]
        let headers = exchange.responseHeaders.filter { !skipped.contains($0.name.lowercased()) }
        let body = String(bytes: exchange.responseBody, encoding: .utf8).map { text in
            Formatting.prettyJSON(exchange.responseBody) ?? text
        } ?? ""
        var rule = HTTPRule(name: "Mock \(Self.shortPath(exchange.url))", pattern: BreakpointCenter.pattern(for: exchange.url),
                            method: exchange.method, kind: .mapLocal)
        rule.mapLocal = MapLocalResponse(statusCode: exchange.statusCode ?? 200,
                                         headers: headers.isEmpty ? MapLocalResponse().headers : headers,
                                         body: body)
        httpRules.append(rule)
        selection = .http(rule.id)
        return rule
    }

    /// Map Remote for this exchange's host: everything on it goes to another server, paths kept.
    @discardableResult
    public func addMapRemote(from exchange: HTTPExchange) -> HTTPRule {
        let origin = SplitURLHelper.origin(of: exchange.url) ?? exchange.url
        var rule = HTTPRule(pattern: origin + "/*", kind: .mapRemote)
        rule.mapRemote = MapRemoteDestination(url: "http://localhost:3000")
        httpRules.append(rule)
        selection = .http(rule.id)
        return rule
    }

    /// A Rewrite rule for this exchange's URL (query dropped), with a header edit to start from.
    @discardableResult
    public func addRewrite(from exchange: HTTPExchange) -> HTTPRule {
        addHTTPRule(kind: .rewrite, pattern: BreakpointCenter.pattern(for: exchange.url), method: exchange.method)
    }

    public func remove(_ selection: RuleSelection) {
        switch selection {
        case .http(let id): httpRules.removeAll { $0.id == id }
        case .mqtt(let id): mqttRules.removeAll { $0.id == id }
        }
        if self.selection == selection { self.selection = nil }
    }

    /// A copy of the rule right after it, selected.
    public func duplicate(_ selection: RuleSelection) {
        switch selection {
        case .http(let id):
            guard let index = httpRules.firstIndex(where: { $0.id == id }) else { return }
            var copy = httpRules[index]
            copy.id = UUID()
            copy.name = copy.name.isEmpty ? "" : copy.name + " copy"
            httpRules.insert(copy, at: index + 1)
            self.selection = .http(copy.id)
        case .mqtt(let id):
            guard let index = mqttRules.firstIndex(where: { $0.id == id }) else { return }
            var copy = mqttRules[index]
            copy.id = UUID()
            copy.name = copy.name.isEmpty ? "" : copy.name + " copy"
            mqttRules.insert(copy, at: index + 1)
            self.selection = .mqtt(copy.id)
        }
    }

    static func shortPath(_ url: String) -> String {
        let withoutScheme = url.components(separatedBy: "://").last ?? url
        var path = withoutScheme.firstIndex(of: "/").map { String(withoutScheme[$0...]) } ?? "/"
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return path
    }

    // MARK: Previews for the editor

    /// URLs from `rows` that the rule matches, newest first (for "matches 12 requests").
    public static func matchingURLs(_ rule: HTTPRule, in rows: [TrafficRow], limit: Int = 200) -> [String] {
        var urls: [String] = []
        var enabled = rule
        enabled.isEnabled = true
        for row in rows.reversed() {
            guard case .httpExchange(let exchange) = row.event else { continue }
            if enabled.matches(method: exchange.method, url: exchange.url) {
                urls.append(exchange.url)
                if urls.count >= limit { break }
            }
        }
        return urls
    }

    /// Topics from `rows` that the rule matches, newest first, without repeats.
    public static func matchingTopics(_ rule: MQTTRule, in rows: [TrafficRow], limit: Int = 200) -> [String] {
        var seen: Set<String> = []
        var topics: [String] = []
        for row in rows.reversed() {
            guard case .mqtt(let capture) = row.event, case .publish = capture.event.packet,
                  let topic = capture.event.resolvedTopic, MQTTTopicFilter.matches(rule.topicFilter, topic: topic),
                  seen.insert(topic).inserted else { continue }
            topics.append(topic)
            if topics.count >= limit { break }
        }
        return topics
    }
}

enum SplitURLHelper {
    /// `scheme://authority` of an absolute URL.
    static func origin(of url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        return String(url[..<end])
    }
}
