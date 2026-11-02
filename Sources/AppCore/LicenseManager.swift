import Foundation
import Licensing
import Observation

/// Build-time licensing settings. Store IDs come from the app's Info.plist
/// (`TWLemonSqueezyStoreID`, `TWLemonSqueezyProductIDs`), so release builds set them without code changes.
public struct LicenseConfiguration: Sendable {
    /// Stores this build accepts licenses from. New keys are tried against each in order; a stored
    /// license goes back to the provider that issued it. When moving to another store, put it first
    /// and keep the old one so existing customers' licenses still validate.
    public var providers: [any LicenseProvider]
    public var purchaseURL: URL?
    /// When this build was released; nil for development builds.
    public var releaseDate: Date?

    public init(providers: [any LicenseProvider], purchaseURL: URL?, releaseDate: Date?) {
        self.providers = providers
        self.purchaseURL = purchaseURL
        self.releaseDate = releaseDate
    }

    /// Reads `TWLemonSqueezyStoreID` (number), `TWLemonSqueezyProductIDs` (comma-separated),
    /// `TWPurchaseURL` and `TWReleaseDate` (`yyyy-MM-dd`) from an Info.plist dictionary.
    public init(infoDictionary info: [String: Any], transport: LicenseTransport? = nil) {
        var providers: [any LicenseProvider] = []
        if let product = Self.lemonSqueezyProduct(info) {
            providers.append(LemonSqueezyClient(product: product, transport: transport))
        }
        self.providers = providers
        purchaseURL = (info["TWPurchaseURL"] as? String).flatMap(URL.init(string:))
        releaseDate = (info["TWReleaseDate"] as? String).flatMap(Self.parseDay)
    }

    static func lemonSqueezyProduct(_ info: [String: Any]) -> LemonSqueezyClient.Product? {
        let storeID = (info["TWLemonSqueezyStoreID"] as? NSNumber)?.intValue
            ?? (info["TWLemonSqueezyStoreID"] as? String).flatMap { Int($0) }
        let products = Set(((info["TWLemonSqueezyProductIDs"] as? String) ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        guard let storeID, storeID > 0, !products.isEmpty else { return nil }
        return LemonSqueezyClient.Product(storeID: storeID, productIDs: products)
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
    private let providers: [any LicenseProvider]
    private let storage: LicenseStorage
    private let instanceName: String
    private let now: () -> Date
    /// The saved license exists but couldn't be read (for example a keychain error). Free-tier limits
    /// that delete data stay off until it can be read again.
    private var loadFailed = false

    public init(configuration: LicenseConfiguration, storage: LicenseStorage, policy: LicensePolicy = .standard,
                instanceName: String = LicenseManager.defaultInstanceName, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.policy = policy
        self.storage = storage
        self.instanceName = instanceName
        self.now = now
        providers = configuration.providers
        do {
            license = try storage.load()
        } catch {
            loadFailed = true
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
    public var isConfigured: Bool { !providers.isEmpty }

    /// Where customers bought their key: the stored license's store, else the one new keys go to first.
    public var storeName: String? {
        (license.flatMap { provider(for: $0) } ?? providers.first)?.storeName
    }

    private func provider(for license: StoredLicense) -> (any LicenseProvider)? {
        providers.first { $0.id == license.provider }
    }

    /// Saved sessions the free tier keeps; nil when there is no limit. The limit deletes old sessions, so
    /// it applies only to Macs that never had a license: a customer whose license lapsed, is offline
    /// past the grace period, or whose license couldn't be read keeps everything they captured.
    public var sessionLimit: Int? {
        guard license == nil, !loadFailed else { return nil }
        return policy.freeSessionLimit
    }

    public func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !providers.isEmpty else {
            lastError = "This build isn't connected to the license store. Use a release build from the website to activate Pro."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let activated = try await activateWithFirstMatchingProvider(key: key)
            try storage.save(activated)
            license = activated
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        recompute()
    }

    /// Tries each provider in order. A key one store doesn't know may belong to the next; the first
    /// store's answer is reported when none accepts it. Network errors and other failures stop the search.
    private func activateWithFirstMatchingProvider(key: String) async throws -> StoredLicense {
        var firstRefusal: Error?
        for provider in providers {
            do {
                return try await provider.activate(key: key, instanceName: instanceName, now: now())
            } catch let error as LicenseError {
                switch error {
                case .rejected, .wrongProduct: firstRefusal = firstRefusal ?? error
                default: throw error
                }
            }
        }
        throw firstRefusal ?? LicenseError.unexpectedResponse
    }

    /// Frees this Mac's activation on the store, then forgets the license here.
    public func deactivate() async {
        guard let license else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            // A license from a store this build can't reach is only forgotten here.
            do {
                try await provider(for: license)?.deactivate(license)
            } catch LicenseError.rejected {
                // The store no longer knows this activation (removed from the customer's account, or
                // a refunded key), so there is nothing to free there; forget it here.
            }
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
        guard let license, !providers.isEmpty else { return }
        guard let provider = provider(for: license) else {
            // Leave the license as is: the offline grace period still applies, and an update that
            // knows this store again will validate it.
            lastError = String(describing: LicenseError.unknownProvider(license.provider))
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let refreshed = try await provider.validate(license, now: now())
            try storage.save(refreshed)
            self.license = refreshed
            lastError = nil
        } catch LicenseError.network(let message) {
            lastError = "Couldn't check the license (\(message)). Pro keeps working offline for up to \(Int(policy.offlineGracePeriod / 86_400)) days."
        } catch let error as LicenseError where error == .unexpectedResponse {
            // Often a captive portal or a proxy's error page rather than the store: treat it as offline.
            lastError = "Couldn't check the license (\(error)). Pro keeps working offline for up to \(Int(policy.offlineGracePeriod / 86_400)) days."
        } catch let error as LicenseError {
            var revoked = license
            revoked.status = .disabled
            try? storage.save(revoked)
            self.license = revoked
            lastError = String(describing: error)
        } catch {
            // Saving the refreshed license failed (a keychain error): keep the one we have.
            lastError = "Couldn't save the license: \(error)"
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
