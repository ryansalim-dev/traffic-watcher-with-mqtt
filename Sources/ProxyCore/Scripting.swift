import Foundation
import MQTTCore

// MARK: Scripts

/// A user script (Pro). JavaScript that defines any of three functions, each called for the traffic
/// the script's match settings select:
///
/// - `onRequest(request)`: before an HTTP request goes to the server. Edit it, or return
///   `respond(...)` to answer without contacting the server.
/// - `onResponse(request, response)`: before the response goes back to the app.
/// - `onPublish(message)`: for every MQTT PUBLISH through a forwarder.
///
/// Top-level variables keep their values between calls until the script is edited.
public struct UserScript: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var name: String
    public var source: String
    /// URL pattern, as for rules. Empty means the script never sees HTTP.
    public var urlPattern: String
    /// Upper-case HTTP method, or nil for any.
    public var method: String?
    /// MQTT topic filter. Empty means the script never sees MQTT.
    public var topicFilter: String
    public var direction: MQTTRule.Direction

    public init(id: UUID = UUID(), isEnabled: Bool = true, name: String = "", source: String = "",
                urlPattern: String = "", method: String? = nil, topicFilter: String = "",
                direction: MQTTRule.Direction = .both) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.source = source
        self.urlPattern = urlPattern
        self.method = method
        self.topicFilter = topicFilter
        self.direction = direction
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !urlPattern.isEmpty { return urlPattern }
        return topicFilter.isEmpty ? "Untitled script" : topicFilter
    }

    public var handlesHTTP: Bool { !urlPattern.trimmingCharacters(in: .whitespaces).isEmpty }
    public var handlesMQTT: Bool { !topicFilter.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(method: String, url: String) -> Bool {
        guard isEnabled, handlesHTTP else { return false }
        if let scriptMethod = self.method, !scriptMethod.isEmpty, scriptMethod.uppercased() != method.uppercased() { return false }
        return URLPattern.matches(urlPattern, url: url)
    }

    public func matches(topic: String, direction: MQTTDirection) -> Bool {
        guard isEnabled, handlesMQTT else { return false }
        return MQTTRule(topicFilter: topicFilter, direction: self.direction).matches(topic: topic, direction: direction)
    }

    /// Which hooks the source appears to define. A quick look for the editor; the engine decides for real.
    public var definedHooks: Set<ScriptHook> {
        Set(ScriptHook.allCases.filter { hook in
            source.range(of: "(function\\s+\(hook.functionName)\\b|\\b\(hook.functionName)\\s*=)", options: .regularExpression) != nil
        })
    }

    private enum CodingKeys: String, CodingKey { case id, isEnabled, name, source, urlPattern, method, topicFilter, direction }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        urlPattern = try container.decodeIfPresent(String.self, forKey: .urlPattern) ?? ""
        method = try container.decodeIfPresent(String.self, forKey: .method)
        topicFilter = try container.decodeIfPresent(String.self, forKey: .topicFilter) ?? ""
        direction = try container.decodeIfPresent(MQTTRule.Direction.self, forKey: .direction) ?? .both
    }
}

public enum ScriptHook: String, CaseIterable, Codable, Hashable, Sendable {
    case request, response, publish

    /// The JavaScript function the hook calls.
    public var functionName: String {
        switch self {
        case .request: "onRequest"
        case .response: "onResponse"
        case .publish: "onPublish"
        }
    }
}

/// One line in the scripts console: something a script logged, or an error.
public struct ScriptLogEntry: Equatable, Identifiable, Sendable {
    public enum Level: String, Sendable { case log, warn, error, info }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var scriptID: UUID?
    public var scriptName: String
    /// What the script was handling, such as `onRequest · GET https://…`.
    public var context: String
    public var message: String
    /// Line in the script, for errors that have one.
    public var line: Int?

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, scriptID: UUID?, scriptName: String,
                context: String, message: String, line: Int? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.context = context
        self.message = message
        self.line = line
    }
}

// MARK: Engine

/// What an engine returned for one hook call.
public enum ScriptCallResult: Equatable, Sendable {
    /// The runtime's JSON answer (see `ScriptRunner`).
    case output(String)
    /// The script didn't load, ran too long, or the engine stopped responding.
    case failure(String, line: Int?)
}

/// Runs scripts. Calls may come from any thread and block until the script returns or its time
/// limit passes. An engine is made for one set of scripts and replaced when they change.
public protocol ScriptEngine: AnyObject, Sendable {
    /// Calls `hook` of `script` with the runtime's JSON input.
    func call(_ hook: ScriptHook, script: UserScript, input: String) -> ScriptCallResult
}

