import CaptureStore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import ProxyCore
import TLSMitm

/// A local MQTT forwarder the user configured: the app connects to `listenPort`, the forwarder
/// relays to the broker.
public struct ForwarderConfiguration: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var brokerHost: String
    public var brokerPort: Int
    public var listenPort: Int
    public var useTLS: Bool

    public init(brokerHost: String, brokerPort: Int? = nil, listenPort: Int = 18830, useTLS: Bool = false) {
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort ?? (useTLS ? 8883 : 1883)
        self.listenPort = listenPort
        self.useTLS = useTLS
    }

    public var label: String { "\(brokerHost):\(brokerPort)\(useTLS ? " (TLS)" : "")" }
}

public struct EngineConfiguration: Codable, Equatable, Sendable {
    public var proxyPort = 9090
    /// Listen on all interfaces so physical devices on the same network can use the proxy.
    public var allowRemoteDevices = false
    public var decryptHTTPS = true
    public var bypassHosts: [String] = []
    public var forwarders: [ForwarderConfiguration] = []
    /// Point this Mac's system HTTP/HTTPS proxy at Wiretide while capturing (needs the helper).
    public var setSystemProxy = false

    public init() {}

    var listenHost: String { allowRemoteDevices ? "0.0.0.0" : "127.0.0.1" }

    private enum CodingKeys: String, CodingKey {
        case proxyPort, allowRemoteDevices, decryptHTTPS, bypassHosts, forwarders, setSystemProxy
    }

    /// Missing keys keep their defaults, so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? proxyPort
        allowRemoteDevices = try container.decodeIfPresent(Bool.self, forKey: .allowRemoteDevices) ?? allowRemoteDevices
        decryptHTTPS = try container.decodeIfPresent(Bool.self, forKey: .decryptHTTPS) ?? decryptHTTPS
        bypassHosts = try container.decodeIfPresent([String].self, forKey: .bypassHosts) ?? bypassHosts
        forwarders = try container.decodeIfPresent([ForwarderConfiguration].self, forKey: .forwarders) ?? forwarders
        setSystemProxy = try container.decodeIfPresent(Bool.self, forKey: .setSystemProxy) ?? setSystemProxy
    }
}

/// Switches the Mac's system proxy to the capture proxy and back. The app implements it with the
/// privileged helper; tests use a fake.
public protocol SystemProxyControlling: Sendable {
    func enable(host: String, port: Int, bypass: [String]) async throws
    func disable() async throws
}

