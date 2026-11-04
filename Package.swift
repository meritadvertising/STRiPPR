// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STRiPPR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "STRiPPR", targets: ["STRiPPR"]),
        .executable(name: "strippr-cli", targets: ["StripprCLI"]),
        .library(name: "StripprCore", targets: ["StripprCore"])
    ],
    targets: [
        .target(name: "StripprCore"),
        .executableTarget(name: "STRiPPR", dependencies: ["StripprCore"]),
        .executableTarget(name: "StripprCLI", dependencies: ["StripprCore"]),
        .testTarget(name: "StripprCoreTests", dependencies: ["StripprCore"]),
        .testTarget(name: "StripprAppTests", dependencies: ["STRiPPR", "StripprCore"])
    ],
    swiftLanguageModes: [.v5]
)
