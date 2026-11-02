import Foundation

// MARK: HTTP rules

/// A map or rewrite rule for HTTP and HTTPS. Requests whose method and URL match are answered from
/// a local response (Map Local), sent to another server (Map Remote), or edited on the way through
/// (Rewrite). Every kind keeps its own settings, so switching kinds in the editor loses nothing.
public struct HTTPRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case mapLocal, mapRemote, rewrite

        public var title: String {
            switch self {
            case .mapLocal: "Map Local"
            case .mapRemote: "Map Remote"
            case .rewrite: "Rewrite"
            }
        }
    }

    public var id: UUID
    public var isEnabled: Bool
    /// Shown in the rules list and on exchanges the rule changed. Empty means "use the pattern".
    public var name: String
    /// URL pattern, as for breakpoints: `*` matches anything; without a scheme it matches http and https.
    public var pattern: String
    /// Upper-case HTTP method, or nil for any.
    public var method: String?
    public var kind: Kind
    public var mapLocal: MapLocalResponse
    public var mapRemote: MapRemoteDestination
    public var operations: [RewriteOperation]

    public init(id: UUID = UUID(), isEnabled: Bool = true, name: String = "", pattern: String, method: String? = nil,
                kind: Kind, mapLocal: MapLocalResponse = .init(), mapRemote: MapRemoteDestination = .init(),
                operations: [RewriteOperation] = []) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.pattern = pattern
        self.method = method
        self.kind = kind
        self.mapLocal = mapLocal
        self.mapRemote = mapRemote
        self.operations = operations
    }

    /// The name, or the pattern when the rule has none.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return pattern.isEmpty ? "Untitled rule" : pattern
    }

    public func matches(method: String, url: String) -> Bool {
        guard isEnabled else { return false }
        if let ruleMethod = self.method, !ruleMethod.isEmpty, ruleMethod.uppercased() != method.uppercased() { return false }
        return URLPattern.matches(pattern, url: url)
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, name, pattern, method, kind, mapLocal, mapRemote, operations
    }

    /// Missing keys keep their defaults, so rules saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        method = try container.decodeIfPresent(String.self, forKey: .method)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .rewrite
        mapLocal = try container.decodeIfPresent(MapLocalResponse.self, forKey: .mapLocal) ?? .init()
        mapRemote = try container.decodeIfPresent(MapRemoteDestination.self, forKey: .mapRemote) ?? .init()
        operations = try container.decodeIfPresent([RewriteOperation].self, forKey: .operations) ?? []
    }
}

/// The response a Map Local rule answers with. The body is either typed in or read from a file on
/// every request, so editing the file changes the next response without touching the rule.
public struct MapLocalResponse: Codable, Equatable, Hashable, Sendable {
    public var statusCode: Int
    public var headers: [CapturedHeader]
    public var body: String
    /// When set, the body comes from this file instead of `body`.
    public var filePath: String?

    public init(statusCode: Int = 200,
                headers: [CapturedHeader] = [CapturedHeader(name: "Content-Type", value: "application/json")],
                body: String = "", filePath: String? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.filePath = filePath
    }

    /// Builds the response, reading the file if there is one. A file that can't be read gives a
    /// 500 that says why, so a broken mock is visible in the timeline rather than silently real.
    public func response(readFile: (String) throws -> [UInt8]) -> HTTPResponseDraft {
        var headers = self.headers
        let body: [UInt8]
        if let path = filePath?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            do {
                body = try readFile(path)
            } catch {
                let message = "Map Local couldn't read \(path): \(error.localizedDescription)"
                return HTTPResponseDraft(statusCode: 500, headers: [CapturedHeader(name: "Content-Type", value: "text/plain; charset=utf-8")],
                                         body: Array(message.utf8))
            }
            if !headers.contains(where: { $0.name.lowercased() == "content-type" }), let type = Self.contentType(forPath: path) {
                headers.append(CapturedHeader(name: "Content-Type", value: type))
            }
        } else {
            body = Array(self.body.utf8)
        }
        headers.removeAll { ["content-length", "content-encoding", "transfer-encoding"].contains($0.name.lowercased()) }
        return HTTPResponseDraft(statusCode: statusCode, headers: headers, body: body)
    }

    static func contentType(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let types: [String: String] = [
            "json": "application/json", "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
            "txt": "text/plain; charset=utf-8", "xml": "application/xml", "js": "text/javascript", "css": "text/css",
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
            "svg": "image/svg+xml", "pdf": "application/pdf", "csv": "text/csv", "bin": "application/octet-stream",
        ]
        return types[ext]
    }

    /// Reads a file the way Map Local does; `~` means the home folder.
    public static func readFile(_ path: String) throws -> [UInt8] {
        let expanded = (path as NSString).expandingTildeInPath
        return Array(try Data(contentsOf: URL(fileURLWithPath: expanded)))
    }
}

