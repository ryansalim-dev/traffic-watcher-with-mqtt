#if os(macOS)
import AppCore
import Foundation
import HelperCore
import Observation
import ServiceManagement

/// Installs the privileged helper with SMAppService and talks to it over XPC.
/// macOS asks the user once to allow it in System Settings › General › Login Items.
@MainActor
@Observable
final class SystemProxyHelper {
    enum State: Equatable {
        /// Not inside a signed .app (e.g. `swift run`), so there is nothing to register.
        case unavailable
        case notInstalled
        case needsApproval
        case installed
        case failed(String)
    }

    private(set) var state: State = .unavailable
    private let service: SMAppService?

    init(bundle: Bundle = .main) {
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperIdentity.launchdPlistName)")
        if bundle.bundleURL.pathExtension == "app", FileManager.default.fileExists(atPath: plist.path) {
            service = SMAppService.daemon(plistName: HelperIdentity.launchdPlistName)
        } else {
            service = nil
        }
        refresh()
    }

    func refresh() {
        guard let service else {
            state = .unavailable
            return
        }
        switch service.status {
        case .enabled: state = .installed
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: state = .notInstalled
        @unknown default: state = .notInstalled
        }
    }

    func install() {
        guard let service else { return }
        do {
            try service.register()
            refresh()
        } catch {
            refresh()
            if state != .needsApproval { state = .failed(error.localizedDescription) }
        }
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() {
        guard let service else { return }
        Task {
            try? await service.unregister()
            refresh()
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// One XPC connection per capture session. Closing it (or the app exiting) makes the helper restore the
/// previous proxy settings, so the connection is kept open between `enable` and `disable`.
final class HelperConnection: SystemProxyControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    struct HelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func enable(host: String, port: Int, bypass: [String]) async throws {
        try await call { helper, reply in helper.enableSystemProxy(host: host, port: port, bypass: bypass, reply: reply) }
    }

    func disable() async throws {
        try await call { helper, reply in helper.disableSystemProxy(reply: reply) }
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: WiretideHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func call(_ body: @escaping (WiretideHelperProtocol, @escaping (String?) -> Void) -> Void) async throws {
        let connection = currentConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.run {
                    continuation.resume(throwing: HelperError(message:
                        "The helper isn't available. Install it in Settings › Proxy. (\(error.localizedDescription))"))
                }
            }
            guard let helper = proxy as? WiretideHelperProtocol else {
                return once.run { continuation.resume(throwing: HelperError(message: "The helper has an unexpected interface.")) }
            }
            body(helper) { message in
                once.run {
                    if let message {
                        continuation.resume(throwing: HelperError(message: message))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// XPC can report an error after a reply; resume the continuation only once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}
#endif
