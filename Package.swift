// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrafficWatcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MQTTCore", targets: ["MQTTCore"]),
    ],
    targets: [
        .target(name: "MQTTCore"),
        .testTarget(name: "MQTTCoreTests", dependencies: ["MQTTCore"]),
    ]
)
