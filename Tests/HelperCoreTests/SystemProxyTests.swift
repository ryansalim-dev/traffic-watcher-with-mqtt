import Foundation
import HelperCore
import XCTest

final class SystemProxyPlanTests: XCTestCase {
    private let original: [String: Any] = [
        "HTTPEnable": NSNumber(value: 0),
        "HTTPProxy": "corp-proxy.example.com",
        "ExceptionsList": ["*.corp.example.com"],
        "ProxyAutoConfigEnable": NSNumber(value: 1),
        "ProxyAutoConfigURLString": "http://wpad/wpad.dat",
    ]

    func testEnablingSetsHTTPAndHTTPSAndKeepsOtherSettings() {
        let enabled = SystemProxyPlan.enabling(original, host: "127.0.0.1", port: 9090, bypass: ["pinned.bank.example"])
        XCTAssertTrue(SystemProxyPlan.isEnabled(enabled, host: "127.0.0.1", port: 9090))
        XCTAssertEqual(ProxyValue(enabled["HTTPSProxy"]), .string("127.0.0.1"))
        XCTAssertEqual(ProxyValue(enabled["HTTPSPort"]), .int(9090))
        XCTAssertEqual(enabled["ExceptionsList"] as? [String],
                       ["*.corp.example.com", "127.0.0.1", "localhost", "*.local", "169.254/16", "pinned.bank.example"])
        XCTAssertEqual(enabled["ProxyAutoConfigURLString"] as? String, "http://wpad/wpad.dat")
        XCTAssertFalse(SystemProxyPlan.isEnabled(original, host: "127.0.0.1", port: 9090))
    }

    func testRestoringPutsBackExactlyWhatWasThere() {
        let backup = SystemProxyPlan.backup(of: original)
        XCTAssertEqual(backup["HTTPProxy"], .string("corp-proxy.example.com"))
        XCTAssertEqual(backup["HTTPSProxy"], .absent)

        let enabled = SystemProxyPlan.enabling(original, host: "127.0.0.1", port: 9090)
        let restored = SystemProxyPlan.restoring(enabled, from: backup)
        XCTAssertEqual(ProxyValue(restored["HTTPEnable"]), .int(0))
        XCTAssertEqual(restored["HTTPProxy"] as? String, "corp-proxy.example.com")
        XCTAssertNil(restored["HTTPPort"])
        XCTAssertNil(restored["HTTPSEnable"])
        XCTAssertNil(restored["HTTPSProxy"])
        XCTAssertEqual(restored["ExceptionsList"] as? [String], ["*.corp.example.com"])
        XCTAssertEqual(ProxyValue(restored["ProxyAutoConfigEnable"]), .int(1))
        XCTAssertEqual(Set(restored.keys), Set(original.keys))
    }

    func testBackupFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID().uuidString)/backup.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let backup = SystemProxyBackup(services: ["SERVICE-1": SystemProxyPlan.backup(of: original)],
                                       createdAt: Date(timeIntervalSince1970: 1_793_500_000))
        try backup.save(to: url)
        XCTAssertEqual(SystemProxyBackup.load(from: url), backup)
        XCTAssertNil(SystemProxyBackup.load(from: url.appendingPathExtension("missing")))
    }
}

/// Records what a transaction committed, and whether the backup was on disk at that moment.
private final class FakeProxyStore: ProxySettingsStore {
    var services: [String: [String: Any]]
    let backupURL: URL
    var backupExistedAtCommit: Bool?

    init(services: [String: [String: Any]], backupURL: URL) {
        self.services = services
        self.backupURL = backupURL
    }

    func transaction(_ change: ([String: [String: Any]]) throws -> [String: [String: Any]]) throws {
        let updates = try change(services)
        backupExistedAtCommit = FileManager.default.fileExists(atPath: backupURL.path)
        services.merge(updates) { _, new in new }
    }
}

final class ProxySwitcherTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private let wifi: [String: Any] = ["HTTPEnable": NSNumber(value: 0), "ProxyAutoConfigEnable": NSNumber(value: 1)]

    func testBackupIsSavedBeforeTheChangeIsCommitted() throws {
        let url = directory.appendingPathComponent("backup.plist")
        let store = FakeProxyStore(services: ["WIFI": wifi], backupURL: url)
        try ProxySwitcher.enable(host: "127.0.0.1", port: 9090, bypass: [], store: store, backupURL: url)
        XCTAssertEqual(store.backupExistedAtCommit, true)
        XCTAssertTrue(SystemProxyPlan.isEnabled(store.services["WIFI"]!, host: "127.0.0.1", port: 9090))

        try ProxySwitcher.restore(store: store, backupURL: url)
        XCTAssertEqual(ProxyValue(store.services["WIFI"]!["HTTPEnable"]), .int(0))
        XCTAssertNil(store.services["WIFI"]!["HTTPProxy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingChangesWhenTheBackupCantBeSaved() throws {
        // The backup's folder is a file, so the save fails.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("backup.plist")
        let store = FakeProxyStore(services: ["WIFI": wifi], backupURL: url)
        XCTAssertThrowsError(try ProxySwitcher.enable(host: "127.0.0.1", port: 9090, bypass: [], store: store, backupURL: url))
        XCTAssertNil(store.backupExistedAtCommit, "no commit")
        XCTAssertFalse(SystemProxyPlan.isEnabled(store.services["WIFI"]!, host: "127.0.0.1", port: 9090))
    }

    func testAnUnrestoredBackupIsKept() throws {
        let url = directory.appendingPathComponent("backup.plist")
        let store = FakeProxyStore(services: ["WIFI": wifi], backupURL: url)
        try ProxySwitcher.enable(host: "127.0.0.1", port: 9090, bypass: [], store: store, backupURL: url)
        // A crash: the proxy stays on, and the next session must not back up Wiretide's own settings.
        try ProxySwitcher.enable(host: "127.0.0.1", port: 9091, bypass: [], store: store, backupURL: url)
        try ProxySwitcher.restore(store: store, backupURL: url)
        XCTAssertEqual(ProxyValue(store.services["WIFI"]!["HTTPEnable"]), .int(0))
    }
}
