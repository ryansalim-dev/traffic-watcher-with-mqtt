import Foundation
#if canImport(Security)
import Security
#endif

/// Where the activated license is kept between launches.
public protocol LicenseStorage: Sendable {
    func load() throws -> StoredLicense?
    func save(_ license: StoredLicense) throws
    func clear() throws
}

/// JSON file readable only by the user. Used in tests and on platforms without a keychain.
public struct FileLicenseStorage: LicenseStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> StoredLicense? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(StoredLicense.self, from: Data(contentsOf: url))
    }

    public func save(_ license: StoredLicense) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(license)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

#if canImport(Security)
/// Keeps the license in the login keychain as a generic password.
public struct KeychainLicenseStorage: LicenseStorage {
    public let service: String
    public let account: String

    public init(service: String = "com.trafficwatcher.license", account: String = "pro") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> StoredLicense? {
        var result: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try FileLicenseStorage.decoder.decode(StoredLicense.self, from: data)
    }

    public func save(_ license: StoredLicense) throws {
        let data = try FileLicenseStorage.encoder.encode(license)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
#endif
