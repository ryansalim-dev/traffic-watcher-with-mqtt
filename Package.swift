// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wiretide",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MQTTCore", targets: ["MQTTCore"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .library(name: "TLSMitm", targets: ["TLSMitm"]),
        .library(name: "CaptureStore", targets: ["CaptureStore"]),
        .library(name: "Licensing", targets: ["Licensing"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .executable(name: "Wiretide", targets: ["WiretideApp"]),
        .executable(name: "WiretideHelper", targets: ["WiretideHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.18.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Auto-updates for the macOS app (binary framework; linked on macOS only).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "MQTTCore"),
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        .target(name: "CaptureStore", dependencies: ["CSQLite", "MQTTCore", "ProxyCore"]),
        // Pro license: Lemon Squeezy client, entitlement rules, keychain storage. Foundation only.
        .target(name: "Licensing"),
        // Shared by the app and the privileged helper: XPC interface and system-proxy rules.
        .target(name: "HelperCore"),
        // Root daemon (SMAppService) that switches the system proxy on while capturing and always back off.
        .executableTarget(name: "WiretideHelper", dependencies: ["HelperCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "AppCore",
            dependencies: [
                "CaptureStore", "ProxyCore", "TLSMitm", "MQTTCore", "Licensing",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Linux toolchains ship libswiftObservation.so with an unresolved reference to
            // swift::threading::fatal, which only runs on a fatal error. Let the link through.
            linkerSettings: [.unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux]))]
        ),
        // SwiftUI app. Its views compile only on macOS; elsewhere the executable is a stub.
        .executableTarget(
            name: "WiretideApp",
            dependencies: [
                "AppCore", "CaptureStore", "ProxyCore", "MQTTCore", "TLSMitm", "Licensing", "HelperCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Inside Wiretide.app, Sparkle.framework lives in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]
        ),
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
        .testTarget(name: "LicensingTests", dependencies: ["Licensing"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"]),
        .testTarget(name: "CaptureStoreTests", dependencies: ["CaptureStore", "ProxyCore", "MQTTCore"]),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "CaptureStore", "ProxyCore", "MQTTCore", "TLSMitm", "Licensing"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
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
