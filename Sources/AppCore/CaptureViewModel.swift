import CaptureStore
import Foundation
import Licensing
import MQTTCore
import Observation
import ProxyCore
import TLSMitm

/// The sidebar sections of the main window.
public enum TrafficSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, http, mqtt, webSocket, issues

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All Traffic"
        case .http: "HTTP & HTTPS"
        case .mqtt: "MQTT"
        case .webSocket: "WebSocket"
        case .issues: "Issues"
        }
    }

    public var symbol: String {
        switch self {
        case .all: "list.bullet.rectangle"
        case .http: "globe"
        case .mqtt: "antenna.radiowaves.left.and.right"
        case .webSocket: "arrow.left.arrow.right"
        case .issues: "exclamationmark.triangle"
        }
    }

    public func includes(_ row: TrafficRow) -> Bool {
        switch self {
        case .all: true
        case .http: row.kind == .http
        case .mqtt: row.kind == .mqtt
        case .webSocket: row.kind == .webSocket
        case .issues: row.isIssue
        }
    }
}

/// One line of the traffic timeline.
public struct TrafficRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case http, mqtt, webSocket, tunnel, tls }

    public var id: Int64
    public var kind: Kind
    public var time: Date
    public var host: String
    public var summary: String
    /// Status code, MQTT packet type or WebSocket opcode.
    public var badge: String
    public var size: Int
    public var isIssue: Bool
    public var event: CaptureEvent

    init(_ stored: StoredCaptureEvent) {
        id = stored.id
        host = stored.host
        summary = stored.summary
        event = stored.event
        isIssue = false
        size = 0
        time = stored.timestamp
        switch stored.event {
        case .httpExchange(let e):
            kind = .http
            badge = e.statusCode.map(String.init) ?? "ERR"
            size = e.responseBody.count
            isIssue = e.error != nil || (e.statusCode ?? 0) >= 500
            summary = "\(e.method) \(e.url)"
        case .mqtt(let m):
            kind = .mqtt
            badge = "\(m.event.packet.type)".uppercased()
            size = m.event.frame.rawBytes.count
            summary = Self.mqttSummary(m.event)
            isIssue = Self.mqttIsFailure(m.event)
        case .webSocketMessage(let m):
            kind = .webSocket
            badge = "\(m.opcode)".uppercased()
            size = m.payload.count
        case .tunnelOpened:
            kind = .tunnel
            badge = "TUNNEL"
        case .tunnelClosed:
            kind = .tunnel
            badge = "CLOSED"
        case .tlsInterceptionFailed:
            kind = .tls
            badge = "PINNED?"
            isIssue = true
        case .mqttDecodingFailed:
            kind = .mqtt
            badge = "DECODE"
            isIssue = true
        case .webSocketDecodingFailed:
            kind = .webSocket
            badge = "DECODE"
            isIssue = true
        }
    }

    static func mqttSummary(_ event: MQTTSessionEvent) -> String {
        let arrow = event.direction == .clientToBroker ? "→" : "←"
        switch event.packet {
        case .connect(let c): return "\(arrow) client \(c.clientIdentifier.isEmpty ? "(auto)" : c.clientIdentifier), MQTT \(c.version)"
        case .publish(let p):
            let text = String(bytes: p.payload.prefix(80), encoding: .utf8).map { " " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
            return "\(arrow) \(event.resolvedTopic ?? p.topic)\(text)"
        case .subscribe(let s): return "\(arrow) " + s.subscriptions.map(\.topicFilter).joined(separator: ", ")
        case .unsubscribe(let u): return "\(arrow) " + u.topicFilters.joined(separator: ", ")
        case .connack(let a): return "\(arrow) " + MQTTDescriber.reasonName(a.reasonCode, connack: true, version: event.version)
        default: return "\(arrow) \(event.packet.type)"
        }
    }

    static func mqttIsFailure(_ event: MQTTSessionEvent) -> Bool {
        switch event.packet {
        case .connack(let a): a.reasonCode != 0
        case .suback(let a): a.reasonCodes.contains { $0 >= 0x80 }
        case .disconnect(let r): r.reasonCode >= 0x80
        default: false
        }
    }
}

