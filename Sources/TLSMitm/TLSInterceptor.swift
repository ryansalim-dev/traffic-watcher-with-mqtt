import Foundation
import NIOSSL

/// Decides which hosts get decrypted and hands out cached per-host server contexts.
public final class TLSInterceptor: @unchecked Sendable {
    public let authority: CertificateAuthority
    private let lock = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]
    private var bypassPatterns: [String]

    /// - Parameter bypass: hosts relayed without decryption, such as apps that pin certificates.
    ///   `*.example.com` matches subdomains only; `example.com` matches exactly.
    public init(authority: CertificateAuthority, bypass: [String] = []) {
        self.authority = authority
        self.bypassPatterns = bypass.map { $0.lowercased() }
    }

    public var bypass: [String] {
        get { lock.lock(); defer { lock.unlock() }; return bypassPatterns }
        set { lock.lock(); defer { lock.unlock() }; bypassPatterns = newValue.map { $0.lowercased() } }
    }

    public func shouldIntercept(host: String) -> Bool {
        let host = host.lowercased()
        return !bypass.contains { pattern in
            if pattern.hasPrefix("*.") {
                return host.hasSuffix(pattern.dropFirst())
            }
            return host == pattern
        }
    }

    /// Server-side TLS context presenting a leaf for `host`, issued on first use.
    public func serverContext(for host: String) throws -> NIOSSLContext {
        try serverContext(forHosts: [host])
    }

    /// Server-side TLS context presenting one leaf valid for all of `hosts`, issued on first use.
    public func serverContext(forHosts hosts: [String]) throws -> NIOSSLContext {
        let key = hosts.map { $0.lowercased() }.joined(separator: ",")
        lock.lock()
        if let cached = contexts[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let context = try NIOSSLContext(configuration: authority.issueLeaf(for: hosts).serverTLSConfiguration())
        lock.lock(); defer { lock.unlock() }
        if let raced = contexts[key] { return raced }
        contexts[key] = context
        return context
    }
}
