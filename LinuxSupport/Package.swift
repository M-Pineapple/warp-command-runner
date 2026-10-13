// swift-tools-version: 5.9
// Linux stand-ins for Apple SDK modules this package imports.
// The root manifest depends on this package only when the host is Linux.
// macOS builds keep using the system AppKit, CryptoKit, Security, and SQLite3.

import PackageDescription

let package = Package(
    name: "LinuxSupport",
    products: [
        .library(name: "AppKit", targets: ["AppKit"]),
        .library(name: "CryptoKit", targets: ["CryptoKit"]),
        .library(name: "Security", targets: ["Security"]),
        .library(name: "SQLite3", targets: ["SQLite3"]),
    ],
    targets: [
        .target(name: "AppKit"),
        .target(name: "CryptoKit"),
        .target(name: "Security"),
        .systemLibrary(
            name: "SQLite3",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"])
            ]
        ),
    ]
)