/// State behind the main window: live capture, filtering, search, selection and the topic tree.
@MainActor
@Observable
public final class CaptureViewModel {
    public private(set) var rows: [TrafficRow] = []
    public private(set) var topicTree = TopicTree()
    public private(set) var searchResults: [TrafficRow]?
    public private(set) var isCapturing = false
    public private(set) var proxyPort: Int?
    public private(set) var lastError: String?
    /// True while this Mac's system proxy points at the capture proxy.
    public private(set) var systemProxyActive = false
    /// Hosts whose clients rejected our certificate and are not bypassed yet.
    public private(set) var pinnedHosts: [String] = []

    public var section: TrafficSection = .all
    /// The chip selected above the timeline.
    public var quickFilter: QuickFilter = .all
    /// Shows only this host's events when set (from the sidebar's Hosts list).
    public var hostFilter: String?
    /// Shows only HTTP requests with this method when set ("+ Filter" menu).
    public var methodFilter: String?
    /// Shows only HTTP responses in this class (2 for 2xx … 5 for 5xx) when set.
    public var statusClassFilter: Int?
    /// When the running capture started; nil while not capturing.
    public private(set) var captureStartedAt: Date?
    public var selection: TrafficRow.ID?
    public var configuration: EngineConfiguration {
        didSet { saveConfiguration?(configuration) }
    }
    public var searchText = "" {
        didSet { runSearch() }
    }
    /// Saved sessions the free tier keeps next to the one recording now; nil keeps them all. Nothing is
    /// deleted on its own: starting a session past the limit asks first (`sessionLimitPrompt`).
    public var savedSessionLimit: Int?
    /// Set when New Session needs the user to choose (free tier, saved sessions full). The main window
    /// shows it; `replaceAndStartNewSession` goes ahead.
    public var sessionLimitPrompt: SessionLimitPrompt?
    /// Saved sessions, newest first (the one recording now included). Refreshed by `reloadSessions()`.
    public private(set) var sessions: [CaptureSession] = []
    /// The saved session shown in the timeline instead of the live one; nil while showing live capture.
    public private(set) var viewedSession: CaptureSession?
    /// Set to open the Saved Sessions window (the view resets it).
    public var sessionsPresented = false
    /// The live timeline, kept aside (and still growing) while a saved session is shown.
    private var liveRows: [TrafficRow] = []
    private var liveTopicTree = TopicTree()

    public let store: CaptureStore
    /// HTTP breakpoints (Pro).
    public let breakpoints: BreakpointCenter
    /// MQTT publish and replay (Pro).
    public let composer: MQTTComposer
    /// Map Local, Map Remote and Rewrite rules (Pro).
    public let rewrites: RewriteCenter
    /// User scripts (Pro).
    public let scripts: ScriptCenter
    private let engine: CaptureEngine?
    private let saveConfiguration: ((EngineConfiguration) -> Void)?
    private let systemProxy: SystemProxyControlling?
    private var consumer: Task<Void, Never>?

