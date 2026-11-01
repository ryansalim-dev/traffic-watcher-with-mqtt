import Foundation

/// Identifiers shared by the app, the helper's launchd plist and the packaging script.
public enum HelperIdentity {
    public static let machServiceName = "app.wiretide.Wiretide.Helper"
    public static let launchdPlistName = "app.wiretide.Wiretide.Helper.plist"
    public static let appBundleIdentifier = "app.wiretide.Wiretide"
    /// Bumped whenever the XPC interface changes, so the app can tell an outdated helper to re-register.
    public static let protocolVersion = 1
}

/// A value from a network service's Proxies dictionary that we may change, or its absence.
public enum ProxyValue: Codable, Equatable, Sendable {
    case int(Int)
    case string(String)
    case strings([String])
    case absent

    public init(_ any: Any?) {
        switch any {
        case let number as NSNumber: self = .int(number.intValue)
        case let int as Int: self = .int(int)
        case let string as String: self = .string(string)
        case let strings as [String]: self = .strings(strings)
        default: self = .absent
        }
    }

    /// The Foundation value to store, or nil to remove the key.
    public var foundationValue: Any? {
        switch self {
        case .int(let value): NSNumber(value: value)
        case .string(let value): value
        case .strings(let value): value
        case .absent: nil
        }
    }
}

/// Turns the system HTTP and HTTPS proxy on for each network service, remembering exactly the keys it
/// changed so they can be put back. PAC, SOCKS and every other setting are left alone.
/// Keys are SystemConfiguration's `kSCPropNetProxies*` names.
public enum SystemProxyPlan {
    public static let httpEnable = "HTTPEnable", httpProxy = "HTTPProxy", httpPort = "HTTPPort"
    public static let httpsEnable = "HTTPSEnable", httpsProxy = "HTTPSProxy", httpsPort = "HTTPSPort"
    public static let exceptions = "ExceptionsList"

    public static let managedKeys = [httpEnable, httpProxy, httpPort, httpsEnable, httpsProxy, httpsPort, exceptions]

    /// Hosts that should never go through the proxy, added to the user's own exceptions.
    public static let defaultExceptions = ["127.0.0.1", "localhost", "*.local", "169.254/16"]

    /// What to remember about one service so `restoring` can undo `enabling`.
    public typealias Backup = [String: ProxyValue]

    public static func backup(of proxies: [String: Any]) -> Backup {
        Dictionary(uniqueKeysWithValues: managedKeys.map { ($0, ProxyValue(proxies[$0])) })
    }

    public static func enabling(_ proxies: [String: Any], host: String, port: Int, bypass: [String] = []) -> [String: Any] {
        var updated = proxies
        updated[httpEnable] = NSNumber(value: 1)
        updated[httpProxy] = host
        updated[httpPort] = NSNumber(value: port)
        updated[httpsEnable] = NSNumber(value: 1)
        updated[httpsProxy] = host
        updated[httpsPort] = NSNumber(value: port)
        var exceptionList = (proxies[exceptions] as? [String]) ?? []
        for host in defaultExceptions + bypass where !exceptionList.contains(host) {
            exceptionList.append(host)
        }
        updated[exceptions] = exceptionList
        return updated
    }

    public static func restoring(_ proxies: [String: Any], from backup: Backup) -> [String: Any] {
        var restored = proxies
        for key in managedKeys {
            restored[key] = (backup[key] ?? .absent).foundationValue
        }
        return restored
    }

    /// True when `proxies` already points HTTP and HTTPS at `host:port`.
    public static func isEnabled(_ proxies: [String: Any], host: String, port: Int) -> Bool {
        ProxyValue(proxies[httpEnable]) == .int(1) && ProxyValue(proxies[httpProxy]) == .string(host)
            && ProxyValue(proxies[httpPort]) == .int(port) && ProxyValue(proxies[httpsEnable]) == .int(1)
    }
}

/// Backups for every service the helper changed, kept on disk so a crash or reboot can be undone.
public struct SystemProxyBackup: Codable, Equatable, Sendable {
    /// Network service ID → original values of the managed keys.
    public var services: [String: SystemProxyPlan.Backup]
    public var createdAt: Date

    public init(services: [String: SystemProxyPlan.Backup], createdAt: Date = Date()) {
        self.services = services
        self.createdAt = createdAt
    }

    public static func load(from url: URL) -> SystemProxyBackup? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(SystemProxyBackup.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

#if canImport(ObjectiveC)
/// The helper's XPC interface. Replies carry an error message, or nil on success.
@objc public protocol WiretideHelperProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
    /// Points the HTTP and HTTPS proxy of every enabled network service at `host:port`.
    /// The helper restores the previous settings when `disableSystemProxy` is called or when
    /// this connection closes (the app quit or crashed).
    func enableSystemProxy(host: String, port: Int, bypass: [String], reply: @escaping (String?) -> Void)
    func disableSystemProxy(reply: @escaping (String?) -> Void)
}
#endif
