// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlidesToVideo",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SlidesToVideoKit", resources: [.copy("Resources")]),
        .executableTarget(name: "SlidesToVideo", dependencies: ["SlidesToVideoKit"]),
        .testTarget(
            name: "SlidesToVideoKitTests",
            dependencies: ["SlidesToVideoKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