/// The scripts the proxy and forwarders run, and the engine that runs them. The app replaces them
/// as the user edits, and the next request or packet uses the new set.
public final class LiveScripts: @unchecked Sendable {
    public typealias EngineFactory = @Sendable ([UserScript]) -> ScriptEngine?

    /// One consistent view of the scripts and their engine.
    public struct Snapshot: Sendable {
        public var scripts: [UserScript]
        public var engine: ScriptEngine
        private var hooks: [UUID: Set<ScriptHook>]

        public init(scripts: [UserScript], engine: ScriptEngine) {
            self.scripts = scripts
            self.engine = engine
            hooks = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0.definedHooks) })
        }

        /// Scripts that match the request and define `hook`, in order.
        public func scripts(for hook: ScriptHook, method: String, url: String) -> [UserScript] {
            scripts.filter { hooks[$0.id]?.contains(hook) == true && $0.matches(method: method, url: url) }
        }

        /// True when some script defines `onPublish`.
        public var handlesPublish: Bool {
            scripts.contains { hooks[$0.id]?.contains(.publish) == true }
        }

        /// Scripts that match the PUBLISH and define `onPublish`, in order.
        public func scripts(topic: String, direction: MQTTDirection) -> [UserScript] {
            scripts.filter { hooks[$0.id]?.contains(.publish) == true && $0.matches(topic: topic, direction: direction) }
        }
    }

    private let lock = NSLock()
    private let makeEngine: EngineFactory
    private var _snapshot: Snapshot?
    private var _onLog: (@Sendable ([ScriptLogEntry]) -> Void)?

    /// - Parameter makeEngine: builds the engine for a set of scripts; nil (no engine on this
    ///   platform) leaves traffic alone.
    public init(makeEngine: @escaping EngineFactory = LiveScripts.platformEngine) {
        self.makeEngine = makeEngine
    }

    /// The JavaScriptCore engine on Apple platforms, nothing elsewhere.
    public static let platformEngine: EngineFactory = { scripts in
        #if canImport(JavaScriptCore)
        JavaScriptEngine(scripts: scripts)
        #else
        nil
        #endif
    }

    /// True where scripts can run (JavaScriptCore is available).
    public static var isSupported: Bool {
        #if canImport(JavaScriptCore)
        true
        #else
        false
        #endif
    }

    /// Enabled scripts with their engine; nil while there are none.
    public var snapshot: Snapshot? { lock.withLock { _snapshot } }

    /// Receives console output and errors, on whatever thread the script ran.
    public var onLog: (@Sendable ([ScriptLogEntry]) -> Void)? {
        get { lock.withLock { _onLog } }
        set { lock.withLock { _onLog = newValue } }
    }

    /// Replaces the scripts. A fresh engine starts, so scripts begin again from their top level.
    public func update(_ scripts: [UserScript]) {
        let enabled = scripts.filter { $0.isEnabled && ($0.handlesHTTP || $0.handlesMQTT) }
        let snapshot = enabled.isEmpty ? nil : makeEngine(enabled).map { Snapshot(scripts: enabled, engine: $0) }
        lock.withLock { _snapshot = snapshot }
    }

    func log(_ entries: [ScriptLogEntry]) {
        guard !entries.isEmpty else { return }
        onLog?(entries)
    }
}

// MARK: Running hooks

/// Turns traffic into the runtime's JSON, calls the engine and applies what the script changed.
/// Pure apart from the engine, so the rules are tested with a stand-in engine.
public enum ScriptRunner {
    public struct RequestResult: Equatable, Sendable {
        public var request: HTTPRequestDraft
        /// Set when a script answered with `respond(...)`; the server is never contacted.
        public var response: HTTPResponseDraft?
        /// The script that answered.
        public var answeredBy: String?
        /// Names of the scripts that changed something.
        public var applied: [String]
        public var logs: [ScriptLogEntry]
    }

    public struct ResponseResult: Equatable, Sendable {
        public var response: HTTPResponseDraft
        public var applied: [String]
        public var logs: [ScriptLogEntry]
    }

    public struct PublishResult: Equatable, Sendable {
        public var publish: MQTTPublish
        public var topic: String
        public var applied: [String]
        public var logs: [ScriptLogEntry]
    }

