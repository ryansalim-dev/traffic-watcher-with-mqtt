import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
@testable import ProxyCore
import TLSMitm
import XCTest

final class TLSInterceptionTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var upstreamCA: CertificateAuthority!
    private var proxyCA: CertificateAuthority!

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        upstreamCA = try .generate(commonName: "Upstream Test CA")
        proxyCA = try .generate(commonName: "Proxy Test CA")
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func trusting(_ ca: CertificateAuthority) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([try NIOSSLCertificate(bytes: ca.certificateDER, format: .der)])
        return configuration
    }

    /// An HTTPS server for `localhost` whose certificate comes from `upstreamCA`.
    private func startHTTPSUpstream() async throws -> Channel {
        let context = try NIOSSLContext(configuration: upstreamCA.issueLeaf(for: "localhost").serverTLSConfiguration())
        return try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(UpstreamHTTPHandler())
            }
        }
    }

    private func startProxy(log: CaptureLog, bypass: [String] = []) async throws -> (HTTPProxyServer, Int) {
        var configuration = HTTPProxyServer.Configuration()
        configuration.interceptor = TLSInterceptor(authority: proxyCA, bypass: bypass)
        configuration.upstreamTLS = try trusting(upstreamCA)
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        return (proxy, try await proxy.start())
    }

    /// Sends CONNECT, waits for the 200, then starts TLS on the client side.
    private func connectAndStartTLS(proxyPort: Int, target: String, trust: CertificateAuthority) async throws -> RawClient {
        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        await eventually("CONNECT answered") { client.text.contains("\r\n\r\n") }
        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 200 OK"), client.text)
        let tls = try NIOSSLContext(configuration: trusting(trust))
        let channel = client.channel
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(
                NIOSSLClientHandler(context: tls, serverHostname: "localhost"), position: .first)
        }.get()
        return client
    }

    func testDecryptsAndCapturesHTTPSExchange() async throws {
        let upstream = try await startHTTPSUpstream()
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        let (proxy, proxyPort) = try await startProxy(log: log)

        let client = try await connectAndStartTLS(proxyPort: proxyPort, target: "localhost:\(port)", trust: proxyCA)
        let tunnelPrefix = client.bytes.count
        try await client.send("PUT /secure?x=1 HTTP/1.1\r\nHost: localhost:\(port)\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsecret")
        await eventually("response decrypted") { client.text.contains("body=secret") }

        let response = String(decoding: client.bytes.dropFirst(tunnelPrefix), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201 Created"), response)
        XCTAssertTrue(response.hasSuffix("PUT /secure?x=1 host=localhost:\(port) body=secret"), response)

        await eventually("exchange recorded") { !log.events.isEmpty }
        guard case .httpExchange(let exchange)? = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(exchange.url, "https://localhost:\(port)/secure?x=1")
        XCTAssertEqual(exchange.method, "PUT")
        XCTAssertEqual(exchange.statusCode, 201)
        XCTAssertEqual(exchange.requestBody, Array("secret".utf8))
        XCTAssertNil(exchange.error)

        try? await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }

    func testUntrustedUpstreamCertificateBecomes502() async throws {
        let upstream = try await startHTTPSUpstream()
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        var configuration = HTTPProxyServer.Configuration()
        configuration.interceptor = TLSInterceptor(authority: proxyCA)
        configuration.upstreamTLS = try trusting(proxyCA) // wrong root for the upstream
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        let proxyPort = try await proxy.start()

        let client = try await connectAndStartTLS(proxyPort: proxyPort, target: "localhost:\(port)", trust: proxyCA)
        try await client.send("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        await eventually("502 decrypted") { client.text.contains("502 Bad Gateway") }
        await eventually("exchange recorded") { !log.events.isEmpty }
        guard case .httpExchange(let exchange)? = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(exchange.statusCode, 502)
        XCTAssertNotNil(exchange.error)

        try? await client.channel.close()
        try await proxy.stop()
        try await upstream.close()
    }

    func testClientRejectingCertificateIsReported() async throws {
        let log = CaptureLog()
        let (proxy, proxyPort) = try await startProxy(log: log)
        // The client trusts only the upstream CA, as a pinned app would.
        let client = try await connectAndStartTLS(proxyPort: proxyPort, target: "localhost:443", trust: upstreamCA)
        try? await client.send("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")

        await eventually("failure recorded") { !log.events.isEmpty }
        guard case .tlsInterceptionFailed(let host, let port, _)? = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(host, "localhost")
        XCTAssertEqual(port, 443)

        try? await client.channel.close()
        try await proxy.stop()
    }

    func testBypassedHostIsTunneledUntouched() async throws {
        let echo = try await startServer(group: group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let port = echo.localAddress!.port!
        let log = CaptureLog()
        let (proxy, proxyPort) = try await startProxy(log: log, bypass: ["127.0.0.1"])

        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\n\r\n")
        await eventually("CONNECT answered") { client.text.contains("\r\n\r\n") }
        let prefix = client.bytes.count
        try await client.send("raw")
        await eventually("echo") { client.bytes.count == prefix + 3 }

        guard case .tunnelOpened(let info)? = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(info.port, port)

        try? await client.channel.close()
        try await proxy.stop()
        try await echo.close()
    }

    func testInterceptedOriginURL() {
        XCTAssertEqual(InterceptedOrigin(host: "api.test", port: 443).url(for: "/a?b=1"), "https://api.test/a?b=1")
        XCTAssertEqual(InterceptedOrigin(host: "api.test", port: 8443).url(for: "/"), "https://api.test:8443/")
        XCTAssertEqual(InterceptedOrigin(host: "::1", port: 443).url(for: "/"), "https://[::1]/")
    }
}