/// Where a Map Remote rule sends matching requests.
///
/// - `https://staging.example.com` (no path, or just `/`) keeps the original path and query and swaps
///   scheme, host and port.
/// - `http://localhost:3000/api/v2/*` replaces the path too; each `*` is filled with what the
///   pattern's `*`s matched, in order. The original query is kept unless the destination has one.
public struct MapRemoteDestination: Codable, Equatable, Hashable, Sendable {
    public var url: String
    /// Send the original Host header instead of the destination's (for virtual hosts behind one address).
    public var preserveHostHeader: Bool

    public init(url: String = "", preserveHostHeader: Bool = false) {
        self.url = url
        self.preserveHostHeader = preserveHostHeader
    }

    /// The URL `original` is sent to, or nil when the destination isn't an absolute http(s) URL.
    public func destination(for original: String, pattern: String) -> String? {
        let captures = URLPattern.captures(pattern, url: original) ?? []
        let target = URLPattern.substitute(captures, into: url.trimmingCharacters(in: .whitespaces))
        guard let destination = SplitURL(target), let source = SplitURL(original) else { return nil }
        var result = destination.origin
        if destination.path.isEmpty || destination.path == "/" {
            result += source.path.isEmpty ? "/" : source.path
        } else {
            result += destination.path
        }
        if let query = destination.query ?? source.query { result += "?" + query }
        return result
    }
}

/// An absolute URL cut into origin (`scheme://authority`), path and query, without normalizing anything.
struct SplitURL {
    var origin: String
    var path: String
    var query: String?

    init?(_ url: String) {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        var rest = url[schemeEnd.upperBound...]
        if let fragment = rest.firstIndex(of: "#") { rest = rest[..<fragment] }
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        guard authorityEnd > rest.startIndex else { return nil }
        origin = "\(scheme)://\(rest[..<authorityEnd])"
        let tail = rest[authorityEnd...]
        if let mark = tail.firstIndex(of: "?") {
            path = String(tail[..<mark])
            query = String(tail[tail.index(after: mark)...])
        } else {
            path = String(tail)
            query = nil
        }
    }
}

/// One edit a Rewrite rule makes. Which fields are used depends on `target` and `action`:
///
/// | target  | set                          | remove           | replace                              |
/// |---------|------------------------------|------------------|--------------------------------------|
/// | url     | whole URL = value            | –                | find → value in the URL              |
/// | method  | method = value               | –                | –                                    |
/// | header  | header `name` = value        | header `name`    | find → value in `name`'s values (all headers when empty) |
/// | query   | parameter `name` = value     | parameter `name` | find → value in the query string     |
/// | body    | body = value                 | empty body       | find → value in the body text        |
/// | json    | key path `name` = JSON value | key path `name`  | –                                    |
/// | status  | status = value               | –                | –                                    |
///
/// `url`, `method` and `query` only apply to requests, `status` only to responses.
public struct RewriteOperation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Phase: String, Codable, CaseIterable, Sendable { case request, response }
    public enum Target: String, Codable, CaseIterable, Sendable {
        case url, method, header, query, body, json, status

        public var title: String {
            switch self {
            case .url: "URL"
            case .method: "Method"
            case .header: "Header"
            case .query: "Query"
            case .body: "Body"
            case .json: "JSON value"
            case .status: "Status"
            }
        }

        public func applies(to phase: Phase) -> Bool {
            switch self {
            case .url, .method, .query: phase == .request
            case .status: phase == .response
            case .header, .body, .json: true
            }
        }

        /// The actions that make sense for this target.
        public var actions: [Action] {
            switch self {
            case .url: [.set, .replace]
            case .method, .status: [.set]
            case .header, .query, .body: [.set, .remove, .replace]
            case .json: [.set, .remove]
            }
        }

        /// True when the operation addresses something by name (a header, parameter or key path).
        public var usesName: Bool { self == .header || self == .query || self == .json }
    }
    public enum Action: String, Codable, CaseIterable, Sendable {
        case set, remove, replace

        public var title: String {
            switch self {
            case .set: "Set"
            case .remove: "Remove"
            case .replace: "Replace"
            }
        }
    }

    public var id: UUID
    public var phase: Phase
    public var target: Target
    public var action: Action
    /// Header or query parameter name, or a JSON key path such as `user.plan` or `items[0].id`.
    public var name: String
    public var value: String
    /// What `replace` looks for.
    public var find: String
    /// Treat `find` as a regular expression; `value` may then use `$1`…
    public var useRegex: Bool

    public init(id: UUID = UUID(), phase: Phase = .response, target: Target, action: Action = .set, name: String = "",
                value: String = "", find: String = "", useRegex: Bool = false) {
        self.id = id
        self.phase = phase
        self.target = target
        self.action = action
        self.name = name
        self.value = value
        self.find = find
        self.useRegex = useRegex
    }

    private enum CodingKeys: String, CodingKey { case id, phase, target, action, name, value, find, useRegex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .response
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .header
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? .set
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
    }
}

