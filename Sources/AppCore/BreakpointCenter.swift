import Foundation
import Observation
import ProxyCore

/// One exchange held at a breakpoint, waiting for the user.
public struct PausedExchange: Identifiable, Equatable, Sendable {
    public enum Stage: Sendable { case request, response }

    public let id: UUID
    public let stage: Stage
    public let pausedAt: Date
    /// At the request stage, the request to edit; at the response stage, the request that was sent.
    public let request: HTTPRequestDraft
    /// The response to edit; nil at the request stage.
    public let response: HTTPResponseDraft?

    public var title: String { "\(request.method) \(request.url)" }
}

/// Owns the breakpoint rules (Pro) and the exchanges paused by them. The proxy talks to it through
/// `handler`; the UI edits the paused exchanges and resumes or aborts them.
@MainActor
@Observable
public final class BreakpointCenter {
    public var rules: [BreakpointRule] {
        didSet {
            handler.update(rules: rules, active: isActive)
            save?(rules)
        }
    }
    /// The master switch in the toolbar. Turning it off lets everything that is paused continue.
    public var isEnabled = true {
        didSet { activeChanged() }
    }
    /// Whether the license allows breakpoints. Without Pro the rules are kept but nothing pauses.
    public var isAllowed = false {
        didSet { activeChanged() }
    }
    /// Paused exchanges, oldest first.
    public private(set) var paused: [PausedExchange] = []
    /// A paused exchange nobody answers continues unchanged after this long, before most clients give up.
    public var timeout: Duration

    /// Hand this to the capture engine.
    public let handler: Handler
    private let save: (([BreakpointRule]) -> Void)?
    private var waiters: [UUID: Waiter] = [:]

    private enum Waiter {
        case request(CheckedContinuation<BreakpointResolution<HTTPRequestDraft>, Never>, HTTPRequestDraft)
        case response(CheckedContinuation<BreakpointResolution<HTTPResponseDraft>, Never>, HTTPResponseDraft)
    }

    public init(rules: [BreakpointRule] = [], timeout: Duration = .seconds(300), save: (([BreakpointRule]) -> Void)? = nil) {
        self.rules = rules
        self.timeout = timeout
        self.save = save
        handler = Handler()
        handler.center = self
        handler.update(rules: rules, active: isActive)
    }

    /// True when matching requests actually pause.
    public var isActive: Bool { isEnabled && isAllowed }

    // MARK: Rules

    /// Adds a rule for exactly this URL (query dropped), or re-enables the one that already exists.
    @discardableResult
    public func addRule(for url: String, method: String? = nil, stages: BreakpointStages = [.request, .response]) -> BreakpointRule {
        let pattern = Self.pattern(for: url)
        if let index = rules.firstIndex(where: { $0.pattern == pattern && $0.method == method }) {
            rules[index].isEnabled = true
            rules[index].stages.formUnion(stages)
            return rules[index]
        }
        let rule = BreakpointRule(pattern: pattern, method: method, stages: stages)
        rules.append(rule)
        return rule
    }

    /// A pattern for `url` without its query or fragment, so the rule survives changing parameters.
    static func pattern(for url: String) -> String {
        var pattern = url
        if let cut = pattern.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pattern = String(pattern[..<cut]) + "*"
        }
        return pattern
    }

    // MARK: Answering

    /// Sends the request on, with the user's edits.
    public func resume(_ id: UUID, request: HTTPRequestDraft) {
        guard case .request(let continuation, _) = waiters.removeValue(forKey: id) else { return }
        paused.removeAll { $0.id == id }
        continuation.resume(returning: .proceed(request))
    }

    /// Sends the response on to the client, with the user's edits.
    public func resume(_ id: UUID, response: HTTPResponseDraft) {
        guard case .response(let continuation, _) = waiters.removeValue(forKey: id) else { return }
        paused.removeAll { $0.id == id }
        continuation.resume(returning: .proceed(response))
    }

    /// Lets the exchange continue exactly as it arrived.
    public func resumeUnchanged(_ id: UUID) {
        switch waiters.removeValue(forKey: id) {
        case .request(let continuation, let original): continuation.resume(returning: .proceed(original))
        case .response(let continuation, let original): continuation.resume(returning: .proceed(original))
        case nil: return
        }
        paused.removeAll { $0.id == id }
    }

    /// Drops the exchange; the client gets an error response.
    public func abort(_ id: UUID) {
        switch waiters.removeValue(forKey: id) {
        case .request(let continuation, _): continuation.resume(returning: .abort)
        case .response(let continuation, _): continuation.resume(returning: .abort)
        case nil: return
        }
        paused.removeAll { $0.id == id }
    }

    public func resumeAll() {
        for item in paused { resumeUnchanged(item.id) }
    }

    // MARK: Pausing (called through the handler)

    func pause(request: HTTPRequestDraft) async -> BreakpointResolution<HTTPRequestDraft> {
        guard isActive else { return .proceed(request) }
        return await withCheckedContinuation { continuation in
            let item = PausedExchange(id: UUID(), stage: .request, pausedAt: Date(), request: request, response: nil)
            waiters[item.id] = .request(continuation, request)
            hold(item)
        }
    }

    func pause(response: HTTPResponseDraft, for request: HTTPRequestDraft) async -> BreakpointResolution<HTTPResponseDraft> {
        guard isActive else { return .proceed(response) }
        return await withCheckedContinuation { continuation in
            let item = PausedExchange(id: UUID(), stage: .response, pausedAt: Date(), request: request, response: response)
            waiters[item.id] = .response(continuation, response)
            hold(item)
        }
    }

    private func hold(_ item: PausedExchange) {
        paused.append(item)
        let timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeUnchanged(item.id)
        }
    }

    private func activeChanged() {
        handler.update(rules: rules, active: isActive)
        if !isActive { resumeAll() }
    }

    /// The proxy's view of the center: a lock-protected copy of the rules for the event loop, and
    /// a hop to the main actor when something pauses.
    public final class Handler: HTTPBreakpointHandler, @unchecked Sendable {
        private let lock = NSLock()
        private var rules: [BreakpointRule] = []
        private var active = false
        private weak var _center: BreakpointCenter?

        fileprivate var center: BreakpointCenter? {
            get { lock.withLock { _center } }
            set { lock.withLock { _center = newValue } }
        }

        fileprivate func update(rules: [BreakpointRule], active: Bool) {
            lock.withLock {
                self.rules = rules
                self.active = active
            }
        }

        public func stages(method: String, url: String) -> BreakpointStages {
            lock.withLock { active ? rules.stages(method: method, url: url) : [] }
        }

        public func editRequest(_ request: HTTPRequestDraft) async -> BreakpointResolution<HTTPRequestDraft> {
            guard let center else { return .proceed(request) }
            return await center.pause(request: request)
        }

        public func editResponse(_ response: HTTPResponseDraft, for request: HTTPRequestDraft) async -> BreakpointResolution<HTTPResponseDraft> {
            guard let center else { return .proceed(response) }
            return await center.pause(response: response, for: request)
        }
    }
}

// MARK: Editing helpers

/// Headers as editable text, one `Name: value` per line, and back.
public enum HeaderText {
    public static func format(_ headers: [CapturedHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// Lines without a colon or with an empty name are ignored.
    public static func parse(_ text: String) -> [CapturedHeader] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return CapturedHeader(name: name, value: value)
        }
    }
}
