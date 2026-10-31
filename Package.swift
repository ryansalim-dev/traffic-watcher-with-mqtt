// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrafficWatcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MQTTCore", targets: ["MQTTCore"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
    ],
    targets: [
        .target(name: "MQTTCore"),
        .target(
            name: "ProxyCore",
            dependencies: [
                "MQTTCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            // NIO channel handlers are event-loop confined rather than Sendable.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MQTTCoreTests", dependencies: ["MQTTCore"]),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: [
                "ProxyCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
