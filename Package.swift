// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrafficWatcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MQTTCore", targets: ["MQTTCore"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .library(name: "TLSMitm", targets: ["TLSMitm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.18.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "MQTTCore"),
        .target(
            name: "TLSMitm",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "MQTTCore",
                "TLSMitm",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            // NIO channel handlers are event-loop confined rather than Sendable.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MQTTCoreTests", dependencies: ["MQTTCore"]),
        .testTarget(
            name: "TLSMitmTests",
            dependencies: [
                "TLSMitm",
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: [
                "ProxyCore",
                "TLSMitm",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
