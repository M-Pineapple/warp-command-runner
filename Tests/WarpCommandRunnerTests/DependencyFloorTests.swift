// DependencyFloorTests.swift
//
// Package.resolved is committed so fresh clones resolve the same versions.
// These floors keep it from slipping back to versions that do not compile
// under current Swift toolchains (swift-sdk < 0.12) or that carry known
// upstream fixes (swift-nio < 2.100).
import Foundation
import XCTest

final class DependencyFloorTests: XCTestCase {
    static let floors: [String: [Int]] = [
        "swift-sdk": [0, 12, 1],
        "swift-nio": [2, 100, 0],
    ]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WarpCommandRunnerTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    func testManifestRequiresSwiftSDKFloor() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let line = try XCTUnwrap(manifest.split(separator: "\n").first { $0.contains("modelcontextprotocol/swift-sdk") },
                                 "swift-sdk dependency missing from Package.swift")
        let afterFrom = try XCTUnwrap(line.components(separatedBy: "from: \"").dropFirst().first,
                                      "no `from:` version in: \(line)")
        let version = try XCTUnwrap(afterFrom.split(separator: "\"").first.map(String.init))
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let floor = Self.floors["swift-sdk"]!
        XCTAssertFalse(parts.lexicographicallyPrecedes(floor),
                       "Package.swift allows swift-sdk below \(floor.map(String.init).joined(separator: "."))")
    }

    func testCommittedLockfileMeetsFloors() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Package.resolved"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        for (identity, floor) in Self.floors {
            let pin = try XCTUnwrap(pins.first { ($0["identity"] as? String) == identity },
                                    "\(identity) missing from Package.resolved")
            let state = try XCTUnwrap(pin["state"] as? [String: Any])
            let version = try XCTUnwrap(state["version"] as? String)
            let parts = version.split(separator: ".").map { Int($0) ?? 0 }
            XCTAssertFalse(parts.lexicographicallyPrecedes(floor),
                           "\(identity) \(version) is below \(floor.map(String.init).joined(separator: "."))")
        }
    }
}