/// Keeps the local root CA in a directory (`ca.pem`, `ca-key.pem`, key file mode 0600) and
/// creates it on first use. The app passes its Application Support folder.
public struct CertificateStorage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var certificateURL: URL { directory.appendingPathComponent("ca.pem") }
    var keyURL: URL { directory.appendingPathComponent("ca-key.pem") }

    public func loadOrCreate() throws -> CertificateAuthority {
        if let certificate = try? String(contentsOf: certificateURL, encoding: .utf8),
           let key = try? String(contentsOf: keyURL, encoding: .utf8) {
            return try CertificateAuthority(certificatePEM: certificate, privateKeyPEM: key)
        }
        let authority = try CertificateAuthority.generate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try authority.certificatePEM.write(to: certificateURL, atomically: true, encoding: .utf8)
        _ = FileManager.default.createFile(
            atPath: keyURL.path,
            contents: Data(authority.privateKeyPEM.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        return authority
    }

    /// Writes the root as DER (`.cer`), the format `simctl` and macOS Keychain Access accept.
    public func exportDER(_ authority: CertificateAuthority) throws -> URL {
        let url = directory.appendingPathComponent("WiretideCA.cer")
        try Data(authority.certificateDER).write(to: url)
        return url
    }
}

/// Owns the event loop group, the proxy and the MQTT forwarders, and streams their events.
public final class CaptureEngine: @unchecked Sendable {
    public let authority: CertificateAuthority
    public let interceptor: TLSInterceptor
    public let events: AsyncStream<CaptureEvent>

    private let sink: AsyncStreamCaptureSink
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var proxy: HTTPProxyServer?
    private var forwarders: [UUID: MQTTForwarder] = [:]
    private var _runningConfiguration: EngineConfiguration?
    private var _breakpoints: HTTPBreakpointHandler?

    public init(authority: CertificateAuthority, threads: Int = System.coreCount) {
        self.authority = authority
        interceptor = TLSInterceptor(authority: authority)
        sink = AsyncStreamCaptureSink()
        events = sink.events
        group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threads))
    }

    deinit {
        sink.finish()
        try? group.syncShutdownGracefully()
    }

    public var isRunning: Bool { lock.withLock { proxy != nil } }

    /// Pauses matching HTTP exchanges for editing. Read when capture starts.
    public var breakpoints: HTTPBreakpointHandler? {
        get { lock.withLock { _breakpoints } }
        set { lock.withLock { _breakpoints = newValue } }
    }

    /// A publisher on this engine's event loops whose traffic lands in the capture stream.
    public func makePublisher() -> MQTTPublisher {
        MQTTPublisher(group: group, sink: sink)
    }
    public var runningConfiguration: EngineConfiguration? { lock.withLock { _runningConfiguration } }

    /// Starts the proxy and every forwarder. Returns the proxy's bound port. Stops anything
    /// already running first, so it also applies a changed configuration.
    @discardableResult
    public func start(_ configuration: EngineConfiguration) async throws -> Int {
        try await stop()
        interceptor.bypass = configuration.bypassHosts

        var proxyConfiguration = HTTPProxyServer.Configuration()
        proxyConfiguration.interceptor = configuration.decryptHTTPS ? interceptor : nil
        proxyConfiguration.breakpoints = breakpoints
        let proxy = HTTPProxyServer(group: group, sink: sink, configuration: proxyConfiguration)
        let port = try await proxy.start(host: configuration.listenHost, port: configuration.proxyPort)

        var started: [UUID: MQTTForwarder] = [:]
        do {
            for forwarder in configuration.forwarders {
                let instance = MQTTForwarder(
                    group: group,
                    sink: sink,
                    brokerHost: forwarder.brokerHost,
                    brokerPort: forwarder.brokerPort,
                    tls: forwarder.useTLS ? .init(interceptor: interceptor) : nil
                )
                try await instance.start(host: configuration.listenHost, port: forwarder.listenPort)
                started[forwarder.id] = instance
            }
        } catch {
            try? await proxy.stop()
            for instance in started.values { try? await instance.stop() }
            throw error
        }

        lock.withLock {
            self.proxy = proxy
            forwarders = started
            _runningConfiguration = configuration
        }
        return port
    }

    public func stop() async throws {
        let (proxy, forwarders) = lock.withLock {
            defer { self.proxy = nil; self.forwarders = [:]; _runningConfiguration = nil }
            return (self.proxy, self.forwarders)
        }
        try await proxy?.stop()
        for forwarder in forwarders.values { try await forwarder.stop() }
    }

    /// Adds a host to the decryption bypass list at runtime (e.g. after a pinning failure).
    public func bypass(host: String) {
        guard !interceptor.bypass.contains(host.lowercased()) else { return }
        interceptor.bypass.append(host)
    }
}

/// Commands for trusting the root CA in the iOS Simulator.
public enum SimulatorTools {
    /// `xcrun simctl keychain <device> add-root-cert <path>`; `device` is a UDID or `booted`.
    public static func addRootCertificateArguments(certificatePath: String, device: String = "booted") -> [String] {
        ["xcrun", "simctl", "keychain", device, "add-root-cert", certificatePath]
    }

    /// Runs `simctl` and returns its combined output; throws when it exits non-zero.
    public static func installRootCertificate(at url: URL, device: String = "booted") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = addRootCertificateArguments(certificatePath: url.path, device: device)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SimulatorToolsError.commandFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}

public enum SimulatorToolsError: Error, Equatable, CustomStringConvertible {
    case commandFailed(status: Int32, output: String)

    public var description: String {
        switch self {
        case .commandFailed(let status, let output):
            "simctl exited with \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
