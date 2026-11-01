import Foundation
@testable import TLSMitm
import X509
import XCTest

final class CertificateAuthorityTests: XCTestCase {
    func testGeneratedRootIsACertificateAuthority() throws {
        let ca = try CertificateAuthority.generate(commonName: "Test CA")
        let constraints = try XCTUnwrap(ca.certificate.extensions.basicConstraints)
        XCTAssertEqual(constraints, .isCertificateAuthority(maxPathLength: 0))
        XCTAssertEqual(ca.certificate.subject, ca.certificate.issuer)
        XCTAssertTrue(ca.certificate.publicKey.isValidSignature(ca.certificate.signature, for: ca.certificate))
    }

    func testPEMRoundTrip() throws {
        let ca = try CertificateAuthority.generate()
        let restored = try CertificateAuthority(certificatePEM: ca.certificatePEM, privateKeyPEM: ca.privateKeyPEM)
        XCTAssertEqual(restored.certificate, ca.certificate)
        XCTAssertFalse(try ca.certificateDER.isEmpty)
    }

    func testRejectsMismatchedKey() throws {
        let a = try CertificateAuthority.generate()
        let b = try CertificateAuthority.generate()
        XCTAssertThrowsError(try CertificateAuthority(certificatePEM: a.certificatePEM, privateKeyPEM: b.privateKeyPEM)) {
            XCTAssertEqual($0 as? CertificateAuthorityError, .keyDoesNotMatchCertificate)
        }
    }

    func testLeafChainsToRootForHostname() async throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.issueLeaf(for: "api.example.com").certificate

        XCTAssertEqual(leaf.issuer, ca.certificate.subject)
        XCTAssertEqual(try leaf.extensions.basicConstraints, .notCertificateAuthority)
        XCTAssertEqual(try leaf.extensions.extendedKeyUsage, try ExtendedKeyUsage([.serverAuth]))
        XCTAssertLessThanOrEqual(leaf.notValidAfter.timeIntervalSince(leaf.notValidBefore), 398 * 86_400)

        var verifier = Verifier(rootCertificates: CertificateStore([ca.certificate])) {
            RFC5280Policy()
            ServerIdentityPolicy(serverHostname: "api.example.com", serverIP: nil)
        }
        let result = await verifier.validate(leaf: leaf, intermediates: CertificateStore())
        guard case .validCertificate = result else { return XCTFail("\(result)") }
    }

    func testLeafForIPAddressUsesIPSubjectAltName() throws {
        let ca = try CertificateAuthority.generate()
        let v4 = try ca.issueLeaf(for: "192.168.1.20").certificate
        XCTAssertEqual(try v4.extensions.subjectAlternativeNames.map(Array.init),
                       [.ipAddress(.init(contentBytes: [192, 168, 1, 20]))])
        let v6 = try ca.issueLeaf(for: "::1").certificate
        guard case .ipAddress(let bytes)? = try v6.extensions.subjectAlternativeNames?.first else { return XCTFail() }
        XCTAssertEqual(Array(bytes.bytes), Array(repeating: 0, count: 15) + [1])
    }
}

extension CertificateAuthorityTests {
    func testLeafForSeveralHosts() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.issueLeaf(for: ["broker.test", "localhost", "127.0.0.1"]).certificate
        XCTAssertEqual(try leaf.extensions.subjectAlternativeNames.map(Array.init), [
            .dnsName("broker.test"), .dnsName("localhost"), .ipAddress(.init(contentBytes: [127, 0, 0, 1])),
        ])
    }
}

final class TLSInterceptorTests: XCTestCase {
    func testBypassPatterns() throws {
        let interceptor = TLSInterceptor(authority: try .generate(), bypass: ["Pinned.example.com", "*.bank.test"])
        XCTAssertFalse(interceptor.shouldIntercept(host: "pinned.example.com"))
        XCTAssertTrue(interceptor.shouldIntercept(host: "other.example.com"))
        XCTAssertFalse(interceptor.shouldIntercept(host: "api.bank.test"))
        XCTAssertTrue(interceptor.shouldIntercept(host: "bank.test"))
        interceptor.bypass = []
        XCTAssertTrue(interceptor.shouldIntercept(host: "pinned.example.com"))
    }

    func testServerContextsAreCachedPerHost() throws {
        let interceptor = TLSInterceptor(authority: try .generate())
        let a = try interceptor.serverContext(for: "a.test")
        XCTAssertTrue(a === (try interceptor.serverContext(for: "A.test")))
        XCTAssertFalse(a === (try interceptor.serverContext(for: "b.test")))
    }
}
