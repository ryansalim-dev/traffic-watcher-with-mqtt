#if os(macOS)
import Foundation
import HelperCore
import Security
import SystemConfiguration

/// Root daemon registered by the app with SMAppService. It does one privileged job: switch the
/// system HTTP/HTTPS proxy to Traffic Watcher while capturing, and always switch it back, even when
/// the app quits or crashes (the XPC connection closes) or the Mac restarts (a backup on disk).

let backupURL = URL(fileURLWithPath: "/Library/Application Support/TrafficWatcher/SystemProxyBackup.plist")

enum ProxyStore {
    /// Applies `change` to the Proxies protocol of every enabled network service, in one commit.
    /// Returns the service IDs it changed.
    static func update(_ change: (_ serviceID: String, _ proxies: [String: Any]) -> [String: Any]?) throws -> [String] {
        guard let prefs = SCPreferencesCreate(nil, "TrafficWatcherHelper" as CFString, nil) else { throw HelperError.systemConfiguration("open") }
        guard SCPreferencesLock(prefs, true) else { throw HelperError.systemConfiguration("lock") }
        defer { SCPreferencesUnlock(prefs) }

        var changed: [String] = []
        for service in (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? [] where SCNetworkServiceGetEnabled(service) {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proxiesProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = (SCNetworkProtocolGetConfiguration(proxiesProtocol) as? [String: Any]) ?? [:]
            guard let updated = change(id, current) else { continue }
            guard SCNetworkProtocolSetConfiguration(proxiesProtocol, updated as CFDictionary) else {
                throw HelperError.systemConfiguration("set \(id)")
            }
            changed.append(id)
        }
        guard SCPreferencesCommitChanges(prefs) else { throw HelperError.systemConfiguration("commit") }
        guard SCPreferencesApplyChanges(prefs) else { throw HelperError.systemConfiguration("apply") }
        return changed
    }
}

enum HelperError: Error, CustomStringConvertible {
    case systemConfiguration(String)
    var description: String {
        switch self {
        case .systemConfiguration(let step): "Couldn't change network settings (\(step)): \(String(cString: SCErrorString(SCError())))"
        }
    }
}

/// Serializes all proxy changes on one queue and tracks which connection turned the proxy on.
final class ProxyManager: @unchecked Sendable {
    static let shared = ProxyManager()
    private let queue = DispatchQueue(label: "TrafficWatcherHelper.proxy")
    private var owner: ObjectIdentifier?

    func enable(host: String, port: Int, bypass: [String], for connection: ObjectIdentifier) -> String? {
        queue.sync {
            do {
                // Keep the oldest backup: if a previous session never restored, its backup holds the user's real settings.
                var backup = SystemProxyBackup.load(from: backupURL) ?? SystemProxyBackup(services: [:])
                _ = try ProxyStore.update { id, proxies in
                    if backup.services[id] == nil { backup.services[id] = SystemProxyPlan.backup(of: proxies) }
                    return SystemProxyPlan.enabling(proxies, host: host, port: port, bypass: bypass)
                }
                try backup.save(to: backupURL)
                owner = connection
                return nil
            } catch {
                return String(describing: error)
            }
        }
    }

    func disable(for connection: ObjectIdentifier) -> String? {
        queue.sync {
            if owner != connection { return nil } // not the session that turned it on
            return restoreLocked()
        }
    }

    /// Restores a backup left by a crash or restart. Called once at launch.
    func restoreStaleBackup() {
        queue.sync { _ = restoreLocked() }
    }

    private func restoreLocked() -> String? {
        guard let backup = SystemProxyBackup.load(from: backupURL) else {
            owner = nil
            return nil
        }
        do {
            _ = try ProxyStore.update { id, proxies in
                backup.services[id].map { SystemProxyPlan.restoring(proxies, from: $0) }
            }
            try? FileManager.default.removeItem(at: backupURL)
            owner = nil
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

final class HelperService: NSObject, TrafficWatcherHelperProtocol {
    let connection: ObjectIdentifier

    init(connection: ObjectIdentifier) {
        self.connection = connection
    }

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(HelperIdentity.protocolVersion)
    }

    func enableSystemProxy(host: String, port: Int, bypass: [String], reply: @escaping (String?) -> Void) {
        guard (1...65_535).contains(port), !host.isEmpty, host.count < 256 else { return reply("Invalid proxy address") }
        reply(ProxyManager.shared.enable(host: host, port: port, bypass: Array(bypass.prefix(200)), for: connection))
    }

    func disableSystemProxy(reply: @escaping (String?) -> Void) {
        reply(ProxyManager.shared.disable(for: connection))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// Only the Traffic Watcher app signed by the same team as this helper may connect.
    let requirement: String?

    override init() {
        requirement = Self.clientRequirement()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            NSLog("TrafficWatcherHelper: refusing connection, the helper is not signed with a team ID")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        let id = ObjectIdentifier(connection)
        let service = HelperService(connection: id)
        connection.exportedInterface = NSXPCInterface(with: TrafficWatcherHelperProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = {
            // The app quit or crashed: put the user's network settings back.
            _ = ProxyManager.shared.disable(for: id)
        }
        connection.resume()
        return true
    }

    /// `identifier "<app>" and anchor apple generic and certificate leaf[subject.OU] = "<our team>"`.
    static func clientRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return "identifier \"\(HelperIdentity.appBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

ProxyManager.shared.restoreStaleBackup()
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
#else
print("TrafficWatcherHelper runs on macOS only.")
#endif
