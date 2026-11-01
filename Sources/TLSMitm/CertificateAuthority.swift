import Crypto
import Foundation
import NIOCore
import NIOSSL
import SwiftASN1
import X509

/// A local root certificate authority that signs short-lived leaf certificates for intercepted hosts.
///
/// The root must be installed and trusted on the device under test (Simulator keychain or a
/// configuration profile). Persist `certificatePEM` and `privateKeyPEM` (the app keeps the key in
/// the Keychain) so the same root survives restarts.
public struct CertificateAuthority: Sendable {
    public let certificate: Certificate
    private let privateKey: P256.Signing.PrivateKey

    /// Creates a new root valid for `validityYears` years.
    public static func generate(
        commonName: String = "Traffic Watcher Local CA",
        validityYears: Int = 10,
        now: Date = Date()
    ) throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Traffic Watcher")
        }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: Calendar(identifier: .gregorian).date(byAdding: .year, value: validityYears, to: now)!,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return CertificateAuthority(certificate: certificate, privateKey: key)
    }

    /// Loads a root previously exported with `certificatePEM` and `privateKeyPEM`.
    public init(certificatePEM: String, privateKeyPEM: String) throws {
        let certificate = try Certificate(pemEncoded: certificatePEM)
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        guard certificate.publicKey == Certificate.PublicKey(key.publicKey) else {
            throw CertificateAuthorityError.keyDoesNotMatchCertificate
        }
        self.init(certificate: certificate, privateKey: key)
    }

    private init(certificate: Certificate, privateKey: P256.Signing.PrivateKey) {
        self.certificate = certificate
        self.privateKey = privateKey
    }

    public var certificatePEM: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    public var privateKeyPEM: String { privateKey.pemRepresentation }

    /// DER bytes of the root, e.g. for a `.mobileconfig` payload or `simctl keychain add-root-cert`.
    public var certificateDER: [UInt8] {
        get throws {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return serializer.serializedBytes
        }
    }

    /// Issues a leaf certificate for `host` (a DNS name or an IP literal).
    ///
    /// Validity stays under Apple's 398-day limit for TLS server certificates.
    public func issueLeaf(for host: String, now: Date = Date()) throws -> IssuedCertificate {
        try issueLeaf(for: [host], now: now)
    }

    /// Issues one leaf valid for every name in `hosts`; the first one becomes the common name.
    public func issueLeaf(for hosts: [String], now: Date = Date()) throws -> IssuedCertificate {
        precondition(!hosts.isEmpty, "a leaf needs at least one host")
        let host = hosts[0]
        let key = P256.Signing.PrivateKey()
        let publicKey = Certificate.PublicKey(key.publicKey)
        let subjectAltNames: [GeneralName] = hosts.map { name in
            if let ip = ipAddressBytes(name) {
                .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip)))
            } else {
                .dnsName(name)
            }
        }
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(365 * 86_400),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(String(host.prefix(64))) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(subjectAltNames)
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )
        return IssuedCertificate(certificate: leaf, privateKey: key, issuer: certificate)
    }
}

public enum CertificateAuthorityError: Error, Equatable {
    case keyDoesNotMatchCertificate
}

/// A leaf certificate with its key, ready to serve TLS.
public struct IssuedCertificate: Sendable {
    public let certificate: Certificate
    let privateKey: P256.Signing.PrivateKey
    let issuer: Certificate

    /// A NIOSSL server configuration presenting this leaf (plus its issuer), offering HTTP/1.1 only.
    public func serverTLSConfiguration() throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try nioCertificate(certificate)), .certificate(try nioCertificate(issuer))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey.pemRepresentation.utf8), format: .pem))
        )
        configuration.applicationProtocols = ["http/1.1"]
        return configuration
    }
}

func nioCertificate(_ certificate: Certificate) throws -> NIOSSLCertificate {
    var serializer = DER.Serializer()
    try serializer.serialize(certificate)
    return try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
}

/// Raw network-order bytes when `host` is an IPv4 or IPv6 literal, else nil.
public func ipAddressBytes(_ host: String) -> [UInt8]? {
    let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    guard let address = try? SocketAddress(ipAddress: literal, port: 0) else { return nil }
    switch address {
    case .v4(let v4):
        return withUnsafeBytes(of: v4.address.sin_addr) { Array($0) }
    case .v6(let v6):
        return withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
    case .unixDomainSocket:
        return nil
    }
}
