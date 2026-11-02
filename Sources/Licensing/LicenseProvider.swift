import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A store that issues and checks Pro license keys. `LemonSqueezyClient` is the one in use today;
/// another store (for example Paddle for payments with Keygen for keys) only needs a new conformance
/// and an entry in `LicenseConfiguration`, and nothing in the app or the entitlement rules changes.
///
/// Contract, which `LicenseManager` relies on:
/// - Returned licenses carry `provider == id`, the activation for this Mac in `instanceID`, and
///   `lastValidatedAt == now`.
/// - Failing to reach the store throws `LicenseError.network`, so Pro keeps working offline.
///   Every other error is a refusal and revokes a stored license on `validate`.
/// - `activate` throws `LicenseError.wrongProduct` or `.rejected` for keys it doesn't recognise,
///   so the next configured provider can be tried.
public protocol LicenseProvider: Sendable {
    /// Stable identifier saved with each license, e.g. `"lemonsqueezy"`. Never change it once shipped.
    var id: String { get }
    /// Shown to customers, e.g. "Your key is in the email from Lemon Squeezy".
    var storeName: String { get }

    /// Activates `key` for this Mac and returns the license to store.
    func activate(key: String, instanceName: String, now: Date) async throws -> StoredLicense
    /// Re-checks a stored license. A license the store no longer honours comes back with a non-active
    /// status (or the call throws a refusal).
    func validate(_ license: StoredLicense, now: Date) async throws -> StoredLicense
    /// Frees this Mac's activation so the key can be used on another Mac.
    func deactivate(_ license: StoredLicense) async throws
}

/// Sends one HTTP request and returns the body and status code. Injected in tests.
public typealias LicenseTransport = @Sendable (URLRequest) async throws -> (Data, Int)

public let defaultLicenseTransport: LicenseTransport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
}

public enum LicenseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The store rejected the request; `message` is its explanation (e.g. "license_key not found.").
    case rejected(String)
    /// The key belongs to another product or store.
    case wrongProduct
    case activationLimitReached
    case network(String)
    case unexpectedResponse
    /// The stored license came from a store this build no longer talks to.
    case unknownProvider(String)

    public var description: String {
        switch self {
        case .rejected(let message): "The license server said: \(message)"
        case .wrongProduct: "This key is for a different product. Check that you copied the Wiretide Pro key."
        case .activationLimitReached: "This key is already active on its maximum number of Macs. Deactivate it on another Mac first."
        case .network(let message): "Couldn't reach the license server: \(message)"
        case .unexpectedResponse: "The license server sent a response Wiretide didn't understand."
        case .unknownProvider: "This license came from a store this version of Wiretide can't check. Update Wiretide or contact support."
        }
    }
}
