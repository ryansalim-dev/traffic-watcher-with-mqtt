import Foundation
import Licensing
import Observation

/// Build-time licensing settings. The store and product IDs come from the app's Info.plist
/// (`TWLemonSqueezyStoreID`, `TWLemonSqueezyProductIDs`), so release builds set them without code changes.
public struct LicenseConfiguration: Sendable {
    public var product: LemonSqueezyClient.Product?
    public var purchaseURL: URL?
    /// When this build was released; nil for development builds.
    public var releaseDate: Date?

    public init(product: LemonSqueezyClient.Product?, purchaseURL: URL?, releaseDate: Date?) {
        self.product = product
        self.purchaseURL = purchaseURL
        self.releaseDate = releaseDate
    }

    /// Reads `TWLemonSqueezyStoreID` (number), `TWLemonSqueezyProductIDs` (comma-separated),
    /// `TWPurchaseURL` and `TWReleaseDate` (`yyyy-MM-dd`) from an Info.plist dictionary.
    public init(infoDictionary info: [String: Any]) {
        let storeID = (info["TWLemonSqueezyStoreID"] as? NSNumber)?.intValue
            ?? (info["TWLemonSqueezyStoreID"] as? String).flatMap { Int($0) }
        let products = Set(((info["TWLemonSqueezyProductIDs"] as? String) ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        product = storeID.flatMap { $0 > 0 && !products.isEmpty ? LemonSqueezyClient.Product(storeID: $0, productIDs: products) : nil }
        purchaseURL = (info["TWPurchaseURL"] as? String).flatMap(URL.init(string:))
        releaseDate = (info["TWReleaseDate"] as? String).flatMap(Self.parseDay)
    }

    static func parseDay(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

/// Owns the Pro license: activation, background re-validation, and the resulting entitlement.
@MainActor
@Observable
public final class LicenseManager {
    public private(set) var license: StoredLicense?
    public private(set) var entitlement: Entitlement = .free(.noLicense)
    public private(set) var isWorking = false
    public private(set) var lastError: String?

    public let configuration: LicenseConfiguration
    public let policy: LicensePolicy
    private let client: LemonSqueezyClient?
    private let storage: LicenseStorage
    private let instanceName: String
    private let now: () -> Date

    public init(configuration: LicenseConfiguration, storage: LicenseStorage, policy: LicensePolicy = .standard,
                instanceName: String = LicenseManager.defaultInstanceName,
                transport: LemonSqueezyClient.Transport? = nil, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.policy = policy
        self.storage = storage
        self.instanceName = instanceName
        self.now = now
        client = configuration.product.map { LemonSqueezyClient(product: $0, transport: transport) }
        do {
            license = try storage.load()
        } catch {
            lastError = "Couldn't read the saved license: \(error)"
        }
        recompute()
    }

    public nonisolated static var defaultInstanceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// False in builds without store IDs (development builds); activation then explains why it can't run.
    public var isConfigured: Bool { client != nil }

    /// Saved sessions the free tier keeps; nil when Pro.
    public var sessionLimit: Int? { entitlement.allows(.unlimitedSessions) ? nil : policy.freeSessionLimit }

    public func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard let client else {
            lastError = "This build isn't connected to the license store. Use a release build from the website to activate Pro."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let activated = try await client.activate(key: key, instanceName: instanceName, now: now())
            try storage.save(activated)
            license = activated
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        recompute()
    }

    /// Frees this Mac's activation on the store, then forgets the license here.
    public func deactivate() async {
        guard let license else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client?.deactivate(license)
            try storage.clear()
            self.license = nil
            lastError = nil
        } catch {
            lastError = "\(error) The license is still active on this Mac."
        }
        recompute()
    }

    /// Re-validates when the last check is older than the policy's interval. Call on launch and when the app becomes active.
    public func refreshIfNeeded() async {
        guard let license, now().timeIntervalSince(license.lastValidatedAt) >= policy.revalidationInterval else { return }
        await refresh()
    }

    /// Re-validates now. Network failures keep the license (Pro works offline for the grace period);
    /// a refusal from the store revokes it.
    public func refresh() async {
        guard let license, let client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let refreshed = try await client.validate(license, now: now())
            try storage.save(refreshed)
            self.license = refreshed
            lastError = nil
        } catch LicenseError.network(let message) {
            lastError = "Couldn't check the license (\(message)). Pro keeps working offline for up to \(Int(policy.offlineGracePeriod / 86_400)) days."
        } catch {
            var revoked = license
            revoked.status = .disabled
            try? storage.save(revoked)
            self.license = revoked
            lastError = String(describing: error)
        }
        recompute()
    }

    public func recompute() {
        entitlement = Entitlement.evaluate(license, now: now(), releaseDate: configuration.releaseDate, policy: policy)
    }

    /// One line for the status bar and the License tab.
    public var summary: String {
        switch entitlement {
        case .pro(let until):
            "Pro · updates until \(until.formatted(date: .abbreviated, time: .omitted))"
        case .free(.noLicense):
            "Free"
        case .free(.revoked):
            "Free · license deactivated"
        case .free(.expired(let date)):
            "Free · license expired \(date.formatted(date: .abbreviated, time: .omitted))"
        case .free(.updatesEnded(let until, _)):
            "Free · this version is newer than your updates (until \(until.formatted(date: .abbreviated, time: .omitted)))"
        case .free(.needsValidation):
            "Free · connect to the internet to check your license"
        }
    }
}
