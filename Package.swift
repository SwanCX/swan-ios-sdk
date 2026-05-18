// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwanSDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SwanSDK", targets: ["SwanSDK"]),
    ],
    targets: [
        .target(name: "SwanSDK", path: "Sources/SwanSDK"),
    ]
)
