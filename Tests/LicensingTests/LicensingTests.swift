import Foundation
@testable import Licensing
import XCTest

private let day: TimeInterval = 86_400
private let purchase = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

private func license(status: StoredLicense.Status = .active, expires: Date? = nil, validated: Date = purchase) -> StoredLicense {
    StoredLicense(key: "ABCD-1234-EFGH-5678", instanceID: "inst-1", status: status,
                  purchasedAt: purchase, expiresAt: expires, lastValidatedAt: validated)
}

final class EntitlementTests: XCTestCase {
    func testNoLicenseIsFree() {
        XCTAssertEqual(Entitlement.evaluate(nil, now: purchase, releaseDate: nil), .free(.noLicense))
    }

    func testActiveLicenseIsProWithAYearOfUpdates() {
        let entitlement = Entitlement.evaluate(license(), now: purchase + 2 * day, releaseDate: purchase - 30 * day)
        guard case .pro(let until) = entitlement else { return XCTFail("\(entitlement)") }
        XCTAssertEqual(until.timeIntervalSince(purchase) / day, 365, accuracy: 1)
        XCTAssertTrue(entitlement.allows(.mqttPublish))
    }

    func testReleaseAfterUpdateWindowFallsBackToFree() {
        let release = purchase + 400 * day
        let entitlement = Entitlement.evaluate(license(validated: release), now: release, releaseDate: release)
        guard case .free(.updatesEnded(_, let released)) = entitlement else { return XCTFail("\(entitlement)") }
        XCTAssertEqual(released, release)
    }

    func testReleaseInsideWindowStaysProForever() {
        // A version released within the window keeps Pro years later, as long as the license validates.
        let now = purchase + 3 * 365 * day
        XCTAssertTrue(Entitlement.evaluate(license(validated: now), now: now, releaseDate: purchase + 300 * day).isPro)
    }

    func testOfflineGracePeriod() {
        XCTAssertTrue(Entitlement.evaluate(license(), now: purchase + 29 * day, releaseDate: nil).isPro)
        XCTAssertEqual(Entitlement.evaluate(license(), now: purchase + 31 * day, releaseDate: nil),
                       .free(.needsValidation(since: purchase)))
    }

    func testRevokedAndExpired() {
        XCTAssertEqual(Entitlement.evaluate(license(status: .disabled), now: purchase, releaseDate: nil), .free(.revoked))
        XCTAssertEqual(Entitlement.evaluate(license(status: .inactive), now: purchase, releaseDate: nil), .free(.revoked))
        let expiry = purchase + 10 * day
        XCTAssertEqual(Entitlement.evaluate(license(expires: expiry), now: expiry + 1, releaseDate: nil), .free(.expired(expiry)))
    }

    func testMaskedKey() {
        XCTAssertEqual(license().maskedKey, "••••••••5678")
    }
}

/// Records requests and answers from a queue of canned responses.
private final class FakeServer: @unchecked Sendable {
    var responses: [(Int, String)] = []
    var requests: [(path: String, body: String)] = []
    var failure: Error?
    private let lock = NSLock()

