// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DualSpace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DualSpace", targets: ["DualSpace"]),
        .executable(name: "DualSpaceLauncher", targets: ["DualSpaceLauncher"]),
        .executable(name: "dualspace-cli", targets: ["DualSpaceCLI"])
    ],
    targets: [
        .target(name: "DualSpaceCore"),
        .executableTarget(name: "DualSpaceLauncher"),
        .executableTarget(name: "DualSpaceCLI", dependencies: ["DualSpaceCore"]),
        .executableTarget(name: "DualSpace", dependencies: ["DualSpaceCore"]),
        .testTarget(name: "DualSpaceCoreTests", dependencies: ["DualSpaceCore"]),
        .testTarget(name: "DualSpaceTests", dependencies: ["DualSpace", "DualSpaceCore"])
    ],
    swiftLanguageModes: [.v5]
)
