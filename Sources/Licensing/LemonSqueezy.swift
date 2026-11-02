import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Lemon Squeezy License API (`/v1/licenses/activate|validate|deactivate`).
/// Those endpoints take the license key itself as the credential, so the app ships no API secret.
public struct LemonSqueezyClient: LicenseProvider {
    public typealias Transport = LicenseTransport
    public static let providerID = "lemonsqueezy"

    public var id: String { Self.providerID }
    public var storeName: String { "Lemon Squeezy" }

    /// Identifies our product so keys from other Lemon Squeezy stores are refused.
    public struct Product: Equatable, Sendable {
        public var storeID: Int
        public var productIDs: Set<Int>

        public init(storeID: Int, productIDs: Set<Int>) {
            self.storeID = storeID
            self.productIDs = productIDs
        }
    }

    public var baseURL: URL
    public var product: Product
    private let transport: Transport

    public init(product: Product, baseURL: URL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!,
                transport: Transport? = nil) {
        self.product = product
        self.baseURL = baseURL
        self.transport = transport ?? Self.urlSessionTransport
    }

    /// Activates `key` for this Mac and returns the license to store.
    public func activate(key: String, instanceName: String, now: Date = Date()) async throws -> StoredLicense {
        let response = try await post("activate", ["license_key": key, "instance_name": instanceName])
        guard response.activated == true else {
            throw Self.error(for: response)
        }
        return try license(from: response, key: key, instanceID: response.instance?.id, now: now)
    }

    /// Re-checks a stored license. Returns the refreshed license; a revoked one comes back with its new status.
    public func validate(_ stored: StoredLicense, now: Date = Date()) async throws -> StoredLicense {
        let response = try await post("validate", ["license_key": stored.key, "instance_id": stored.instanceID])
        if response.valid != true, response.licenseKey == nil {
            throw Self.error(for: response)
        }
        var refreshed = try license(from: response, key: stored.key, instanceID: stored.instanceID, now: now)
        if response.valid != true, refreshed.status == .active {
            // Valid key, but this Mac's instance was removed from the customer's account.
            refreshed.status = .inactive
        }
        return refreshed
    }

    /// Frees this Mac's activation so the key can be used on another Mac.
    public func deactivate(_ stored: StoredLicense) async throws {
        let response = try await post("deactivate", ["license_key": stored.key, "instance_id": stored.instanceID])
        guard response.deactivated == true else { throw Self.error(for: response) }
    }

    // MARK: Internals

    private func license(from response: Response, key: String, instanceID: String?, now: Date) throws -> StoredLicense {
        guard let licenseKey = response.licenseKey, let instanceID, let meta = response.meta else {
            throw LicenseError.unexpectedResponse
        }
        guard meta.storeID == product.storeID, product.productIDs.contains(meta.productID) else {
            throw LicenseError.wrongProduct
        }
        guard let purchasedAt = Self.date(licenseKey.createdAt) else { throw LicenseError.unexpectedResponse }
        return StoredLicense(
            provider: id,
            key: key,
            instanceID: instanceID,
            status: StoredLicense.Status(rawValue: licenseKey.status) ?? .disabled,
            customerName: meta.customerName,
            customerEmail: meta.customerEmail,
            purchasedAt: purchasedAt,
            expiresAt: licenseKey.expiresAt.flatMap(Self.date),
            lastValidatedAt: now
        )
    }

    private static func error(for response: Response) -> LicenseError {
        let message = response.error ?? "unknown error"
        if message.lowercased().contains("activation limit") { return .activationLimitReached }
        return .rejected(message)
    }

    private func post(_ endpoint: String, _ fields: [String: String]) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        request.timeoutInterval = 20

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch {
            throw LicenseError.network(error.localizedDescription)
        }
        // Server trouble and rate limits say nothing about the key, even when they come with a JSON
        // error, so they count as not reaching the store rather than as a refusal.
        if status >= 500 || status == 429 {
            throw LicenseError.network(status == 429 ? "too many requests, try again later" : "server error \(status)")
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LicenseError.unexpectedResponse
        }
        return response
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// Lemon Squeezy sends microseconds (`2024-01-24T14:15:07.000000Z`), which ISO8601DateFormatter can't parse.
    static func date(_ string: String) -> Date? {
        var trimmed = string
        if let dot = trimmed.firstIndex(of: "."), let zone = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            trimmed.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static let urlSessionTransport: Transport = defaultLicenseTransport

    struct Response: Decodable {
        struct LicenseKey: Decodable {
            var status: String
            var createdAt: String
            var expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case status
                case createdAt = "created_at"
                case expiresAt = "expires_at"
            }
        }

        struct Instance: Decodable {
            var id: String
        }

        struct Meta: Decodable {
            var storeID: Int
            var productID: Int
            var customerName: String?
            var customerEmail: String?

            enum CodingKeys: String, CodingKey {
                case storeID = "store_id"
                case productID = "product_id"
                case customerName = "customer_name"
                case customerEmail = "customer_email"
            }
        }

        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var licenseKey: LicenseKey?
        var instance: Instance?
        var meta: Meta?

        enum CodingKeys: String, CodingKey {
            case activated, valid, deactivated, error, instance, meta
            case licenseKey = "license_key"
        }
    }
}
