// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacSteward", platforms: [.macOS(.v14)],
    products: [.library(name: "MacStewardCore", targets: ["MacStewardCore"]), .executable(name: "MacSteward", targets: ["MacSteward"]), .executable(name: "stewardctl", targets: ["stewardctl"])],
    targets: [.target(name: "MacStewardCore"), .target(name: "PhotoEngine", path: "iOS/Artifloam/Shared"), .executableTarget(name: "MacSteward", dependencies: ["MacStewardCore", "PhotoEngine"], resources: [.process("Resources")]), .executableTarget(name: "stewardctl", dependencies: ["MacStewardCore"]), .testTarget(name: "MacStewardCoreTests", dependencies: ["MacStewardCore"])],
    swiftLanguageModes: [.v5]
)
