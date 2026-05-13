// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "StrataCore",    targets: ["StrataCore"]),
        .library(name: "StrataTesting", targets: ["StrataTesting"]),
        .library(name: "StrataInspect", targets: ["StrataInspect"]),
        .library(name: "PostsDemo",     targets: ["PostsDemo"]),
        .executable(name: "strata",     targets: ["StrataCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "StrataCore",
            path: "Sources/StrataCore"
        ),
        .target(
            name: "StrataTesting",
            dependencies: ["StrataCore"],
            path: "Sources/StrataTesting"
        ),
        .target(
            name: "StrataInspect",
            dependencies: ["StrataCore"],
            path: "Sources/StrataInspect"
        ),
        .executableTarget(
            name: "StrataCLI",
            dependencies: [
                "StrataCore",
                "StrataInspect",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StrataCLI"
        ),
        .target(
            name: "PostsDemo",
            dependencies: ["StrataCore"],
            path: "Examples/PostsDemo/Sources/PostsDemo"
        ),
        .testTarget(
            name: "StrataCoreTests",
            dependencies: ["StrataCore", "StrataTesting", "PostsDemo"],
            path: "Tests/StrataCoreTests"
        ),
        .testTarget(
            name: "StrataTestingTests",
            dependencies: ["StrataTesting", "PostsDemo"],
            path: "Tests/StrataTestingTests"
        ),
        .testTarget(
            name: "StrataInspectTests",
            dependencies: ["StrataInspect", "StrataTesting", "PostsDemo"],
            path: "Tests/StrataInspectTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