// MARK: Applying HTTP rules

/// Applies HTTP rules. Pure functions, so every rule is unit-tested without a proxy.
public enum HTTPRewriter {
    /// What the request phase decided.
    public struct RequestOutcome: Equatable, Sendable {
        /// The request to send on (or to show, when it is answered locally).
        public var request: HTTPRequestDraft
        /// Set when a Map Local rule answers the request; the server is never contacted.
        public var localResponse: HTTPResponseDraft?
        /// Every rule that matched, in order: they also get the response phase.
        public var matched: [HTTPRule]
        /// Names of the rules that changed something, for the timeline.
        public var applied: [String]
    }

    /// Runs the request phase: Map Remote and Rewrite edit the request in rule order, and the first
    /// Map Local answers it. Rules match the URL as the app sent it, so their order doesn't change
    /// which ones apply.
    public static func rewriteRequest(_ original: HTTPRequestDraft, rules: [HTTPRule],
                                      readFile: (String) throws -> [UInt8] = MapLocalResponse.readFile) -> RequestOutcome {
        let matched = rules.filter { $0.matches(method: original.method, url: original.url) }
        var request = original
        var local: HTTPResponseDraft?
        var applied: [String] = []
        for rule in matched {
            switch rule.kind {
            case .mapLocal:
                guard local == nil else { continue }
                local = rule.mapLocal.response(readFile: readFile)
                applied.append(rule.displayName)
            case .mapRemote:
                guard let destination = rule.mapRemote.destination(for: request.url, pattern: rule.pattern) else { continue }
                let before = request
                request.url = destination
                if !rule.mapRemote.preserveHostHeader, let authority = SplitURL(destination).map({ String($0.origin.split(separator: "/").last ?? "") }) {
                    request.headers.setValue(authority, for: "Host")
                }
                if request != before { applied.append(rule.displayName) }
            case .rewrite:
                let before = request
                for operation in rule.operations where operation.phase == .request {
                    apply(operation, to: &request)
                }
                if request != before { applied.append(rule.displayName) }
            }
        }
        return RequestOutcome(request: request, localResponse: local, matched: matched, applied: applied)
    }

    /// Runs the response phase of the rules the request matched. Returns the response and the names
    /// of the rules that changed it.
    public static func rewriteResponse(_ original: HTTPResponseDraft, matched: [HTTPRule]) -> (HTTPResponseDraft, [String]) {
        var response = original
        var applied: [String] = []
        for rule in matched where rule.kind == .rewrite {
            let before = response
            for operation in rule.operations where operation.phase == .response {
                apply(operation, to: &response)
            }
            if response != before { applied.append(rule.displayName) }
        }
        return (response, applied)
    }

    static func apply(_ operation: RewriteOperation, to request: inout HTTPRequestDraft) {
        guard operation.target.applies(to: .request) else { return }
        switch operation.target {
        case .url:
            switch operation.action {
            case .set: if !operation.value.isEmpty { request.url = operation.value }
            case .replace: request.url = TextReplace.replace(in: request.url, operation: operation)
            case .remove: break
            }
        case .method:
            let method = operation.value.trimmingCharacters(in: .whitespaces).uppercased()
            if operation.action == .set, !method.isEmpty { request.method = method }
        case .query:
            request.url = QueryRewrite.apply(operation, to: request.url)
        case .header:
            HeaderRewrite.apply(operation, to: &request.headers)
        case .body:
            BodyRewrite.apply(operation, body: &request.body, headers: &request.headers)
        case .json:
            BodyRewrite.applyJSON(operation, body: &request.body, headers: &request.headers)
        case .status:
            break
        }
    }

