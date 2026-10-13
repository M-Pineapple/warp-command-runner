// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Cloud Agents run Linux. These modules exist in the Apple SDK on macOS and
// are provided by the local LinuxSupport package there.
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.10.0")),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
]

var runnerDependencies: [Target.Dependency] = [
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "MCP", package: "swift-sdk"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOFoundationCompat", package: "swift-nio"),
]

#if os(Linux)
packageDependencies.append(.package(path: "LinuxSupport"))
runnerDependencies.append(contentsOf: [
    .product(name: "AppKit", package: "LinuxSupport"),
    .product(name: "CryptoKit", package: "LinuxSupport"),
    .product(name: "Security", package: "LinuxSupport"),
    .product(name: "SQLite3", package: "LinuxSupport"),
])
#endif

let package = Package(
    name: "warp-command-runner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "warp-command-runner",
            targets: ["WarpCommandRunner"]
        ),
        .executable(
            name: "ConfigManager",
            targets: ["ConfigManager"]
        )
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "WarpCommandRunner",
            dependencies: runnerDependencies,
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ConfigManager",
            dependencies: []
        ),
        .testTarget(
            name: "WarpCommandRunnerTests",
            dependencies: ["WarpCommandRunner"]
        ),
    ]
)
