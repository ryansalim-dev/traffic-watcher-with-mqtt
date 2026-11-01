import Foundation

/// Where a breakpoint stops an exchange.
public struct BreakpointStages: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Before the request goes to the server.
    public static let request = BreakpointStages(rawValue: 1 << 0)
    /// Before the server's response goes back to the client.
    public static let response = BreakpointStages(rawValue: 1 << 1)
}

/// A request held at a breakpoint, as the user edits it.
public struct HTTPRequestDraft: Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [CapturedHeader]
    public var body: [UInt8]

    public init(method: String, url: String, headers: [CapturedHeader], body: [UInt8]) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A response held at a breakpoint, as the user edits it.
public struct HTTPResponseDraft: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [CapturedHeader]
    public var body: [UInt8]

    public init(statusCode: Int, headers: [CapturedHeader], body: [UInt8]) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// What the user decided at a breakpoint.
public enum BreakpointResolution<Value: Sendable>: Sendable {
    /// Carry on with this (possibly edited) value.
    case proceed(Value)
    /// Drop the exchange: the client gets an error response and the server never sees the request
    /// (or its response is thrown away).
    case abort
}

extension BreakpointResolution: Equatable where Value: Equatable {}

/// Decides which exchanges stop and lets the user edit them. The proxy calls `stages` on its event
/// loop for every request, so it must be quick; the edit calls may take as long as the user does.
public protocol HTTPBreakpointHandler: AnyObject, Sendable {
    func stages(method: String, url: String) -> BreakpointStages
    func editRequest(_ request: HTTPRequestDraft) async -> BreakpointResolution<HTTPRequestDraft>
    func editResponse(_ response: HTTPResponseDraft, for request: HTTPRequestDraft) async -> BreakpointResolution<HTTPResponseDraft>
}

/// A user-defined breakpoint: requests whose method and URL match stop at the chosen stages.
public struct BreakpointRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    /// URL pattern; `*` matches any run of characters. Without a scheme it matches http and https.
    /// Matching ignores case and a trailing `/`.
    public var pattern: String
    /// Upper-case HTTP method, or nil for any.
    public var method: String?
    public var stages: BreakpointStages

    public init(id: UUID = UUID(), isEnabled: Bool = true, pattern: String, method: String? = nil,
                stages: BreakpointStages = [.request, .response]) {
        self.id = id
        self.isEnabled = isEnabled
        self.pattern = pattern
        self.method = method
        self.stages = stages
    }

    public func matches(method: String, url: String) -> Bool {
        guard isEnabled, !stages.isEmpty else { return false }
        if let ruleMethod = self.method, !ruleMethod.isEmpty, ruleMethod.uppercased() != method.uppercased() { return false }
        return Self.glob(pattern, matches: url)
    }

    /// Wildcard match of `pattern` against the whole of `url`.
    static func glob(_ pattern: String, matches url: String) -> Bool {
        var pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return false }
        if !pattern.contains("://") { pattern = "*://" + pattern }
        var text = url.lowercased()
        if pattern.hasSuffix("/") { pattern.removeLast() }
        if text.hasSuffix("/") { text.removeLast() }
        return wildcard(Array(pattern.utf8), Array(text.utf8))
    }

    /// Iterative `*` matching with backtracking to the last star; linear in practice.
    private static func wildcard(_ p: [UInt8], _ t: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        var pi = 0, ti = 0
        var lastStar: Int?
        var resume = 0
        while ti < t.count {
            if pi < p.count, p[pi] == star {
                lastStar = pi
                resume = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if let star = lastStar {
                pi = star + 1
                resume += 1
                ti = resume
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == star { pi += 1 }
        return pi == p.count
    }
}

extension Array where Element == BreakpointRule {
    /// The stages of every enabled rule matching this request, combined.
    public func stages(method: String, url: String) -> BreakpointStages {
        reduce(into: []) { result, rule in
            if rule.matches(method: method, url: url) { result.formUnion(rule.stages) }
        }
    }
}