    /// - Parameters:
    ///   - engine: nil for previews and tests that feed events through `ingest`.
    ///   - saveConfiguration: called whenever the configuration changes, to persist it.
    public init(store: CaptureStore, engine: CaptureEngine?, configuration: EngineConfiguration = .init(),
                systemProxy: SystemProxyControlling? = nil,
                saveConfiguration: ((EngineConfiguration) -> Void)? = nil,
                breakpoints: BreakpointCenter? = nil,
                composer: MQTTComposer? = nil,
                rewrites: RewriteCenter? = nil,
                scripts: ScriptCenter? = nil) {
        self.store = store
        self.engine = engine
        let breakpoints = breakpoints ?? BreakpointCenter()
        self.breakpoints = breakpoints
        self.composer = composer ?? MQTTComposer(publisher: engine?.makePublisher())
        engine?.breakpoints = breakpoints.handler
        let rewrites = rewrites ?? RewriteCenter()
        self.rewrites = rewrites
        engine?.rules = rewrites.rules
        let scripts = scripts ?? ScriptCenter()
        self.scripts = scripts
        engine?.scripts = scripts.live
        self.systemProxy = systemProxy
        self.configuration = configuration
        self.saveConfiguration = saveConfiguration
        if let engine {
            consumer = Task { [weak self] in
                for await event in engine.events {
                    self?.ingest(event)
                }
            }
        }
    }

    /// The configuration the engine is running with, to tell whether edits need a restart.
    public var runningConfiguration: EngineConfiguration? { engine?.runningConfiguration }
    /// The root CA used for HTTPS decryption; nil without an engine.
    public var authority: CertificateAuthority? { engine?.authority }

    // MARK: Pro

    /// Unlocks or locks the Pro tools for this entitlement.
    public func apply(_ entitlement: Entitlement) {
        breakpoints.isAllowed = entitlement.allows(.breakpoints)
        composer.isAllowed = entitlement.allows(.mqttPublish)
        rewrites.isAllowed = entitlement.allows(.mapRewrite)
        scripts.isAllowed = entitlement.allows(.scripting)
    }

    /// Starts a script from an HTTP exchange or a PUBLISH row and opens the scripts window on it.
    @discardableResult
    public func addScript(for row: TrafficRow) -> UserScript? {
        let script: UserScript
        switch row.event {
        case .httpExchange(let exchange):
            script = scripts.addScript(for: exchange)
        case .mqtt(let capture):
            guard case .publish = capture.event.packet, let topic = capture.event.resolvedTopic else { return nil }
            script = scripts.addScript(forTopic: topic)
        default:
            return nil
        }
        scripts.isPresented = true
        return script
    }

    /// Starts a map or rewrite rule from an HTTP row and opens the rules window on it.
    @discardableResult
    public func addRule(_ kind: HTTPRule.Kind, for row: TrafficRow) -> HTTPRule? {
        guard case .httpExchange(let exchange) = row.event else { return nil }
        let rule: HTTPRule
        switch kind {
        case .mapLocal: rule = rewrites.addMapLocal(from: exchange)
        case .mapRemote: rule = rewrites.addMapRemote(from: exchange)
        case .rewrite: rule = rewrites.addRewrite(from: exchange)
        }
        rewrites.isPresented = true
        return rule
    }

    /// Starts an MQTT rewrite rule for a PUBLISH row's topic and opens the rules window on it.
    @discardableResult
    public func addMQTTRule(for row: TrafficRow) -> MQTTRule? {
        guard case .mqtt(let capture) = row.event, case .publish = capture.event.packet,
              let topic = capture.event.resolvedTopic else { return nil }
        let rule = rewrites.addMQTTRule(topicFilter: topic)
        rewrites.isPresented = true
        return rule
    }

    /// Fills the composer with a captured PUBLISH, ready to send again. False when `row` isn't one.
    @discardableResult
    public func prepareReplay(of row: TrafficRow) -> Bool {
        guard case .mqtt(let capture) = row.event, case .publish = capture.event.packet else { return false }
        composer.prepareReplay(of: capture, forwarders: configuration.forwarders)
        return true
    }

    /// Fills the composer for a new message to `topic`, on the broker that topic was last seen on.
    public func preparePublish(toTopic topic: String) {
        let last = rows.last { row in
            guard case .mqtt(let capture) = row.event, case .publish = capture.event.packet else { return false }
            return capture.event.resolvedTopic == topic
        }
        var broker: String?
        var version: MQTTVersion?
        if case .mqtt(let capture)? = last?.event {
            broker = capture.broker
            version = capture.event.version
        } else if let forwarder = configuration.forwarders.first {
            broker = "\(forwarder.brokerHost):\(forwarder.brokerPort)"
        }
        composer.preparePublish(toTopic: topic, broker: broker, version: version, forwarders: configuration.forwarders)
    }

