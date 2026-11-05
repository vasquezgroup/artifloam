// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacSteward", platforms: [.macOS(.v14)],
    products: [.library(name: "MacStewardCore", targets: ["MacStewardCore"]), .executable(name: "MacSteward", targets: ["MacSteward"]), .executable(name: "stewardctl", targets: ["stewardctl"])],
    targets: [.target(name: "MacStewardCore"), .executableTarget(name: "MacSteward", dependencies: ["MacStewardCore"], resources: [.process("Resources")]), .executableTarget(name: "stewardctl", dependencies: ["MacStewardCore"]), .testTarget(name: "MacStewardCoreTests", dependencies: ["MacStewardCore"])],
    swiftLanguageModes: [.v5]
)
