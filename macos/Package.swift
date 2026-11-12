// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlidesToVideo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "SlidesToVideoKit", resources: [.copy("Resources")]),
        .executableTarget(
            name: "SlidesToVideo",
            dependencies: ["SlidesToVideoKit", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "SlidesToVideoKitTests",
            dependencies: ["SlidesToVideoKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
