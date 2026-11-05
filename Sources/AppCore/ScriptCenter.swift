import Foundation
import Licensing
import MQTTCore
import Observation
import ProxyCore

/// What the scripts window saves between launches.
public struct ScriptSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var scripts: [UserScript]

    public init(isEnabled: Bool = true, scripts: [UserScript] = []) {
        self.isEnabled = isEnabled
        self.scripts = scripts
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, scripts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        scripts = try container.decodeIfPresent([UserScript].self, forKey: .scripts) ?? []
    }
}

/// Owns the user scripts and their console. Edits reach the proxy at once through `live`; with
/// the master switch off, scripts are kept but none runs. Free runs `limit` scripts at a time;
/// Pro runs them all.
@MainActor
@Observable
public final class ScriptCenter {
    public var scripts: [UserScript] {
        didSet {
            guard !isRefusing else { return }
            var checked = scripts
            if RuleLimit.refuse(old: oldValue, new: &checked, limit: limit, isEnabled: \.isEnabled, group: { _ in 0 }) != nil {
                isRefusing = true
                scripts = checked
                isRefusing = false
                if let limit { limitPrompt = ProLimitPrompt(.ruleLimit(.script, limit: limit)) }
            }
            changed()
        }
    }
    /// The master switch in the scripts window and the Capture menu.
    public var isEnabled: Bool {
        didSet { changed() }
    }
    /// Enabled scripts that run at once on the free tier; nil with Pro. Scripts past it are kept,
    /// and the first ones in the list keep running, so a downgrade doesn't change which ones run.
    public var limit: Int? = LicensePolicy.standard.freeLimits.activeRules {
        didSet { push() }
    }
    /// Set when turning a script on went past `limit`; the UI shows it as a short Pro prompt.
    public var limitPrompt: ProLimitPrompt?
    @ObservationIgnored private var isRefusing = false
    /// The script open in the scripts window.
    public var selection: UUID?
    /// Shows the scripts window; set by the timeline's context menu.
    public var isPresented = false
    /// Console output and errors, oldest first, capped at `logLimit`.
    public private(set) var log: [ScriptLogEntry] = []
    public static let logLimit = 500
    /// True while "Run on Latest Match" is running.
    public private(set) var isTesting = false

    /// Hand this to the capture engine.
    public let live: LiveScripts
    private let save: ((ScriptSettings) -> Void)?
    private let makeEngine: LiveScripts.EngineFactory

    public init(settings: ScriptSettings = .init(), live: LiveScripts? = nil,
                makeEngine: @escaping LiveScripts.EngineFactory = LiveScripts.platformEngine,
                save: ((ScriptSettings) -> Void)? = nil) {
        scripts = settings.scripts
        isEnabled = settings.isEnabled
        self.makeEngine = makeEngine
        self.live = live ?? LiveScripts(makeEngine: makeEngine)
        self.save = save
        self.live.onLog = { [weak self] entries in
            Task { @MainActor in self?.append(entries) }
        }
        push()
    }

    /// True when enabled scripts actually run.
    public var isActive: Bool { isEnabled }

    /// True on the free tier.
    public var isLimited: Bool { limit != nil }

    /// The enabled scripts that run.
    public var runningScripts: [UserScript] {
        let ids = RuleLimit.running(scripts, limit: limit, isEnabled: \.isEnabled, group: { _ in 0 })
        return scripts.filter { ids.contains($0.id) }
    }

    /// Enabled scripts that the free tier's limit keeps from running.
    public var heldScriptIDs: Set<UUID> {
        let running = Set(runningScripts.map(\.id))
        return Set(scripts.filter { $0.isEnabled && !running.contains($0.id) }.map(\.id))
    }

    public var enabledCount: Int { scripts.filter(\.isEnabled).count }

    public var settings: ScriptSettings { ScriptSettings(isEnabled: isEnabled, scripts: scripts) }

    /// Errors in the console from this script, newest first.
    public func errors(for id: UUID) -> [ScriptLogEntry] {
        log.reversed().filter { $0.scriptID == id && $0.level == .error }
    }

    private func changed() {
        push()
        save?(settings)
    }

    private func push() {
        live.update(isActive ? runningScripts : [])
    }

