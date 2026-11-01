import Foundation
import MQTTCore
import Observation
import ProxyCore

/// State behind the Publish sheet (Pro): the broker to connect to, the message, and how many
/// times to send it. Replay fills it from a captured PUBLISH.
@MainActor
@Observable
public final class MQTTComposer {
    public enum PayloadFormat: String, CaseIterable, Identifiable, Sendable {
        case text = "Text", hex = "Hex"
        public var id: String { rawValue }
    }

    public var target: MQTTBrokerTarget {
        didSet { saveTarget?(target) }
    }
    public var topic = ""
    public var payloadText = ""
    public var payloadFormat = PayloadFormat.text
    public var qos = MQTTQoS.atMostOnce
    public var retain = false
    /// MQTT 5 only.
    public var contentType = ""
    public var userProperties: [MQTTOutgoingMessage.UserProperty] = []
    /// Properties copied from a replayed message that the sheet doesn't edit (response topic, correlation data…).
    private var replayedExtras: MQTTOutgoingMessage?

    /// How many times to send the message; 1 is a single publish.
    public var repeatCount = 1
    /// Pause between repeats, in milliseconds.
    public var intervalMilliseconds = 0

    /// Whether the license allows publishing.
    public var isAllowed = false
    /// Drives the Publish sheet, so any view can open it after filling the composer in.
    public var isPresented = false
    public private(set) var isSending = false
    public private(set) var sentCount = 0
    /// One line about the last send, success or failure.
    public private(set) var status: Status?

    public enum Status: Equatable, Sendable {
        case sent(count: Int, to: String)
        case partlyRefused(accepted: Int, refused: Int, firstReason: UInt8)
        case failed(String)
    }

    private let publisher: MQTTPublisher?
    private let saveTarget: ((MQTTBrokerTarget) -> Void)?
    private var sending: Task<Void, Never>?

    public init(publisher: MQTTPublisher?, target: MQTTBrokerTarget = MQTTBrokerTarget(host: "localhost"),
                saveTarget: ((MQTTBrokerTarget) -> Void)? = nil) {
        self.publisher = publisher
        self.target = target
        self.saveTarget = saveTarget
    }

    // MARK: Filling in

    /// Prepares a replay of a captured PUBLISH: same topic, payload, QoS, retain flag and v5 properties,
    /// sent to the broker it was captured from.
    public func prepareReplay(of capture: MQTTCaptureEvent, forwarders: [ForwarderConfiguration]) {
        guard case .publish(let publish) = capture.event.packet else { return }
        let message = MQTTOutgoingMessage(replaying: publish, resolvedTopic: capture.event.resolvedTopic)
        load(message)
        replayedExtras = message
        target = Self.target(forBroker: capture.broker, version: capture.event.version, forwarders: forwarders, keeping: target)
        repeatCount = 1
        status = nil
    }

    /// Prepares a new message to `topic` on the broker the topic was seen on.
    public func preparePublish(toTopic topic: String, broker: String?, version: MQTTVersion?, forwarders: [ForwarderConfiguration]) {
        load(MQTTOutgoingMessage(topic: topic, payload: []))
        replayedExtras = nil
        if let broker {
            target = Self.target(forBroker: broker, version: version ?? target.version, forwarders: forwarders, keeping: target)
        }
        status = nil
    }

    private func load(_ message: MQTTOutgoingMessage) {
        topic = message.topic
        qos = message.qos
        retain = message.retain
        contentType = message.contentType ?? ""
        userProperties = message.userProperties
        if let text = String(bytes: message.payload, encoding: .utf8), !text.contains("\0") {
            payloadFormat = .text
            payloadText = text
        } else {
            payloadFormat = .hex
            payloadText = Self.hexString(message.payload)
        }
    }

    /// The broker a capture came from (`host:port`), with TLS taken from the matching forwarder.
    static func target(forBroker broker: String, version: MQTTVersion, forwarders: [ForwarderConfiguration],
                       keeping current: MQTTBrokerTarget) -> MQTTBrokerTarget {
        var target = current
        target.version = version
        if let forwarder = forwarders.first(where: { "\($0.brokerHost):\($0.brokerPort)" == broker }) {
            target.host = forwarder.brokerHost
            target.port = forwarder.brokerPort
            target.useTLS = forwarder.useTLS
        } else if let colon = broker.lastIndex(of: ":"), let port = Int(broker[broker.index(after: colon)...]) {
            target.host = String(broker[..<colon])
            target.port = port
            target.useTLS = port == 8883
        }
        return target
    }

    // MARK: Building the message

    /// The payload bytes, or nil when the hex isn't valid.
    public var payload: [UInt8]? {
        switch payloadFormat {
        case .text: Array(payloadText.utf8)
        case .hex: Self.bytes(fromHex: payloadText)
        }
    }

    public var message: MQTTOutgoingMessage? {
        guard let payload else { return nil }
        var message = MQTTOutgoingMessage(topic: topic, payload: payload, qos: qos, retain: retain,
                                          contentType: contentType.isEmpty ? nil : contentType,
                                          userProperties: userProperties.filter { !$0.key.isEmpty })
        if let extras = replayedExtras {
            message.responseTopic = extras.responseTopic
            message.correlationData = extras.correlationData
            message.messageExpiryInterval = extras.messageExpiryInterval
            message.payloadIsUTF8 = extras.payloadIsUTF8 && payloadFormat == .text
        }
        return message
    }

    /// Why Send is disabled, or nil when it's ready.
    public var problem: String? {
        if !isAllowed { return "Publishing and replay are part of Pro." }
        if target.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the broker's host." }
        if !(1...65535).contains(target.port) { return "The port must be between 1 and 65535." }
        guard let message else { return "The payload isn't valid hex." }
        if let topicProblem = message.topicProblem { return topicProblem }
        if !(1...10_000).contains(repeatCount) { return "Send between 1 and 10,000 times." }
        return nil
    }

    // MARK: Sending

    public func send() {
        guard problem == nil, let message, let publisher, !isSending else { return }
        let messages = Array(repeating: message, count: repeatCount)
        let target = self.target
        let interval = Duration.milliseconds(max(0, intervalMilliseconds))
        isSending = true
        sentCount = 0
        status = nil
        sending = Task {
            do {
                let outcomes = try await publisher.publish(messages, to: target, interval: interval) { done in
                    Task { @MainActor [weak self] in self?.sentCount = done }
                }
                let refused = outcomes.filter { !$0.accepted }
                if let first = refused.first {
                    status = .partlyRefused(accepted: outcomes.count - refused.count, refused: refused.count, firstReason: first.reasonCode)
                } else {
                    status = .sent(count: outcomes.count, to: target.label)
                }
            } catch is CancellationError {
                status = .failed("Stopped after \(sentCount) of \(messages.count).")
            } catch {
                status = .failed(String(describing: error))
            }
            isSending = false
        }
    }

    /// Stops a repeat run between messages.
    public func cancel() {
        sending?.cancel()
    }

    // MARK: Hex

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Accepts pairs of hex digits with optional whitespace, `0x` prefixes and colons.
    static func bytes(fromHex text: String) -> [UInt8]? {
        let cleaned = text.replacingOccurrences(of: "0x", with: "").filter { !$0.isWhitespace && $0 != ":" }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