    /// Runs `onRequest` of each script in order. The first `respond(...)` answers the request and
    /// the scripts after it don't run.
    public static func runRequest(_ original: HTTPRequestDraft, scripts: [UserScript], engine: ScriptEngine) -> RequestResult {
        var request = original
        var result = RequestResult(request: original, response: nil, answeredBy: nil, applied: [], logs: [])
        for script in scripts {
            let input = Envelope(request: RequestIn(request), response: nil, message: nil)
            let context = "onRequest · \(request.method) \(request.url)"
            guard let output = call(.request, script: script, input: input, context: context, engine: engine, logs: &result.logs),
                  let edited = output.request else { continue }
            let before = request
            request = edited.apply(to: request)
            if let answer = output.response {
                var response = HTTPResponseDraft(statusCode: 200, headers: [], body: [])
                response = answer.apply(to: response)
                response.headers.removeAll { ["content-length", "transfer-encoding"].contains($0.name.lowercased()) }
                result.response = response
                result.answeredBy = script.displayName
                if !result.applied.contains(script.displayName) { result.applied.append(script.displayName) }
                break
            }
            if request != before, !result.applied.contains(script.displayName) { result.applied.append(script.displayName) }
        }
        result.request = request
        return result
    }

    /// Runs `onResponse` of each script in order; `request` is what was sent.
    public static func runResponse(_ original: HTTPResponseDraft, request: HTTPRequestDraft, scripts: [UserScript],
                                   engine: ScriptEngine) -> ResponseResult {
        var response = original
        var result = ResponseResult(response: original, applied: [], logs: [])
        for script in scripts {
            let input = Envelope(request: RequestIn(request), response: ResponseIn(response), message: nil)
            let context = "onResponse · \(response.statusCode) \(request.method) \(request.url)"
            guard let output = call(.response, script: script, input: input, context: context, engine: engine, logs: &result.logs),
                  let edited = output.response else { continue }
            let before = response
            response = edited.apply(to: response)
            if response != before, !result.applied.contains(script.displayName) { result.applied.append(script.displayName) }
        }
        result.response = response
        return result
    }

    /// Runs `onPublish` of each script in order. `resolvedTopic` is the topic after any v5 alias.
    public static func runPublish(_ original: MQTTPublish, resolvedTopic: String, direction: MQTTDirection, broker: String,
                                  clientID: String?, scripts: [UserScript], engine: ScriptEngine) -> PublishResult {
        var publish = original
        var topic = resolvedTopic
        var result = PublishResult(publish: original, topic: resolvedTopic, applied: [], logs: [])
        for script in scripts {
            let message = MessageIn(topic: topic, qos: Int(publish.qos.rawValue), retain: publish.retain,
                                    direction: direction == .clientToBroker ? "clientToBroker" : "brokerToClient",
                                    broker: broker, clientId: clientID, payload: BodyIn(publish.payload, headers: []))
            let input = Envelope(request: nil, response: nil, message: message)
            let context = "onPublish · \(topic)"
            guard let output = call(.publish, script: script, input: input, context: context, engine: engine, logs: &result.logs),
                  let edited = output.message else { continue }
            let before = (publish, topic)
            edited.apply(to: &publish, topic: &topic)
            if before.0 != publish || before.1 != topic, !result.applied.contains(script.displayName) {
                result.applied.append(script.displayName)
            }
        }
        result.publish = publish
        result.topic = topic
        return result
    }

