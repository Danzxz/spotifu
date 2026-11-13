// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Spotifu", platforms: [.macOS(.v13), .iOS(.v15)], products: [
    .library(name: "SpotifuCore", targets: ["SpotifuCore"]),
    .executable(name: "Spotifu", targets: ["SpotifuMac"])
], targets: [
    .target(name: "SpotifuCore", path: "Shared/Core"),
    .target(name: "SpotifuUI", dependencies: ["SpotifuCore"], path: "Shared/UI"),
    .executableTarget(name: "SpotifuMac", dependencies: ["SpotifuUI"], path: "macOS"),
    .testTarget(name: "SpotifuCoreTests", dependencies: ["SpotifuCore"], path: "Tests/Core")
])
