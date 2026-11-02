import Foundation

/// How long each phase of an upstream HTTP exchange took, in seconds.
public struct HTTPTiming: Equatable, Sendable, Codable {
    /// Resolving the host name.
    public var dns: TimeInterval
    /// Opening the TCP connection.
    public var connect: TimeInterval
    /// The TLS handshake, or nil for plain HTTP.
    public var tls: TimeInterval?
    /// From the connection being ready to the first byte of the response (sending included).
    public var waiting: TimeInterval
    /// From the first byte of the response to the last.
    public var download: TimeInterval

    public init(dns: TimeInterval, connect: TimeInterval, tls: TimeInterval?, waiting: TimeInterval, download: TimeInterval) {
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.waiting = waiting
        self.download = download
    }

    public var total: TimeInterval { dns + connect + (tls ?? 0) + waiting + download }

    public enum Phase: String, CaseIterable, Identifiable, Sendable {
        case dns = "DNS", connect = "Connect", tls = "TLS", waiting = "Waiting", download = "Download"
        public var id: String { rawValue }
    }

    /// The phases in order with their durations, leaving out TLS for plain HTTP.
    public var phases: [(phase: Phase, duration: TimeInterval)] {
        var list: [(Phase, TimeInterval)] = [(.dns, dns), (.connect, connect)]
        if let tls { list.append((.tls, tls)) }
        list.append((.waiting, waiting))
        list.append((.download, download))
        return list
    }
}

/// Collects the moments an upstream exchange passes each phase. Only touched on the channel's event loop.
final class PhaseClock: @unchecked Sendable {
    let start = DispatchTime.now()
    var resolved: DispatchTime?
    var connected: DispatchTime?
    var secured: DispatchTime?
    var firstByte: DispatchTime?
    var finished: DispatchTime?

    var timing: HTTPTiming? {
        guard let connected, let firstByte else { return nil }
        let end = finished ?? firstByte
        let resolved = min(self.resolved ?? start, connected)
        let ready = secured ?? connected
        return HTTPTiming(
            dns: Self.seconds(start, resolved),
            connect: Self.seconds(resolved, connected),
            tls: secured.map { Self.seconds(connected, $0) },
            waiting: Self.seconds(ready, firstByte),
            download: Self.seconds(firstByte, end)
        )
    }

    static func seconds(_ from: DispatchTime, _ to: DispatchTime) -> TimeInterval {
        guard to.uptimeNanoseconds > from.uptimeNanoseconds else { return 0 }
        return TimeInterval(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000_000
    }
}