    private static func call(_ hook: ScriptHook, script: UserScript, input: Envelope, context: String, engine: ScriptEngine,
                             logs: inout [ScriptLogEntry]) -> Output? {
        func entry(_ level: ScriptLogEntry.Level, _ message: String, line: Int? = nil) -> ScriptLogEntry {
            ScriptLogEntry(level: level, scriptID: script.id, scriptName: script.displayName, context: context, message: message, line: line)
        }
        guard let json = try? String(decoding: JSONEncoder().encode(input), as: UTF8.self) else { return nil }
        switch engine.call(hook, script: script, input: json) {
        case .failure(let message, let line):
            logs.append(entry(.error, message, line: line))
            return nil
        case .output(let text):
            guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
                logs.append(entry(.error, "The script runtime returned something unreadable"))
                return nil
            }
            for pair in output.logs ?? [] where pair.count == 2 {
                logs.append(entry(ScriptLogEntry.Level(rawValue: pair[0]) ?? .log, pair[1]))
            }
            if let error = output.error {
                logs.append(entry(.error, "\(hook.functionName): \(error)", line: output.line))
                return nil
            }
            return output.skipped == true ? nil : output
        }
    }

    // MARK: JSON the runtime reads

    struct Envelope: Encodable {
        var request: RequestIn?
        var response: ResponseIn?
        var message: MessageIn?
    }

    /// A body as text when it is UTF-8 and not compressed, always as base64.
    struct BodyIn: Encodable {
        var text: String?
        var base64: String

        init(_ bytes: [UInt8], headers: [CapturedHeader]) {
            let encoded = headers.contains { $0.name.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }
            text = encoded ? nil : String(bytes: bytes, encoding: .utf8)
            base64 = Data(bytes).base64EncodedString()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Null rather than missing, so scripts can test `body === null`.
            try container.encode(text, forKey: .text)
            try container.encode(base64, forKey: .base64)
        }

        enum CodingKeys: String, CodingKey { case text, base64 }
    }

    struct RequestIn: Encodable {
        var method: String
        var url: String
        var headers: [[String]]
        var body: BodyIn

        init(_ draft: HTTPRequestDraft) {
            method = draft.method
            url = draft.url
            headers = draft.headers.map { [$0.name, $0.value] }
            body = BodyIn(draft.body, headers: draft.headers)
        }
    }

    struct ResponseIn: Encodable {
        var status: Int
        var headers: [[String]]
        var body: BodyIn

        init(_ draft: HTTPResponseDraft) {
            status = draft.statusCode
            headers = draft.headers.map { [$0.name, $0.value] }
            body = BodyIn(draft.body, headers: draft.headers)
        }
    }

    struct MessageIn: Encodable {
        var topic: String
        var qos: Int
        var retain: Bool
        var direction: String
        var broker: String
        var clientId: String?
        var payload: BodyIn
    }

    // MARK: JSON the runtime writes

    struct Output: Decodable {
        var logs: [[String]]?
        var skipped: Bool?
        var error: String?
        var line: Int?
        var request: RequestOut?
        var response: ResponseOut?
        var message: MessageOut?
    }

    /// A changed body: new text, or new bytes as base64. Nil when the script left the body alone.
    struct BodyOut: Decodable {
        var text: String?
        var base64: String?

        /// The new bytes, and whether they are text (which drops any compression header).
        var bytes: (bytes: [UInt8], isText: Bool)? {
            if let text { return (Array(text.utf8), true) }
            if let base64, let data = Data(base64Encoded: base64) { return (Array(data), false) }
            return nil
        }
    }

    struct RequestOut: Decodable {
        var method: String?
        var url: String?
        var headers: [[String]]?
        var body: BodyOut?

        func apply(to draft: HTTPRequestDraft) -> HTTPRequestDraft {
            var draft = draft
            if let method = method?.trimmingCharacters(in: .whitespaces).uppercased(), !method.isEmpty { draft.method = method }
            if let url = url?.trimmingCharacters(in: .whitespaces), !url.isEmpty { draft.url = url }
            if let headers { draft.headers = ScriptRunner.headers(headers) }
            if let (bytes, isText) = body?.bytes {
                draft.body = bytes
                if isText { draft.headers.removeAll { $0.name.lowercased() == "content-encoding" } }
            }
            return draft
        }
    }

    struct ResponseOut: Decodable {
        var status: Int?
        var headers: [[String]]?
        var body: BodyOut?

        func apply(to draft: HTTPResponseDraft) -> HTTPResponseDraft {
            var draft = draft
            if let status, (100...999).contains(status) { draft.statusCode = status }
            if let headers { draft.headers = ScriptRunner.headers(headers) }
            if let (bytes, isText) = body?.bytes {
                draft.body = bytes
                if isText { draft.headers.removeAll { $0.name.lowercased() == "content-encoding" } }
            }
            return draft
        }
    }

    struct MessageOut: Decodable {
        var topic: String?
        var retain: Bool?
        var payload: BodyOut?

        func apply(to publish: inout MQTTPublish, topic: inout String) {
            if let new = self.topic?.trimmingCharacters(in: .whitespaces), new != topic,
               !new.isEmpty, !new.contains("+"), !new.contains("#") {
                // As for rewrite rules: an alias-only packet keeps its alias, since the packet that set
                // the alias went through the same script.
                topic = new
                if !publish.topic.isEmpty || publish.topicAlias == nil { publish.topic = new }
            }
            if let retain { publish.retain = retain }
            if let (bytes, _) = payload?.bytes { publish.payload = bytes }
        }
    }

    static func headers(_ pairs: [[String]]) -> [CapturedHeader] {
        pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(":"), !name.contains("\n"), !name.contains("\r") else { return nil }
            let value = pair[1].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
            return CapturedHeader(name: name, value: value)
        }
    }
}
