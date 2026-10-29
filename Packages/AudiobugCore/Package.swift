// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudiobugCore",
    platforms: [.iOS(.v26), .watchOS(.v26), .macOS(.v26)],
    products: [.library(name: "AudiobugCore", targets: ["AudiobugCore"])],
    targets: [
        .target(name: "AudiobugCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AudiobugCoreTests", dependencies: ["AudiobugCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
