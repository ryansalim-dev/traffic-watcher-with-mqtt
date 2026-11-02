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

    func includes(_ row: TrafficRow) -> Bool {
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
    /// Saved sessions to keep (free tier); nil keeps them all. Older sessions are deleted when it is set
    /// and whenever a new session starts.
    public var sessionLimit: Int? {
        didSet { applySessionLimit() }
    }

    public let store: CaptureStore
    /// HTTP breakpoints (Pro).
    public let breakpoints: BreakpointCenter
    /// MQTT publish and replay (Pro).
    public let composer: MQTTComposer
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
                composer: MQTTComposer? = nil) {
        self.store = store
        self.engine = engine
        let breakpoints = breakpoints ?? BreakpointCenter()
        self.breakpoints = breakpoints
        self.composer = composer ?? MQTTComposer(publisher: engine?.makePublisher())
        engine?.breakpoints = breakpoints.handler
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
        do {
            try store.startSession(named: name)
            applySessionLimit()
            rows = []
            topicTree = TopicTree()
            selection = nil
            searchResults = nil
            searchText = ""
            hostFilter = nil
            methodFilter = nil
            statusClassFilter = nil
        } catch {
            lastError = "Could not start a new session: \(error)"
        }
    }

    /// Stops decrypting `host` from now on and remembers it in the configuration.
    public func bypass(host: String) {
        engine?.bypass(host: host)
        if !configuration.bypassHosts.contains(host) { configuration.bypassHosts.append(host) }
        pinnedHosts.removeAll { $0 == host }
    }

    private func applySessionLimit() {
        guard let sessionLimit else { return }
        do {
            try store.pruneSessions(keepingNewest: sessionLimit)
        } catch {
            lastError = "Could not remove old sessions: \(error)"
        }
    }

    // MARK: Events

    /// Stores an event and adds it to the timeline.
    public func ingest(_ event: CaptureEvent) {
        do {
            let stored = try store.append(event)
            let row = TrafficRow(stored)
            rows.append(row)
            if case .mqtt(let m) = event { topicTree.record(m.event, at: m.timestamp) }
            if case .tlsInterceptionFailed(let host, _, _) = event,
               !pinnedHosts.contains(host), !configuration.bypassHosts.contains(host) {
                pinnedHosts.append(host)
            }
            if !searchText.isEmpty { runSearch() }
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

    /// Events per bucket over the last `buckets × bucketLength` seconds, for the activity sparkline.
    public func activity(buckets: Int = 24, bucketLength: TimeInterval = 5, now: Date = Date()) -> [Int] {
        ActivityHistogram.counts(of: rows.map(\.time), buckets: buckets, bucketLength: bucketLength, endingAt: now)
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
            let ids = Set(try store.search(query, in: store.currentSession, limit: 5000).map(\.id))
            searchResults = rows.filter { ids.contains($0.id) }
        } catch {
            searchResults = []
        }
    }

    // MARK: Export

    public func exportHAR() throws -> Data { try store.exportHAR(session: store.currentSession) }
    public func exportMQTT() throws -> Data { try store.exportMQTTJSONLines(session: store.currentSession) }
}