    var transport: LemonSqueezyClient.Transport {
        { [self] request in
            try lock.withLock {
                requests.append((request.url?.lastPathComponent ?? "", String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
                if let failure { throw failure }
                let (status, body) = responses.removeFirst()
                return (Data(body.utf8), status)
            }
        }
    }
}

private func body(_ flag: String, status: String = "active", storeID: Int = 7, productID: Int = 42, error: String? = nil) -> String {
    """
    {"\(flag)": \(error == nil), "error": \(error.map { "\"\($0)\"" } ?? "null"),
     "license_key": {"id": 1, "status": "\(status)", "key": "ABCD", "activation_limit": 2, "activation_usage": 1,
                     "created_at": "2026-09-21T14:13:20.000000Z", "expires_at": null},
     "instance": {"id": "inst-9", "name": "Ryan's MacBook", "created_at": "2026-11-01T00:00:00.000000Z"},
     "meta": {"store_id": \(storeID), "order_id": 2, "order_item_id": 3, "product_id": \(productID), "product_name": "Traffic Watcher Pro",
              "variant_id": 5, "variant_name": "Default", "customer_id": 6, "customer_name": "Ryan", "customer_email": "ryan@example.com"}}
    """
}

final class LemonSqueezyClientTests: XCTestCase {
    private let product = LemonSqueezyClient.Product(storeID: 7, productIDs: [42])

    func testActivateParsesLicense() async throws {
        let server = FakeServer()
        server.responses = [(200, body("activated"))]
        let client = LemonSqueezyClient(product: product, transport: server.transport)
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let license = try await client.activate(key: "ABCD 1234", instanceName: "Ryan's MacBook", now: now)

        XCTAssertEqual(server.requests.first?.path, "activate")
        XCTAssertEqual(server.requests.first?.body, "instance_name=Ryan%27s%20MacBook&license_key=ABCD%201234")
        XCTAssertEqual(license.instanceID, "inst-9")
        XCTAssertEqual(license.status, .active)
        XCTAssertEqual(license.customerEmail, "ryan@example.com")
        XCTAssertEqual(license.purchasedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(license.expiresAt)
        XCTAssertEqual(license.lastValidatedAt, now)
    }

    func testRefusesKeysForOtherProducts() async {
        let server = FakeServer()
        server.responses = [(200, body("activated", productID: 99)), (200, body("activated", storeID: 8))]
        let client = LemonSqueezyClient(product: product, transport: server.transport)
        for _ in 0..<2 {
            do {
                _ = try await client.activate(key: "k", instanceName: "m")
                XCTFail("expected wrongProduct")
            } catch {
                XCTAssertEqual(error as? LicenseError, .wrongProduct)
            }
        }
    }

    func testActivationErrorKinds() async {
        let server = FakeServer()
        let client = LemonSqueezyClient(product: product, transport: server.transport)
        server.responses = [(400, #"{"activated": false, "error": "This license key has reached the activation limit."}"#)]
        await assertThrows(.activationLimitReached) { _ = try await client.activate(key: "k", instanceName: "m") }
        server.responses = [(404, #"{"activated": false, "error": "license_key not found."}"#)]
        await assertThrows(.rejected("license_key not found.")) { _ = try await client.activate(key: "k", instanceName: "m") }
        server.responses = [(502, "<html>bad gateway</html>")]
        await assertThrows(.network("server error 502")) { _ = try await client.activate(key: "k", instanceName: "m") }
        server.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await client.activate(key: "k", instanceName: "m")
            XCTFail("expected a network error")
        } catch let LicenseError.network(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testValidateReportsRevokedLicenses() async throws {
        let server = FakeServer()
        let client = LemonSqueezyClient(product: product, transport: server.transport)
        let stored = license()

        server.responses = [(200, body("valid"))]
        let ok = try await client.validate(stored, now: purchase + day)
        XCTAssertEqual(ok.status, .active)
        XCTAssertEqual(ok.lastValidatedAt, purchase + day)
        XCTAssertEqual(server.requests.last?.body, "instance_id=inst-1&license_key=ABCD-1234-EFGH-5678")

        server.responses = [(200, body("valid", status: "disabled", error: "license_key is disabled."))]
        let disabled = try await client.validate(stored)
        XCTAssertEqual(disabled.status, .disabled)

        server.responses = [(404, body("valid", error: "instance_id not found."))]
        let removed = try await client.validate(stored)
        XCTAssertEqual(removed.status, .inactive)

        server.responses = [(404, #"{"valid": false, "error": "license_key not found."}"#)]
        await assertThrows(.rejected("license_key not found.")) { _ = try await client.validate(stored) }
    }

    func testDeactivate() async throws {
        let server = FakeServer()
        let client = LemonSqueezyClient(product: product, transport: server.transport)
        server.responses = [(200, body("deactivated"))]
        try await client.deactivate(license())
        XCTAssertEqual(server.requests.last?.path, "deactivate")
    }

    func testMicrosecondDates() {
        XCTAssertEqual(LemonSqueezyClient.date("2026-09-21T14:13:20.123456Z"), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(LemonSqueezyClient.date("2026-09-21T14:13:20Z"), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(LemonSqueezyClient.date("yesterday"))
    }

    private func assertThrows(_ expected: LicenseError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LicenseError, expected, file: file, line: line)
        }
    }
}

final class FileLicenseStorageTests: XCTestCase {
    func testRoundTripAndPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("license-\(UUID().uuidString)/license.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = FileLicenseStorage(url: url)
        XCTAssertNil(try storage.load())
        try storage.save(license())
        XCTAssertEqual(try storage.load(), license())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try storage.clear()
        XCTAssertNil(try storage.load())
    }
}
