// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YATDCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "YATDCore", targets: ["YATDCore"]),
    ],
    targets: [
        .target(name: "YATDCore"),
        .testTarget(
            name: "YATDCoreTests",
            dependencies: ["YATDCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