    public func append(_ entries: [ScriptLogEntry]) {
        log.append(contentsOf: entries)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    public func clearLog() {
        log.removeAll()
    }

    // MARK: Adding scripts

    /// A new script from `template`, selected.
    @discardableResult
    public func addScript(_ template: ScriptTemplate = .blank, urlPattern: String? = nil, method: String? = nil,
                          topicFilter: String? = nil, name: String? = nil) -> UserScript {
        var script = template.script
        if let urlPattern { script.urlPattern = urlPattern }
        if let method { script.method = method }
        if let topicFilter { script.topicFilter = topicFilter }
        if let name { script.name = name }
        scripts.append(script)
        selection = script.id
        return script
    }

    /// A script for this exchange's URL (query dropped) that starts from both HTTP hooks.
    @discardableResult
    public func addScript(for exchange: HTTPExchange) -> UserScript {
        addScript(.httpBoth, urlPattern: BreakpointCenter.pattern(for: exchange.url), method: exchange.method,
                  name: "Script for \(RewriteCenter.shortPath(exchange.url))")
    }

    /// A script for PUBLISH messages on this topic.
    @discardableResult
    public func addScript(forTopic topic: String) -> UserScript {
        addScript(.mqttPayload, topicFilter: topic, name: "Script for \(topic)")
    }

    public func remove(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    /// A copy of the script right after it, selected.
    public func duplicate(_ id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        var copy = scripts[index]
        copy.id = UUID()
        copy.name = copy.name.isEmpty ? "" : copy.name + " copy"
        scripts.insert(copy, at: index + 1)
        selection = copy.id
    }

    // MARK: Trying a script

    /// The newest exchange or PUBLISH in `rows` that `script` matches (whether or not it is on).
    public static func latestMatch(for script: UserScript, in rows: [TrafficRow]) -> TrafficRow? {
        var script = script
        script.isEnabled = true
        return rows.last { row in
            switch row.event {
            case .httpExchange(let exchange):
                return script.matches(method: exchange.method, url: exchange.url)
            case .mqtt(let capture):
                guard case .publish(let publish) = capture.event.packet else { return false }
                return script.matches(topic: capture.event.resolvedTopic ?? publish.topic, direction: capture.event.direction)
            default:
                return false
            }
        }
    }

    /// Runs the script's hooks on a captured exchange or PUBLISH, in a fresh engine, and writes what
    /// it logged and changed to the console. Traffic is not touched. Works without Pro, so scripts
    /// can be tried before buying.
    public func test(_ script: UserScript, on row: TrafficRow) async {
        isTesting = true
        defer { isTesting = false }
        let makeEngine = self.makeEngine
        let entries = await Task.detached(priority: .userInitiated) {
            Self.testEntries(script, on: row.event, makeEngine: makeEngine)
        }.value
        append(entries)
    }

    nonisolated static func testEntries(_ script: UserScript, on event: CaptureEvent, makeEngine: LiveScripts.EngineFactory) -> [ScriptLogEntry] {
        func note(_ context: String, _ message: String, level: ScriptLogEntry.Level = .info) -> ScriptLogEntry {
            ScriptLogEntry(level: level, scriptID: script.id, scriptName: script.displayName, context: context, message: message)
        }
        var script = script
        script.isEnabled = true
        guard let engine = makeEngine([script]) else {
            return [note("Test", "Scripts need JavaScriptCore, which this system doesn't have", level: .error)]
        }
        let hooks = script.definedHooks
        var entries: [ScriptLogEntry] = []
        switch event {
        case .httpExchange(let exchange):
            let request = HTTPRequestDraft(method: exchange.method, url: exchange.url, headers: exchange.requestHeaders, body: exchange.requestBody)
            guard hooks.contains(.request) || hooks.contains(.response) else {
                return [note("Test", "Define onRequest(request) or onResponse(request, response) to handle HTTP")]
            }
            var sent = request
            if hooks.contains(.request) {
                let result = ScriptRunner.runRequest(request, scripts: [script], engine: engine)
                entries += result.logs
                sent = result.request
                var summary = changes(from: request, to: result.request)
                if let answer = result.response { summary.append("answered with \(answer.statusCode) without calling the server") }
                entries.append(note("Test · onRequest", summary.isEmpty ? "No changes" : "Changed " + summary.joined(separator: ", ")))
                if result.response != nil { return entries }
            }
            if hooks.contains(.response), let status = exchange.statusCode {
                let response = HTTPResponseDraft(statusCode: status, headers: exchange.responseHeaders, body: exchange.responseBody)
                let result = ScriptRunner.runResponse(response, request: sent, scripts: [script], engine: engine)
                entries += result.logs
                let summary = changes(from: response, to: result.response)
                entries.append(note("Test · onResponse", summary.isEmpty ? "No changes" : "Changed " + summary.joined(separator: ", ")))
            }
        case .mqtt(let capture):
            guard case .publish(let publish) = capture.event.packet else { return entries }
            guard hooks.contains(.publish) else { return [note("Test", "Define onPublish(message) to handle MQTT")] }
            let topic = capture.event.resolvedTopic ?? publish.topic
            let result = ScriptRunner.runPublish(publish, resolvedTopic: topic, direction: capture.event.direction, broker: capture.broker,
                                                 clientID: nil, scripts: [script], engine: engine)
            entries += result.logs
            var summary: [String] = []
            if result.topic != topic { summary.append("topic to \(result.topic)") }
            if result.publish.payload != publish.payload { summary.append("payload (\(Formatting.compactByteCount(result.publish.payload.count)))") }
            if result.publish.retain != publish.retain { summary.append("retain to \(result.publish.retain)") }
            entries.append(note("Test · onPublish", summary.isEmpty ? "No changes" : "Changed " + summary.joined(separator: ", ")))
        default:
            break
        }
        return entries
    }

    nonisolated static func changes(from old: HTTPRequestDraft, to new: HTTPRequestDraft) -> [String] {
        var parts: [String] = []
        if old.method != new.method { parts.append("method to \(new.method)") }
        if old.url != new.url { parts.append("URL to \(new.url)") }
        parts += headerChanges(old.headers, new.headers)
        if old.body != new.body { parts.append("body (\(Formatting.compactByteCount(new.body.count)))") }
        return parts
    }

    nonisolated static func changes(from old: HTTPResponseDraft, to new: HTTPResponseDraft) -> [String] {
        var parts: [String] = []
        if old.statusCode != new.statusCode { parts.append("status to \(new.statusCode)") }
        parts += headerChanges(old.headers, new.headers)
        if old.body != new.body { parts.append("body (\(Formatting.compactByteCount(new.body.count)))") }
        return parts
    }

    nonisolated static func headerChanges(_ old: [CapturedHeader], _ new: [CapturedHeader]) -> [String] {
        guard old != new else { return [] }
        let names = Set(old.map { $0.name.lowercased() }).union(new.map { $0.name.lowercased() })
        let changed = names.filter { name in
            old.filter { $0.name.lowercased() == name }.map(\.value) != new.filter { $0.name.lowercased() == name }.map(\.value)
        }
        guard !changed.isEmpty else { return ["header order"] }
        let spelled = changed.sorted().map { lower in (new.first { $0.name.lowercased() == lower } ?? old.first { $0.name.lowercased() == lower })?.name ?? lower }
        return ["header\(spelled.count == 1 ? "" : "s") \(spelled.joined(separator: ", "))"]
    }
}

// MARK: Templates

/// Starting points for new scripts.
public enum ScriptTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank, addHeader, editJSONResponse, mockResponse, httpBoth, mqttPayload

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: "Blank script"
        case .addHeader: "Add a request header"
        case .editJSONResponse: "Edit a JSON response"
        case .mockResponse: "Answer with a mock"
        case .httpBoth: "Request and response"
        case .mqttPayload: "Transform MQTT payloads"
        }
    }

    public var summary: String {
        switch self {
        case .blank: "All three hooks, commented out."
        case .addHeader: "Sign every request, for example with a token or a debug flag."
        case .editJSONResponse: "Change values in the response JSON before the app sees them."
        case .mockResponse: "Answer some requests locally with respond(), decided in code."
        case .httpBoth: "Log what goes out and edit what comes back."
        case .mqttPayload: "Rewrite PUBLISH payloads and topics on their way through Wiretide."
        }
    }

    var script: UserScript {
        switch self {
        case .blank:
            UserScript(name: "", source: Self.blankSource, urlPattern: "", topicFilter: "")
        case .addHeader:
            UserScript(name: "Add debug header", source: """
            // Runs before each matching request goes to the server.
            function onRequest(request) {
              request.headers["X-Debug"] = "1";
              request.headers["Authorization"] = "Bearer " + token();
              return request;
            }

            // Top-level code runs once; variables keep their values between requests.
            let issued = 0;
            function token() {
              issued += 1;
              return "dev-token-" + issued;
            }
            """, urlPattern: "api.example.com/*")
        case .editJSONResponse:
            UserScript(name: "Edit JSON response", source: """
            // Runs before each matching response goes back to the app.
            function onResponse(request, response) {
              if (response.json && response.json.user) {
                response.json.user.plan = "pro";
                console.log("Upgraded", response.json.user.id, "for", request.path);
              }
              return response;
            }
            """, urlPattern: "api.example.com/*")
        case .mockResponse:
            UserScript(name: "Mock some requests", source: """
            function onRequest(request) {
              // Answer without calling the server; return nothing to let the request through.
              if (request.query.mock === "empty") {
                return respond({ status: 200, json: { items: [], total: 0 } });
              }
              if (request.method === "DELETE") {
                return respond(403, "Deleting is disabled while testing");
              }
            }
            """, urlPattern: "api.example.com/*")
        case .httpBoth:
            UserScript(name: "", source: """
            function onRequest(request) {
              console.log(request.method, request.path, request.query);
              return request;
            }

            function onResponse(request, response) {
              response.headers["X-Wiretide-Script"] = "1";
              return response;
            }
            """)
        case .mqttPayload:
            UserScript(name: "Transform payloads", source: """
            // Runs for each matching PUBLISH, through a forwarder or over WebSockets.
            function onPublish(message) {
              if (message.json && typeof message.json.celsius === "number") {
                message.json.fahrenheit = message.json.celsius * 9 / 5 + 32;
              }
              console.log(message.direction, message.topic, message.payload);
              return message;
            }
            """, topicFilter: "home/#")
        }
    }

    static let blankSource = """
    // Wiretide calls these functions for the traffic this script matches.
    // Edit and return the object; return nothing to leave it as it is.

    // function onRequest(request) {
    //   // request: method, url, host, path, query, headers, body, json
    //   return request;
    // }

    // function onResponse(request, response) {
    //   // response: status, headers, body, json
    //   return response;
    // }

    // function onPublish(message) {
    //   // message: topic, payload, json, qos, retain, direction, broker
    //   return message;
    // }
    """
}
