import Foundation

/// What the app knows about an activated license, persisted between launches.
public struct StoredLicense: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case active, inactive, expired, disabled
    }

    /// The `LicenseProvider.id` that issued this license; validation and deactivation go back to it.
    public var provider: String
    public var key: String
    /// The activation the provider created for this Mac (a Lemon Squeezy instance, a Keygen machine, …).
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

    public init(provider: String = LemonSqueezyClient.providerID, key: String, instanceID: String, status: Status,
                customerName: String? = nil, customerEmail: String? = nil,
                purchasedAt: Date, expiresAt: Date? = nil, lastValidatedAt: Date) {
        self.provider = provider
        self.key = key
        self.instanceID = instanceID
        self.status = status
        self.customerName = customerName
        self.customerEmail = customerEmail
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.lastValidatedAt = lastValidatedAt
    }

    enum CodingKeys: String, CodingKey {
        case provider, key, instanceID, status, customerName, customerEmail, purchasedAt, expiresAt, lastValidatedAt
    }

    /// Licenses saved before providers existed have no `provider`; they all came from Lemon Squeezy.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? LemonSqueezyClient.providerID
        key = try container.decode(String.self, forKey: .key)
        instanceID = try container.decode(String.self, forKey: .instanceID)
        status = try container.decode(Status.self, forKey: .status)
        customerName = try container.decodeIfPresent(String.self, forKey: .customerName)
        customerEmail = try container.decodeIfPresent(String.self, forKey: .customerEmail)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        lastValidatedAt = try container.decode(Date.self, forKey: .lastValidatedAt)
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
    /// Saved capture sessions the free tier keeps next to the one recording now.
    public var freeSavedSessions: Int
    /// Enabled rules of each kind (breakpoint, Map Local, Map Remote, Rewrite, MQTT Rewrite, script)
    /// that work at the same time on the free tier.
    public var freeActiveRules: Int
    /// Captured MQTT messages the free tier can resend, unchanged, in each capture session.
    public var freeReplaysPerSession: Int

    public init(updateWindow: DateComponents = DateComponents(year: 1),
                offlineGracePeriod: TimeInterval = 30 * 86_400,
                revalidationInterval: TimeInterval = 3 * 86_400,
                freeSavedSessions: Int = 1,
                freeActiveRules: Int = 1,
                freeReplaysPerSession: Int = 5) {
        self.updateWindow = updateWindow
        self.offlineGracePeriod = offlineGracePeriod
        self.revalidationInterval = revalidationInterval
        self.freeSavedSessions = freeSavedSessions
        self.freeActiveRules = freeActiveRules
        self.freeReplaysPerSession = freeReplaysPerSession
    }

    /// The limits the free tier works under.
    public var freeLimits: FreeLimits {
        FreeLimits(activeRules: max(1, freeActiveRules), replaysPerSession: max(0, freeReplaysPerSession))
    }

    public static let standard = LicensePolicy()

    public func updatesCovered(until purchase: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(byAdding: updateWindow, to: purchase) ?? purchase
    }
}

/// How far the free tier goes with the Pro tools. Free captures and inspects everything and can try
/// each tool: a few rules at a time, and resending captured MQTT messages unchanged.
public struct FreeLimits: Equatable, Sendable {
    /// Enabled rules of each kind that work at once; more stay saved but switched off.
    public var activeRules: Int
    /// Unchanged resends of captured MQTT messages per capture session.
    public var replaysPerSession: Int

    public init(activeRules: Int, replaysPerSession: Int) {
        self.activeRules = activeRules
        self.replaysPerSession = replaysPerSession
    }
}

/// Features that Pro unlocks fully. The free tier captures and inspects everything, keeps one saved
/// session, and can use the tools within `FreeLimits`.
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

    /// What the free tier gets of this feature, for the License tab.
    public func freeAllowance(_ policy: LicensePolicy) -> String {
        let limits = policy.freeLimits
        let rules = limits.activeRules
        switch self {
        case .unlimitedSessions:
            return policy.freeSavedSessions == 1 ? "Free keeps 1 saved session" : "Free keeps \(policy.freeSavedSessions) saved sessions"
        case .mqttPublish:
            return "Free resends captured messages unchanged, \(limits.replaysPerSession) per session"
        case .breakpoints:
            return rules == 1 ? "Free runs 1 rule at a time" : "Free runs \(rules) rules at a time"
        case .mapRewrite:
            return rules == 1 ? "Free runs 1 rule of each kind at a time" : "Free runs \(rules) rules of each kind at a time"
        case .scripting:
            return rules == 1 ? "Free runs 1 script at a time" : "Free runs \(rules) scripts at a time"
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

    /// True when Pro unlocks `feature` fully; without Pro it works within `limits(_:)`.
    public func allows(_ feature: ProFeature) -> Bool { isPro }

    /// The free tier's limits, or nil on Pro (no limits). A lapsed, revoked or unchecked license
    /// falls back to these limits too, so the tools keep working within them.
    public func limits(_ policy: LicensePolicy = .standard) -> FreeLimits? {
        isPro ? nil : policy.freeLimits
    }

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
