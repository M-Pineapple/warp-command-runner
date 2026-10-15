import XCTest
import Foundation
@testable import WarpCommandRunner
@testable import WCRIdentity

/// Guards for the 15 Oct 2026 hardening (blocklist coverage, scratch folder,
/// request size cap, WCR_HOME).
final class SweepGuardTests: XCTestCase {

    private func defaultConfig() throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
    }

    // MARK: blocklist

    func testBlocklistFoldsWhitespaceAndFlagOrder() throws {
        let c = try defaultConfig()
        for cmd in ["rm  -rf /", "rm\t-rf /", "rm -fr /", "rm -r -f /", "rm -Rf /*",
                    "rm --recursive --force /", "echo hi; rm -fr /", "/bin/rm -rf /"] {
            XCTAssertTrue(c.isCommandBlocked(cmd), cmd)
        }
        for cmd in ["rm -rf ./build", "rm -f /tmp/x", "ls -la /", "rm -r /Users/me/old"] {
            XCTAssertFalse(c.isCommandBlocked(cmd), cmd)
        }
    }

    func testPipelineAndStreamingHandlersCheckBlocklist() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WarpCommandRunner/PipelineAndStreaming.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "config.isCommandBlocked(").count - 1, 4)
    }

    // MARK: scratch folder (no shared /tmp)

    func testTempFilesLiveInPrivateScratchFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wcr-guard-\(UUID().uuidString)")
        setenv("WCR_HOME", base.path, 1)
        defer { unsetenv("WCR_HOME"); try? FileManager.default.removeItem(at: base) }

        for path in [TempFiles.outputPath(commandId: "x"), TempFiles.scriptPath(commandId: "x"),
                     TempFiles.streamLogPath(commandId: "x"), TempFiles.streamExitPath(commandId: "x"),
                     TempFiles.streamScriptPath(commandId: "x"), TempFiles.stderrPath(commandId: "x")] {
            XCTAssertFalse(path.hasPrefix("/tmp/"), path)
            XCTAssertTrue(path.hasPrefix(base.path), path)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: TempFiles.directoryPath)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        XCTAssertEqual(TempFiles.scriptPOSIXPermissions, 0o700)
        XCTAssertTrue(createOutputCaptureScript(command: "true", commandId: "x").contains("umask 077"))
    }

    // MARK: request size cap

    func testRequestBodyLimiterCapsBodies() {
        var l = RequestBodyLimiter(maxBytes: 10)
        l.begin(declaredLength: nil)
        XCTAssertTrue(l.accept(byteCount: 6))
        XCTAssertFalse(l.accept(byteCount: 6))
        XCTAssertTrue(l.exceeded)

        l.begin(declaredLength: 11)
        XCTAssertTrue(l.exceeded)
        l.begin(declaredLength: 5)
        XCTAssertFalse(l.exceeded)
        XCTAssertEqual(RequestBodyLimiter.defaultMaxBytes, 1 << 20)
    }

    // MARK: WCR_HOME

    func testHomeOverrideRefusesRootAndHome() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        for raw in ["~", "~/", "/", "//", "/Users/someone", "/Users/someone/", "~/."] {
            XCTAssertNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": raw], userHome: home), raw)
        }
        XCTAssertNotNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": "/Users/someone/wcr-test"], userHome: home))
    }
}