    static func apply(_ operation: RewriteOperation, to response: inout HTTPResponseDraft) {
        guard operation.target.applies(to: .response) else { return }
        switch operation.target {
        case .status:
            if operation.action == .set, let code = Int(operation.value.trimmingCharacters(in: .whitespaces)), (100...999).contains(code) {
                response.statusCode = code
            }
        case .header:
            HeaderRewrite.apply(operation, to: &response.headers)
        case .body:
            BodyRewrite.apply(operation, body: &response.body, headers: &response.headers)
        case .json:
            BodyRewrite.applyJSON(operation, body: &response.body, headers: &response.headers)
        case .url, .method, .query:
            break
        }
    }
}

extension Array where Element == CapturedHeader {
    /// Replaces every header called `name` (any case) with one carrying `value`, keeping the first one's position.
    mutating func setValue(_ value: String, for name: String) {
        let lower = name.lowercased()
        if let first = firstIndex(where: { $0.name.lowercased() == lower }) {
            let original = self[first].name
            removeAll { $0.name.lowercased() == lower }
            insert(CapturedHeader(name: original, value: value), at: Swift.min(first, count))
        } else {
            append(CapturedHeader(name: name, value: value))
        }
    }
}

/// Find-and-replace on text, plain or with a regular expression.
enum TextReplace {
    static func replace(in text: String, operation: RewriteOperation) -> String {
        replace(in: text, find: operation.find, with: operation.value, regex: operation.useRegex)
    }

    static func replace(in text: String, find: String, with value: String, regex: Bool) -> String {
        guard !find.isEmpty else { return text }
        guard regex else { return text.replacingOccurrences(of: find, with: value) }
        guard let expression = try? NSRegularExpression(pattern: find) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: value)
    }
}

enum HeaderRewrite {
    static func apply(_ operation: RewriteOperation, to headers: inout [CapturedHeader]) {
        let name = operation.name.trimmingCharacters(in: .whitespaces)
        switch operation.action {
        case .set:
            guard !name.isEmpty else { return }
            headers.setValue(operation.value, for: name)
        case .remove:
            guard !name.isEmpty else { return }
            headers.removeAll { $0.name.lowercased() == name.lowercased() }
        case .replace:
            for index in headers.indices where name.isEmpty || headers[index].name.lowercased() == name.lowercased() {
                headers[index].value = TextReplace.replace(in: headers[index].value, operation: operation)
            }
        }
    }
}

enum QueryRewrite {
    static func apply(_ operation: RewriteOperation, to url: String) -> String {
        let fragmentStart = url.firstIndex(of: "#") ?? url.endIndex
        let fragment = url[fragmentStart...]
        let withoutFragment = url[..<fragmentStart]
        let base: Substring
        var query: String
        if let mark = withoutFragment.firstIndex(of: "?") {
            base = withoutFragment[..<mark]
            query = String(withoutFragment[withoutFragment.index(after: mark)...])
        } else {
            base = withoutFragment
            query = ""
        }
        let name = operation.name.trimmingCharacters(in: .whitespaces)
        switch operation.action {
        case .replace:
            query = TextReplace.replace(in: query, operation: operation)
        case .set, .remove:
            guard !name.isEmpty else { return url }
            var pairs = query.split(separator: "&", omittingEmptySubsequences: true).map(String.init)
            let matchesName: (String) -> Bool = { pair in
                let key = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? pair
                return (key.removingPercentEncoding ?? key) == name
            }
            if operation.action == .remove {
                pairs.removeAll(where: matchesName)
            } else {
                let encoded = encode(name) + "=" + encode(operation.value)
                if let first = pairs.firstIndex(where: matchesName) {
                    pairs.removeAll(where: matchesName)
                    pairs.insert(encoded, at: min(first, pairs.count))
                } else {
                    pairs.append(encoded)
                }
            }
            query = pairs.joined(separator: "&")
        }
        return String(base) + (query.isEmpty ? "" : "?" + query) + fragment
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

enum BodyRewrite {
    static func apply(_ operation: RewriteOperation, body: inout [UInt8], headers: inout [CapturedHeader]) {
        switch operation.action {
        case .set:
            body = Array(operation.value.utf8)
        case .remove:
            body = []
        case .replace:
            // Compressed or binary bodies aren't text; leave them alone rather than corrupt them.
            guard !isEncoded(headers), let text = String(bytes: body, encoding: .utf8) else { return }
            let replaced = TextReplace.replace(in: text, operation: operation)
            if replaced != text { body = Array(replaced.utf8) }
            return
        }
        // The new body is plain, whatever the old one was compressed with.
        headers.removeAll { $0.name.lowercased() == "content-encoding" }
    }

    static func applyJSON(_ operation: RewriteOperation, body: inout [UInt8], headers: inout [CapturedHeader]) {
        guard !isEncoded(headers), !body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: Data(body), options: [.fragmentsAllowed]) else { return }
        let path = JSONPath.parse(operation.name)
        guard !path.isEmpty else { return }
        let updated: Any?
        switch operation.action {
        case .set: updated = JSONPath.setting(JSONPath.literal(operation.value), at: path, in: root)
        case .remove: updated = JSONPath.removing(at: path, in: root)
        case .replace: updated = nil
        }
        guard let updated,
              let data = try? JSONSerialization.data(withJSONObject: updated, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        body = Array(data)
    }

    private static func isEncoded(_ headers: [CapturedHeader]) -> Bool {
        headers.contains { $0.name.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }
    }
}

/// Dotted key paths into JSON: `user.plan`, `items[0].id`, `items.0.id`.
enum JSONPath {
    enum Component: Equatable { case key(String), index(Int) }

    static func parse(_ path: String) -> [Component] {
        var components: [Component] = []
        for part in path.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: true) {
            var rest = Substring(part)
            if let bracket = rest.firstIndex(of: "[") {
                let key = rest[..<bracket]
                if !key.isEmpty { components.append(Int(key).map(Component.index) ?? .key(String(key))) }
                rest = rest[bracket...]
                while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                    let inner = rest[rest.index(after: rest.startIndex)..<close]
                    if let index = Int(inner) { components.append(.index(index)) } else { components.append(.key(String(inner))) }
                    rest = rest[rest.index(after: close)...]
                }
            } else {
                components.append(Int(rest).map(Component.index) ?? .key(String(rest)))
            }
        }
        return components
    }

