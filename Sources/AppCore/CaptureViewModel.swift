import CaptureStore
import Foundation
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
        case .tunnelOpened(let t):
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
    /// Hosts whose clients rejected our certificate and are not bypassed yet.
    public private(set) var pinnedHosts: [String] = []

    public var section: TrafficSection = .all
    public var selection: TrafficRow.ID?
    public var configuration: EngineConfiguration {
        didSet { saveConfiguration?(configuration) }
    }
    public var searchText = "" {
        didSet { runSearch() }
    }

    public let store: CaptureStore
    private let engine: CaptureEngine?
    private let saveConfiguration: ((EngineConfiguration) -> Void)?
    private var consumer: Task<Void, Never>?

    /// - Parameters:
    ///   - engine: nil for previews and tests that feed events through `ingest`.
    ///   - saveConfiguration: called whenever the configuration changes, to persist it.
    public init(store: CaptureStore, engine: CaptureEngine?, configuration: EngineConfiguration = .init(),
                saveConfiguration: ((EngineConfiguration) -> Void)? = nil) {
        self.store = store
        self.engine = engine
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

    // MARK: Capture

    public func startCapture() async {
        guard let engine else { return }
        do {
            proxyPort = try await engine.start(configuration)
            isCapturing = true
            lastError = nil
        } catch {
            isCapturing = false
            lastError = "Could not start capture: \(error)"
        }
    }

    public func stopCapture() async {
        try? await engine?.stop()
        isCapturing = false
        proxyPort = nil
    }

    /// Starts a fresh session and clears the timeline. Earlier sessions stay in the store.
    public func newSession(named name: String = "Session") {
        do {
            try store.startSession(named: name)
            rows = []
            topicTree = TopicTree()
            selection = nil
            searchResults = nil
            searchText = ""
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

    /// Rows for the current section, narrowed by the search when there is one.
    public var visibleRows: [TrafficRow] {
        (searchResults ?? rows).filter(section.includes)
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
