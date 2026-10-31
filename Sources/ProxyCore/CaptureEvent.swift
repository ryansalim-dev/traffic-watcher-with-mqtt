import Foundation
import MQTTCore

/// A header as seen on the wire, order and case preserved.
public struct CapturedHeader: Equatable, Sendable {
    public var name: String
    public var value: String
}

/// One plain-HTTP request and its response (or the error that replaced it).
public struct HTTPExchange: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var method: String
    public var url: String
    public var requestHeaders: [CapturedHeader]
    public var requestBody: [UInt8]
    public var statusCode: Int?
    public var responseHeaders: [CapturedHeader]
    public var responseBody: [UInt8]
    public var error: String?
}

/// A CONNECT tunnel the proxy relayed without decrypting.
public struct TunnelInfo: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var openedAt: Date
    public var host: String
    public var port: Int
}

/// One MQTT packet seen on a forwarded connection.
public struct MQTTCaptureEvent: Equatable, Sendable {
    public var connectionID: UUID
    public var timestamp: Date
    public var broker: String
    public var event: MQTTSessionEvent
}

public enum CaptureEvent: Equatable, Sendable {
    case httpExchange(HTTPExchange)
    case tunnelOpened(TunnelInfo)
    case tunnelClosed(id: UUID, bytesFromClient: Int, bytesFromServer: Int)
    case mqtt(MQTTCaptureEvent)
    /// Decoding stopped for this connection; bytes are still relayed untouched.
    case mqttDecodingFailed(connectionID: UUID, reason: String)
    /// The client rejected the generated certificate (often certificate pinning). Consider
    /// adding the host to the interceptor's bypass list.
    case tlsInterceptionFailed(host: String, port: Int, reason: String)
}

/// Receives capture events. Called from NIO event loops, so implementations must be thread-safe.
public protocol CaptureSink: Sendable {
    func record(_ event: CaptureEvent)
}

/// Thread-safe in-memory sink, handy for tests and small sessions.
public final class CaptureLog: CaptureSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CaptureEvent] = []

    public init() {}

    public func record(_ event: CaptureEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    public var events: [CaptureEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Bridges capture events into an `AsyncStream` for SwiftUI or other async consumers.
public struct AsyncStreamCaptureSink: CaptureSink {
    public let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    public init(bufferingPolicy: AsyncStream<CaptureEvent>.Continuation.BufferingPolicy = .bufferingNewest(10_000)) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: bufferingPolicy)
    }

    public func record(_ event: CaptureEvent) {
        continuation.yield(event)
    }

    public func finish() {
        continuation.finish()
    }
}