    /// `true`, `42`, `"text"`, `{"a":1}` and `null` are JSON; anything else is taken as a string.
    static func literal(_ text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            return value
        }
        return text
    }

    /// `root` with `value` at `path`; missing objects along the way are created. Nil when the path
    /// runs through something that isn't an object or array.
    static func setting(_ value: Any, at path: [Component], in root: Any) -> Any? {
        guard let first = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let key):
            var object = root as? [String: Any] ?? [:]
            guard root is [String: Any] || root is NSNull else { return nil }
            guard let child = setting(value, at: rest, in: object[key] ?? NSNull()) else { return nil }
            object[key] = child
            return object
        case .index(let index):
            if var array = root as? [Any] {
                if index < array.count && index >= 0 {
                    guard let child = setting(value, at: rest, in: array[index]) else { return nil }
                    array[index] = child
                } else if index == array.count {
                    guard let child = setting(value, at: rest, in: NSNull()) else { return nil }
                    array.append(child)
                } else {
                    return nil
                }
                return array
            }
            if var object = root as? [String: Any] {
                let key = String(index)
                guard let child = setting(value, at: rest, in: object[key] ?? NSNull()) else { return nil }
                object[key] = child
                return object
            }
            return nil
        }
    }

    static func removing(at path: [Component], in root: Any) -> Any? {
        guard let first = path.first else { return nil }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let key):
            guard var object = root as? [String: Any], let child = object[key] else { return nil }
            if rest.isEmpty {
                object.removeValue(forKey: key)
            } else {
                guard let updated = removing(at: rest, in: child) else { return nil }
                object[key] = updated
            }
            return object
        case .index(let index):
            if var array = root as? [Any], array.indices.contains(index) {
                if rest.isEmpty {
                    array.remove(at: index)
                } else {
                    guard let updated = removing(at: rest, in: array[index]) else { return nil }
                    array[index] = updated
                }
                return array
            }
            if root is [String: Any] { return removing(at: [.key(String(index))] + rest, in: root) }
            return nil
        }
    }
}

// MARK: Live rules

/// The rules the proxy and the MQTT forwarders read on their event loops. The app replaces them as
/// the user edits, and the next request or packet uses the new set; nothing needs a restart.
public final class LiveRules: @unchecked Sendable {
    private let lock = NSLock()
    private var _http: [HTTPRule] = []
    private var _mqtt: [MQTTRule] = []

    public init(http: [HTTPRule] = [], mqtt: [MQTTRule] = []) {
        _http = http
        _mqtt = mqtt
    }

    /// Enabled HTTP rules, in order. Empty while map and rewrite are off.
    public var http: [HTTPRule] { lock.withLock { _http } }
    /// Enabled MQTT rules, in order.
    public var mqtt: [MQTTRule] { lock.withLock { _mqtt } }

    public func update(http: [HTTPRule], mqtt: [MQTTRule]) {
        let http = http.filter(\.isEnabled)
        let mqtt = mqtt.filter(\.isEnabled)
        lock.withLock {
            _http = http
            _mqtt = mqtt
        }
    }
}
