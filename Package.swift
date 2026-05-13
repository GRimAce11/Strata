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
        .library(name: "StrataCore",     targets: ["StrataCore"]),
        .library(name: "StrataTesting",  targets: ["StrataTesting"]),
        .library(name: "StrataInspect",  targets: ["StrataInspect"]),
        .library(name: "PostsDemo",      targets: ["PostsDemo"]),
        .executable(name: "strata",      targets: ["StrataCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "StrataCore",
            path: "Sources/StrataCore",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "StrataTesting",
            dependencies: ["StrataCore"],
            path: "Sources/StrataTesting",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "StrataInspect",
            dependencies: ["StrataCore"],
            path: "Sources/StrataInspect",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "StrataCLI",
            dependencies: [
                "StrataCore",
                "StrataInspect",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StrataCLI",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PostsDemo",
            dependencies: ["StrataCore"],
            path: "Examples/PostsDemo/Sources/PostsDemo",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "StrataCoreTests",
            dependencies: ["StrataCore", "StrataTesting", "PostsDemo"],
            path: "Tests/StrataCoreTests",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "StrataTestingTests",
            dependencies: ["StrataTesting", "PostsDemo"],
            path: "Tests/StrataTestingTests",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "StrataInspectTests",
            dependencies: ["StrataInspect", "StrataTesting", "PostsDemo"],
            path: "Tests/StrataInspectTests",
            swiftSettings: strictConcurrency
        ),
    ]
)

// Swift 6 enables strict concurrency by default — no opt-in needed.
// `ExistentialAny` becomes default in Swift 7; opt in now so the
// codebase is forward-compatible.
var strictConcurrency: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
    ]
}