    /// Adds a breakpoint for the URL of an HTTP row (its method only).
    @discardableResult
    public func addBreakpoint(for row: TrafficRow) -> BreakpointRule? {
        guard case .httpExchange(let exchange) = row.event else { return nil }
        return breakpoints.addRule(for: exchange.url, method: exchange.method)
    }

    // MARK: Capture

    public func startCapture() async {
        guard let engine else { return }
        do {
            let port = try await engine.start(configuration)
            proxyPort = port
            isCapturing = true
            captureStartedAt = Date()
            lastError = nil
            await updateSystemProxy(port: port)
        } catch {
            isCapturing = false
            lastError = "Could not start capture: \(error)"
        }
    }

    public func stopCapture() async {
        await updateSystemProxy(port: nil)
        try? await engine?.stop()
        isCapturing = false
        proxyPort = nil
        captureStartedAt = nil
    }

    /// Turns the system proxy on for `port` when the configuration asks for it, or off when `port` is nil.
    func updateSystemProxy(port: Int?) async {
        guard let systemProxy else { return }
        do {
            if let port, configuration.setSystemProxy {
                try await systemProxy.enable(host: "127.0.0.1", port: port, bypass: configuration.bypassHosts)
                systemProxyActive = true
            } else if systemProxyActive {
                try await systemProxy.disable()
                systemProxyActive = false
            }
        } catch {
            lastError = port == nil
                ? "Couldn't switch the system proxy back: \(error). Check System Settings › Network › Proxies."
                : "Capture started, but the system proxy couldn't be set: \(error)"
        }
    }

    /// Starts a fresh session and clears the timeline. Earlier sessions stay in the store.
    public func newSession(named name: String = "Session") {
        returnToLive()
        do {
            let previous = store.currentSession
            try store.startSession(named: name)
            // A session that never recorded anything isn't worth keeping.
            if try store.events(in: previous, limit: 1).isEmpty { try? store.deleteSession(previous) }
            rows = []
            topicTree = TopicTree()
            selection = nil
            searchResults = nil
            searchText = ""
            hostFilter = nil
            methodFilter = nil
            statusClassFilter = nil
            reloadSessions()
        } catch {
            lastError = "Could not start a new session: \(error)"
        }
    }

    // MARK: Saved sessions

    /// The session the timeline, search and export work on.
    public var displayedSessionID: UUID { viewedSession?.id ?? store.currentSession }

    /// True for the session that new traffic is recorded into.
    public func isLive(_ session: CaptureSession) -> Bool { session.id == store.currentSession }

    public func reloadSessions() {
        do {
            sessions = try store.sessions()
            if let viewed = viewedSession { viewedSession = sessions.first { $0.id == viewed.id } }
        } catch {
            lastError = "Could not read saved sessions: \(error)"
        }
    }

    /// Shows a saved session in the timeline. Live capture keeps recording in the background.
    public func openSession(_ id: UUID) {
        guard id != store.currentSession else { return returnToLive() }
        do {
            let events = try store.allEvents(in: id)
            if viewedSession == nil {
                liveRows = rows
                liveTopicTree = topicTree
            }
            var tree = TopicTree()
            for stored in events {
                if case .mqtt(let m) = stored.event { tree.record(m.event, at: m.timestamp) }
            }
            rows = events.map(TrafficRow.init)
            topicTree = tree
            reloadSessions()
            viewedSession = sessions.first { $0.id == id }
            resetFilters()
        } catch {
            lastError = "Could not open the session: \(error)"
        }
    }

