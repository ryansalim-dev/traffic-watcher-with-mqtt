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
