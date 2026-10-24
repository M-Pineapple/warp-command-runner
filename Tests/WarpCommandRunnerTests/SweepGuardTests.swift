import XCTest
import Foundation
import Logging
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
                    "rm --recursive --force /", "echo hi; rm -fr /", "/bin/rm -rf /",
                    #"\rm -rf /"#, "r''m -rf /", #""rm" -rf /"#, "rm -rf /..", "rm -rf /tmp/../..",
                    "rm -rf ~", "rm -rf ~/", "rm -rf $HOME", "rm -rf ${HOME}/", "rm -rf \"$HOME\"",
                    "find / -delete", "find ~ -delete", "find / -exec rm {} +"] {
            XCTAssertTrue(c.isCommandBlocked(cmd), cmd)
        }
        for cmd in ["rm -rf ./build", "rm -f /tmp/x", "ls -la /", "rm -r /Users/me/old",
                    "rm -rf ~/old-build", "find . -delete", "find / -name x", "rm -rf $HOME/tmp/cache"] {
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
        let previous = ProcessInfo.processInfo.environment["WCR_HOME"]
        setenv("WCR_HOME", base.path, 1)
        defer {
            if let previous { setenv("WCR_HOME", previous, 1) } else { unsetenv("WCR_HOME") }
            try? FileManager.default.removeItem(at: base)
        }

        for path in [TempFiles.outputPath(commandId: "x"), TempFiles.scriptPath(commandId: "x"),
                     TempFiles.streamLogPath(commandId: "x"), TempFiles.streamExitPath(commandId: "x"),
                     TempFiles.streamScriptPath(commandId: "x"), TempFiles.stderrPath(commandId: "x")] {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            XCTAssertNotEqual(parent, "/tmp", path)
            XCTAssertNotEqual(parent, "/private/tmp", path)
            XCTAssertTrue(path.hasPrefix(base.path), path)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: TempFiles.directoryPath)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        XCTAssertEqual(TempFiles.scriptPOSIXPermissions, 0o700)
        XCTAssertTrue(createOutputCaptureScript(command: "true", commandId: "x").contains("umask 077"))
    }

    // MARK: request size cap

    #if os(macOS)
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
    #endif

    // MARK: WCR_HOME

    func testHomeOverrideRefusesRootAndHome() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        for raw in ["~", "~/", "/", "//", "/Users/someone", "/Users/someone/", "~/."] {
            XCTAssertNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": raw], userHome: home), raw)
        }
        XCTAssertNotNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": "/Users/someone/wcr-test"], userHome: home))
    }

    func testHomeOverrideRefusesAncestorsAndCaseVariants() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        for raw in ["/Users", "/USERS/someone", "/users/SOMEONE/", "/.", "/var/..", "/Users/someone/..",
                    "/Users/someone/sub/../..", "~/..", "/Users/someone/./"] {
            XCTAssertNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": raw], userHome: home), raw)
        }
        XCTAssertNotNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": "/Users/someone-else"], userHome: home))
    }

    func testHomeOverrideComparesFileIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wcr-id-\(UUID().uuidString)")
        let home = root.appendingPathComponent("parent/home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let linkToHome = root.appendingPathComponent("link-home")
        let linkToParent = root.appendingPathComponent("link-parent")
        try fm.createSymbolicLink(at: linkToHome, withDestinationURL: home)
        try fm.createSymbolicLink(at: linkToParent, withDestinationURL: home.deletingLastPathComponent())
        for raw in [linkToHome.path, linkToParent.path, root.path, home.deletingLastPathComponent().path] {
            XCTAssertNil(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": raw], userHome: home), raw)
        }
        let ok = home.appendingPathComponent("wcr-data").path
        XCTAssertEqual(AppPaths.resolvedHomeOverride(environment: ["WCR_HOME": ok], userHome: home)?.path, ok)
    }

    // MARK: server-level 413

    #if os(macOS)
    func testRemoteServerAnswers413ForOversizedBody() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-413-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let port = Int.random(in: 41000...59000)
        let issuer = "http://127.0.0.1:\(port)"
        let logger = Logger(label: "wcr-413-test")
        let server = RemoteHTTPServer(
            logger: logger,
            oauth: OAuthService(issuer: issuer, storeURL: tmp.appendingPathComponent("oauth.json")),
            bridge: HTTPBridgeTransport(logger: logger),
            listenPort: port,
            issuer: issuer
        )
        let task = Task { try await server.bind() }
        defer { task.cancel() }
        let url = URL(string: "\(issuer)/mcp")!
        let big = Data(repeating: 0x61, count: RequestBodyLimiter.defaultMaxBytes + 1024)

        func post(_ configure: (inout URLRequest) -> Void) async throws -> Int {
            var lastError: Error?
            for _ in 0..<50 {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                configure(&req)
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    return (resp as? HTTPURLResponse)?.statusCode ?? -1
                } catch {
                    lastError = error
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            throw lastError ?? URLError(.cannotConnectToHost)
        }

        // Declared Content-Length over the cap.
        let declared = try await post { $0.httpBody = big }
        XCTAssertEqual(declared, 413)
        // Streamed (chunked, no Content-Length) body over the cap.
        let streamed = try await post { $0.httpBodyStream = InputStream(data: big) }
        XCTAssertEqual(streamed, 413)
    }
    #endif

    // MARK: script mode writes into the private folder

    func testCaptureScriptWritesOwnerOnlyFilesInScratchFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-script-\(UUID().uuidString)")
        let previous = ProcessInfo.processInfo.environment["WCR_HOME"]
        setenv("WCR_HOME", base.path, 1)
        defer {
            if let previous { setenv("WCR_HOME", previous, 1) } else { unsetenv("WCR_HOME") }
            try? FileManager.default.removeItem(at: base)
        }
        let id = UUID().uuidString
        let scriptPath = TempFiles.scriptPath(commandId: id)
        try createOutputCaptureScript(command: "echo hello", commandId: id)
            .write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: TempFiles.scriptPOSIXPermissions], ofItemAtPath: scriptPath)
        let run = try await runProcess(executablePath: "/bin/bash", arguments: [scriptPath], timeout: 30)
        XCTAssertEqual(run.exitCode, 0)

        let out = TempFiles.outputPath(commandId: id)
        XCTAssertTrue(out.hasPrefix(base.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        for path in [scriptPath, out] {
            let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0o777
            XCTAssertEqual(mode & 0o077, 0, "\(path) is readable by others: \(String(mode, radix: 8))")
        }
        XCTAssertTrue((try String(contentsOfFile: out, encoding: .utf8)).contains("hello"))
    }
}
