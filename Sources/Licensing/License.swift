import Foundation

/// What the app knows about an activated license, persisted between launches.
public struct StoredLicense: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case active, inactive, expired, disabled
    }

    public var key: String
    /// The Lemon Squeezy instance created for this Mac on activation.
    public var instanceID: String
    public var status: Status
    public var customerName: String?
    public var customerEmail: String?
    /// When the license was bought; the update window starts here.
    public var purchasedAt: Date
    /// Set only for licenses the store made time-limited.
    public var expiresAt: Date?
    /// Last time the store confirmed the license. Pro keeps working offline for a grace period after it.
    public var lastValidatedAt: Date

    public init(key: String, instanceID: String, status: Status, customerName: String? = nil, customerEmail: String? = nil,
                purchasedAt: Date, expiresAt: Date? = nil, lastValidatedAt: Date) {
        self.key = key
        self.instanceID = instanceID
        self.status = status
        self.customerName = customerName
        self.customerEmail = customerEmail
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.lastValidatedAt = lastValidatedAt
    }

    /// Key with all but the last 4 characters hidden, for display.
    public var maskedKey: String {
        let tail = key.suffix(4)
        return String(repeating: "•", count: max(0, min(key.count, 12) - tail.count)) + tail
    }
}

/// Terms of the Pro license: perpetual use of any version released within the update window.
public struct LicensePolicy: Equatable, Sendable {
    /// Versions released up to this long after purchase are covered.
    public var updateWindow: DateComponents
    /// How long Pro keeps working without reaching the store.
    public var offlineGracePeriod: TimeInterval
    /// After this long since the last check, the app re-validates in the background.
    public var revalidationInterval: TimeInterval
    /// Saved capture sessions kept on the free tier (the current one included).
    public var freeSessionLimit: Int

    public init(updateWindow: DateComponents = DateComponents(year: 1),
                offlineGracePeriod: TimeInterval = 30 * 86_400,
                revalidationInterval: TimeInterval = 3 * 86_400,
                freeSessionLimit: Int = 3) {
        self.updateWindow = updateWindow
        self.offlineGracePeriod = offlineGracePeriod
        self.revalidationInterval = revalidationInterval
        self.freeSessionLimit = freeSessionLimit
    }

    public static let standard = LicensePolicy()

    public func updatesCovered(until purchase: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(byAdding: updateWindow, to: purchase) ?? purchase
    }
}

/// Features that need Pro. The free tier captures and inspects everything; Pro adds tools on top.
public enum ProFeature: String, CaseIterable, Sendable {
    case unlimitedSessions
    case mqttPublish
    case breakpoints
    case mapRewrite
    case scripting

    public var title: String {
        switch self {
        case .unlimitedSessions: "Unlimited saved sessions"
        case .mqttPublish: "MQTT publish and replay"
        case .breakpoints: "Breakpoints"
        case .mapRewrite: "Map and rewrite"
        case .scripting: "Scripting"
        }
    }
}

public enum Entitlement: Equatable, Sendable {
    public enum FreeReason: Equatable, Sendable {
        case noLicense
        /// The store reports the license as refunded, disabled or deactivated.
        case revoked
        case expired(Date)
        /// This version came out after the license's update window closed.
        case updatesEnded(coveredUntil: Date, released: Date)
        /// The license could not be checked for longer than the offline grace period.
        case needsValidation(since: Date)
    }

    case free(FreeReason)
    case pro(coveredUntil: Date)

    public var isPro: Bool {
        if case .pro = self { true } else { false }
    }

    public func allows(_ feature: ProFeature) -> Bool { isPro }

    /// Decides the entitlement from the stored license. Pure, so every rule is unit-tested.
    /// - Parameter releaseDate: when this build was released; nil for development builds,
    ///   which skip the update-window rule.
    public static func evaluate(_ license: StoredLicense?, now: Date, releaseDate: Date?,
                                policy: LicensePolicy = .standard) -> Entitlement {
        guard let license else { return .free(.noLicense) }
        switch license.status {
        case .disabled, .inactive: return .free(.revoked)
        case .expired: return .free(.expired(license.expiresAt ?? license.lastValidatedAt))
        case .active: break
        }
        if let expiresAt = license.expiresAt, now >= expiresAt {
            return .free(.expired(expiresAt))
        }
        if now.timeIntervalSince(license.lastValidatedAt) > policy.offlineGracePeriod {
            return .free(.needsValidation(since: license.lastValidatedAt))
        }
        let coveredUntil = policy.updatesCovered(until: license.purchasedAt)
        if let releaseDate, releaseDate > coveredUntil {
            return .free(.updatesEnded(coveredUntil: coveredUntil, released: releaseDate))
        }
        return .pro(coveredUntil: coveredUntil)
    }
}
