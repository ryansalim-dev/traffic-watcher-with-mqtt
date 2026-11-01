import Foundation
import MQTTCore

/// A header as seen on the wire, order and case preserved.
public struct CapturedHeader: Equatable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One plain-HTTP request and its response (or the error that replaced it).
public struct HTTPExchange: Equatable, Sendable, Identifiable, Codable {
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

    public init(id: UUID = UUID(), startedAt: Date, duration: TimeInterval, method: String, url: String,
                requestHeaders: [CapturedHeader], requestBody: [UInt8], statusCode: Int?,
                responseHeaders: [CapturedHeader], responseBody: [UInt8], error: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.error = error
    }
}

/// A CONNECT tunnel the proxy relayed without decrypting.
public struct TunnelInfo: Equatable, Sendable, Identifiable, Codable {
    public var id: UUID
    public var openedAt: Date
    public var host: String
    public var port: Int

    public init(id: UUID = UUID(), openedAt: Date, host: String, port: Int) {
        self.id = id
        self.openedAt = openedAt
        self.host = host
        self.port = port
    }
}

/// One MQTT packet seen on a forwarded connection.
public struct MQTTCaptureEvent: Equatable, Sendable {
    public var connectionID: UUID
    public var timestamp: Date
    public var broker: String
    public var event: MQTTSessionEvent

    public init(connectionID: UUID, timestamp: Date, broker: String, event: MQTTSessionEvent) {
        self.connectionID = connectionID
        self.timestamp = timestamp
        self.broker = broker
        self.event = event
    }
}

public enum WebSocketDirection: String, Equatable, Sendable, Codable {
    case clientToServer
    case serverToClient
}

/// One complete WebSocket message (fragments joined, payload unmasked) on a non-MQTT socket.
public struct WebSocketMessage: Equatable, Sendable, Codable {
    public var connectionID: UUID
    public var timestamp: Date
    public var url: String
    public var direction: WebSocketDirection
    public var opcode: WebSocketOpcode
    public var payload: [UInt8]

    public init(connectionID: UUID, timestamp: Date, url: String, direction: WebSocketDirection,
                opcode: WebSocketOpcode, payload: [UInt8]) {
        self.connectionID = connectionID
        self.timestamp = timestamp
        self.url = url
        self.direction = direction
        self.opcode = opcode
        self.payload = payload
    }
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
    case webSocketMessage(WebSocketMessage)
    /// Frame parsing stopped for this socket; bytes are still relayed untouched.
    case webSocketDecodingFailed(connectionID: UUID, reason: String)
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