    /// Goes back to the live timeline.
    public func returnToLive() {
        guard viewedSession != nil else { return }
        viewedSession = nil
        rows = liveRows
        topicTree = liveTopicTree
        liveRows = []
        liveTopicTree = TopicTree()
        resetFilters()
    }

    /// Sessions other than the one recording now, newest first.
    public var savedSessions: [CaptureSession] { sessions.filter { !isLive($0) } }

    /// What starting a new session would replace on the free tier, or nil when it fits. Only a new
    /// session that adds a saved one asks: the one recording now must have events, and the saved
    /// sessions must already fill the limit. Sessions kept from before the limit count too, so the
    /// prompt can list several.
    public func sessionLimitPrompt(forNewSessionNamed name: String) -> SessionLimitPrompt? {
        guard let limit = savedSessionLimit else { return nil }
        reloadSessions()
        guard let live = sessions.first(where: { isLive($0) }), live.eventCount > 0 else { return nil }
        let saved = savedSessions
        guard saved.count >= limit else { return nil }
        // The session recording now takes one of the slots once it is saved.
        let replaced = Array(saved.dropFirst(max(0, limit - 1)))
        guard !replaced.isEmpty else { return nil }
        return SessionLimitPrompt(newSessionName: name, saving: live, replacing: replaced, limit: limit)
    }

    /// New Session from the menu: starts one, or sets `sessionLimitPrompt` when the free tier must ask.
    public func requestNewSession(named name: String) {
        if let prompt = sessionLimitPrompt(forNewSessionNamed: name) {
            sessionLimitPrompt = prompt
        } else {
            newSession(named: name)
        }
    }

    /// The user chose to replace: starts the new session, then deletes the sessions the prompt listed.
    public func replaceAndStartNewSession(_ prompt: SessionLimitPrompt) {
        if sessionLimitPrompt?.id == prompt.id { sessionLimitPrompt = nil }
        newSession(named: prompt.newSessionName)
        for session in prompt.replacing where !isLive(session) {
            do {
                try store.deleteSession(session.id)
            } catch {
                lastError = "Could not remove “\(session.name)”: \(error)"
            }
        }
        reloadSessions()
    }

    /// Free tier, at launch: every launch starts a session, so once the saved sessions are full the
    /// app keeps recording into the latest one instead of adding another. Nothing is deleted.
    /// Returns true when it switched.
    @discardableResult
    public func continueLatestSessionIfFull() -> Bool {
        guard let limit = savedSessionLimit, viewedSession == nil else { return false }
        reloadSessions()
        guard let live = sessions.first(where: { isLive($0) }), live.eventCount == 0 else { return false }
        let saved = savedSessions
        guard saved.count > limit, let latest = saved.first else { return false }
        do {
            try store.resumeSession(latest.id)
            let events = try store.allEvents(in: latest.id)
            var tree = TopicTree()
            for stored in events {
                if case .mqtt(let m) = stored.event { tree.record(m.event, at: m.timestamp) }
            }
            rows = events.map(TrafficRow.init)
            topicTree = tree
            resetFilters()
            reloadSessions()
            return true
        } catch {
            lastError = "Could not continue the last session: \(error)"
            return false
        }
    }

    public func renameSession(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.renameSession(id, to: trimmed)
            reloadSessions()
        } catch {
            lastError = "Could not rename the session: \(error)"
        }
    }

    /// Deletes a saved session for good. The session recording now can't be deleted.
    public func deleteSession(_ id: UUID) {
        guard id != store.currentSession else { return }
        if viewedSession?.id == id { returnToLive() }
        do {
            try store.deleteSession(id)
            reloadSessions()
        } catch {
            lastError = "Could not delete the session: \(error)"
        }
    }

    private func resetFilters() {
        selection = nil
        searchText = ""
        searchResults = nil
        hostFilter = nil
        methodFilter = nil
        statusClassFilter = nil
    }

    /// Stops decrypting `host` from now on and remembers it in the configuration.
    public func bypass(host: String) {
        engine?.bypass(host: host)
        if !configuration.bypassHosts.contains(host) { configuration.bypassHosts.append(host) }
        pinnedHosts.removeAll { $0 == host }
    }

    // MARK: Events

    /// Stores an event and adds it to the timeline.
    public func ingest(_ event: CaptureEvent) {
        do {
            let stored = try store.append(event)
            let row = TrafficRow(stored)
            if viewedSession == nil {
                rows.append(row)
                if case .mqtt(let m) = event { topicTree.record(m.event, at: m.timestamp) }
            } else {
                // A saved session is on screen; live capture carries on behind it.
                liveRows.append(row)
                if case .mqtt(let m) = event { liveTopicTree.record(m.event, at: m.timestamp) }
            }
            if case .tlsInterceptionFailed(let host, _, _) = event,
               !pinnedHosts.contains(host), !configuration.bypassHosts.contains(host) {
                pinnedHosts.append(host)
            }
            if !searchText.isEmpty, viewedSession == nil { runSearch() }
        } catch {
            lastError = "Could not save event: \(error)"
        }
    }

    // MARK: Presentation

    /// Rows for the current section, narrowed by the quick filter, host and search.
    public var visibleRows: [TrafficRow] {
        let section = section, filter = quickFilter, host = hostFilter, method = methodFilter, statusClass = statusClassFilter
        return (searchResults ?? rows).filter { row in
            section.includes(row) && filter.includes(row) && (host == nil || row.host == host)
                && (method == nil || (row.kind == .http && row.pill == method))
                && (statusClass == nil || (row.statusCode.map { $0 / 100 } == statusClass))
        }
    }

    /// The busiest hosts in this session, most events first.
    public func topHosts(limit: Int = 6) -> [HostCount] {
        var counts: [String: Int] = [:]
        for row in rows where !row.host.isEmpty { counts[row.host, default: 0] += 1 }
        return counts.map { HostCount(host: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
            .prefix(limit)
            .map { $0 }
    }

    /// The live session's rows, even while a saved session is on screen (for the recording capsule).
    public var liveTimeline: [TrafficRow] { viewedSession == nil ? rows : liveRows }

    /// Events per bucket over the last `buckets × bucketLength` seconds, for the activity sparkline.
    public func activity(buckets: Int = 24, bucketLength: TimeInterval = 5, now: Date = Date()) -> [Int] {
        ActivityHistogram.counts(of: liveTimeline.map(\.time), buckets: buckets, bucketLength: bucketLength, endingAt: now)
    }

    public var selectedRow: TrafficRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    public func count(in section: TrafficSection) -> Int {
        rows.lazy.filter(section.includes).count
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        do {
            let ids = Set(try store.search(query, in: displayedSessionID, limit: 5000).map(\.id))
            searchResults = rows.filter { ids.contains($0.id) }
        } catch {
            searchResults = []
        }
    }

    // MARK: Export

    /// Exports the session on screen, or `session` when given.
    public func exportHAR(session: UUID? = nil) throws -> Data { try store.exportHAR(session: session ?? displayedSessionID) }
    public func exportMQTT(session: UUID? = nil) throws -> Data { try store.exportMQTTJSONLines(session: session ?? displayedSessionID) }
}

/// Starting a new session on the free tier when its saved sessions are full.
public struct SessionLimitPrompt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The name the new session gets.
    public let newSessionName: String
    /// The session recording now, which becomes a saved session.
    public let saving: CaptureSession
    /// Older saved sessions that are deleted to make room, newest first.
    public let replacing: [CaptureSession]
    /// Saved sessions the free tier keeps.
    public let limit: Int

    public init(newSessionName: String, saving: CaptureSession, replacing: [CaptureSession], limit: Int) {
        self.newSessionName = newSessionName
        self.saving = saving
        self.replacing = replacing
        self.limit = limit
    }
}
