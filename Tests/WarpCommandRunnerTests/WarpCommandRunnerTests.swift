import XCTest
import Foundation
import MCP
@testable import WarpCommandRunner
@testable import WCRIdentity

// MARK: - Interactive command detection

final class InteractiveCommandDetectorTests: XCTestCase {

    func testEditorsAreInteractive() {
        for cmd in ["vim file.txt", "nano notes.md", "  emacs init.el", "vi /etc/hosts"] {
            XCTAssertEqual(InteractiveCommandDetector.analyse(cmd).level, .interactive, "Expected interactive: \(cmd)")
        }
    }

    func testBareSSHIsInteractiveButRemoteCommandHintsExist() {
        let result = InteractiveCommandDetector.analyse("ssh user@host")
        XCTAssertEqual(result.level, .interactive)
        XCTAssertNotNil(result.suggestion)
    }

    func testProcessMonitorsAndPagersAreInteractive() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("top").level, .interactive)
        XCTAssertEqual(InteractiveCommandDetector.analyse("htop").level, .interactive)
        XCTAssertEqual(InteractiveCommandDetector.analyse("less /var/log/system.log").level, .interactive)
    }

    func testBareREPLsAreInteractive() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("python3").level, .interactive)
        XCTAssertEqual(InteractiveCommandDetector.analyse("node").level, .interactive)
    }

    func testScriptedInterpreterIsSafe() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("python3 script.py").level, .safe)
    }

    func testInteractiveGitModes() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("git rebase -i HEAD~3").level, .interactive)
        XCTAssertEqual(InteractiveCommandDetector.analyse("git add -p").level, .interactive)
        XCTAssertEqual(InteractiveCommandDetector.analyse("git add .").level, .safe)
    }

    func testSudoIsCautious() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("sudo systemsetup -getcomputername").level, .cautious)
    }

    func testCurlPipedToShellIsCautious() {
        XCTAssertEqual(InteractiveCommandDetector.analyse("curl -fsSL https://example.com/x.sh | sh").level, .cautious)
    }

    func testPlainCommandsAreSafe() {
        for cmd in ["ls -la", "git status", "swift build", "echo hello", "cat file | grep x | sort"] {
            XCTAssertEqual(InteractiveCommandDetector.analyse(cmd).level, .safe, "Expected safe: \(cmd)")
        }
    }

    func testPipelineSegmentDetection() {
        // The pager hides at the end of a pipeline
        XCTAssertEqual(InteractiveCommandDetector.analyse("git log | less").level, .interactive)
        // A quoted pipe must NOT split the command
        XCTAssertEqual(InteractiveCommandDetector.analyse("echo \"a | less\"").level, .safe)
    }
}

// MARK: - Auto-retrieve command-ID contract

final class ExtractCommandIdTests: XCTestCase {

    /// Pins the coupling between execute_command's display output and
    /// auto-retrieve's regex. If the wording changes, this test fails
    /// instead of auto-retrieve silently breaking.
    func testExtractsIdFromExecuteCommandOutput() {
        let id = UUID().uuidString // uppercase hex + dashes, matches [A-F0-9\-]+
        let display = """
        ✅ Command sent to Warp:
        swift build

        📋 Command ID: \(id)

        💡 Command executes automatically. After it completes, use 'get_command_output' with ID: \(id)
        """
        XCTAssertEqual(extractCommandId(from: display), id)
    }

    func testReturnsNilWhenAbsent() {
        XCTAssertNil(extractCommandId(from: "no id in this text"))
    }
}

// MARK: - Escaping helpers

final class EscapingTests: XCTestCase {

    func testShellEscapingNeutralisesBreakout() {
        XCTAssertEqual(escapeForDoubleQuotedShell(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(escapeForDoubleQuotedShell("$HOME"), "\\$HOME")
        XCTAssertEqual(escapeForDoubleQuotedShell("`id`"), "\\`id\\`")
        XCTAssertEqual(escapeForDoubleQuotedShell(#"back\slash"#), #"back\\slash"#)
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(escapeForAppleScript(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(escapeForAppleScript(#"a\b"#), #"a\\b"#)
    }

    func testEscapedDirectoryStaysInsideQuotesInRealShell() async throws {
        // End-to-end: a hostile "directory" must not execute its payload.
        let hostile = #"/tmp" && echo INJECTED && cd ""#
        let cmd = "cd \"\(escapeForDoubleQuotedShell(hostile))\" && echo SAFE"
        let result = try await runProcess(executablePath: "/bin/bash", arguments: ["-c", cmd], timeout: 10)
        XCTAssertFalse(result.stdout.contains("INJECTED"), "Escaping failed — injection executed")
        // cd into the bogus path fails, so the command errors — that's fine,
        // the point is the payload never ran.
    }
}

// MARK: - Parameter helpers

final class ParameterHelperTests: XCTestCase {

    func testIntArgumentAcceptsAllRepresentations() {
        XCTAssertEqual(intArgument(.int(42)), 42)
        XCTAssertEqual(intArgument(.double(42.0)), 42)
        XCTAssertEqual(intArgument(.string("42")), 42)
        XCTAssertNil(intArgument(.string("not a number")))
        XCTAssertNil(intArgument(nil))
        XCTAssertNil(intArgument(.bool(true)))
    }

    func testDoubleArgumentAcceptsAllRepresentations() {
        XCTAssertEqual(doubleArgument(.double(2.5)), 2.5)
        XCTAssertEqual(doubleArgument(.int(2)), 2.0)
        XCTAssertEqual(doubleArgument(.string("2.5")), 2.5)
        XCTAssertNil(doubleArgument(nil))
    }
}

// MARK: - Configuration

final class ConfigurationTests: XCTestCase {

    func testEmptyJSONDecodesToDefaults() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        XCTAssertEqual(config.history.retentionDays, 90)
        XCTAssertFalse(config.security.blockedCommands.isEmpty)
    }

    func testBlocklistMatchesKnownDangerousCommand() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        XCTAssertTrue(config.isCommandBlocked("chmod -R 777 /"))
        XCTAssertFalse(config.isCommandBlocked("ls -la"))
    }
}

// MARK: - Database round-trip

final class DatabaseManagerTests: XCTestCase {

    private var dbPath: String!
    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "ccr_test_\(UUID().uuidString).db"
        db = DatabaseManager(path: dbPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testSaveAndRetrieveCommand() {
        let record = CommandRecord(
            id: UUID().uuidString,
            command: "echo round-trip",
            directory: "/tmp",
            terminalType: "Warp"
        )
        XCTAssertTrue(db.saveCommand(record))

        let recent = db.getRecentCommands(limit: 5)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.command, "echo round-trip")
        XCTAssertEqual(recent.first?.directory, "/tmp")
        XCTAssertNil(recent.first?.exitCode)
    }

    func testUpdateCommandRecordsCompletion() {
        let id = UUID().uuidString
        XCTAssertTrue(db.saveCommand(CommandRecord(id: id, command: "swift build")))
        XCTAssertTrue(db.updateCommand(id, stdout: "Build complete!", stderr: "", exitCode: 0, completedAt: Date()))

        let recent = db.getRecentCommands(limit: 1)
        XCTAssertEqual(recent.first?.exitCode, 0)
        XCTAssertEqual(recent.first?.stdout, "Build complete!")
        XCTAssertNotNil(recent.first?.durationMs)
    }

    func testSearchCommands() {
        XCTAssertTrue(db.saveCommand(CommandRecord(command: "git status")))
        XCTAssertTrue(db.saveCommand(CommandRecord(command: "swift test")))

        let hits = db.searchCommands(query: "swift")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.command, "swift test")
    }

    func testCommandCountUsesCheapPath() {
        XCTAssertEqual(db.commandCount(), 0)
        XCTAssertTrue(db.saveCommand(CommandRecord(command: "a")))
        XCTAssertTrue(db.saveCommand(CommandRecord(command: "b")))
        XCTAssertEqual(db.commandCount(), 2)
    }

    func testCleanupOldCommands() {
        // A command started 10 days ago should fall to a 7-day retention sweep
        let old = CommandRecord(
            command: "ancient",
            startedAt: Date().addingTimeInterval(-10 * 24 * 3600)
        )
        let fresh = CommandRecord(command: "recent")
        XCTAssertTrue(db.saveCommand(old))
        XCTAssertTrue(db.saveCommand(fresh))

        let removed = db.cleanupOldCommands(olderThan: 7)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(db.commandCount(), 1)
        XCTAssertEqual(db.getRecentCommands(limit: 5).first?.command, "recent")
    }

    func testConcurrentWritesDoNotCorrupt() {
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                _ = self.db.saveCommand(CommandRecord(command: "cmd \(i)"))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(db.commandCount(), 50)
    }
}

// MARK: - Process runner

final class ProcessRunnerTests: XCTestCase {

    func testCapturesStdoutStderrAndExitCode() async throws {
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // ~1 MB on each stream — far beyond the ~64 KB pipe buffer that
        // deadlocked the old waitUntilExit-then-read pattern.
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", "yes A | head -c 1000000; yes B | head -c 1000000 >&2"],
            timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 1_000_000)
        XCTAssertEqual(result.stderr.count, 1_000_000)
    }

    func testTimeoutTerminatesHungProcess() async throws {
        let started = Date()
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", "sleep 30"],
            timeout: 1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Timed-out process should return promptly")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testWorkingDirectoryIsHonoured() async throws {
        #if os(macOS)
        let scratch = "/private/tmp"
        #else
        let scratch = "/tmp"
        #endif
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", "pwd"],
            currentDirectory: scratch
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), scratch)
    }
}

// MARK: - Output capture script

final class OutputCaptureScriptTests: XCTestCase {

    /// Execute the generated capture script for real and assert the JSON
    /// it produces decodes into CommandExecutionResult — including awkward
    /// output (quotes, unicode, non-zero exit).
    func testGeneratedScriptProducesDecodableJSON() async throws {
        let commandId = UUID().uuidString
        let script = createOutputCaptureScript(
            command: #"echo 'tricky "quoted" → unicode'; exit 7"#,
            commandId: commandId
        )

        let scriptPath = NSTemporaryDirectory() + "ccr_capture_\(commandId).sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
            try? FileManager.default.removeItem(atPath: TempFiles.outputPath(commandId: commandId))
            try? FileManager.default.removeItem(atPath: TempFiles.outputPath(commandId: commandId) + ".complete")
        }

        let run = try await runProcess(executablePath: "/bin/bash", arguments: [scriptPath], timeout: 30)
        XCTAssertEqual(run.exitCode, 7, "Capture script must propagate the command's exit code")

        let data = try Data(contentsOf: URL(fileURLWithPath: TempFiles.outputPath(commandId: commandId)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(CommandExecutionResult.self, from: data)

        XCTAssertEqual(result.commandId, commandId)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.output.contains(#"tricky "quoted" → unicode"#))
    }
}

// MARK: - Product identity (v7 rebrand)

final class AppIdentityTests: XCTestCase {

    func testPublicNameHasNoClaudeProductBranding() {
        XCTAssertEqual(AppIdentity.displayName, "Warp Command Runner")
        XCTAssertEqual(AppIdentity.commandName, "warp-command-runner")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.m-pineapple.warp-command-runner")
        XCTAssertEqual(AppIdentity.version, "8.0.4")
        XCTAssertFalse(AppIdentity.commandName.contains("claude"))
        XCTAssertFalse(AppIdentity.bundleIdentifier.contains("claude"))
        XCTAssertFalse(AppIdentity.configDirectoryName.contains("claude"))
    }

    func testLegacyPathsAreRememberedForMigration() {
        XCTAssertEqual(AppIdentity.legacyConfigDirectoryName, ".claude-command-runner")
        XCTAssertEqual(AppIdentity.legacyDatabaseFileName, "claude_commands.db")
        XCTAssertEqual(AppIdentity.legacyOutputPrefix, "claude_output_")
        XCTAssertEqual(AppIdentity.legacyScriptPrefix, "claude_script_")
    }

    func testTempFileHelpersUseCurrentPrefix() {
        let dir = TempFiles.directoryPath
        XCTAssertEqual(TempFiles.outputPath(commandId: "abc"), "\(dir)/wcr_output_abc.json")
        XCTAssertEqual(TempFiles.scriptPath(commandId: "abc"), "\(dir)/wcr_script_abc.sh")
        XCTAssertEqual(TempFiles.streamLogPath(commandId: "abc"), "\(dir)/wcr_stream_abc.log")
        let needles = TempFiles.scriptNeedle(commandId: "abc")
        XCTAssertTrue(needles.contains("wcr_script_abc"))
        XCTAssertTrue(needles.contains("claude_script_abc"))
    }

    func testTempFilePrefixesCoverLegacyCaptureFiles() {
        XCTAssertTrue(AppIdentity.tempFilePrefixes.contains("wcr_output_"))
        XCTAssertTrue(AppIdentity.tempFilePrefixes.contains("claude_output_"))
        XCTAssertTrue(AppIdentity.tempFilePrefixes.contains("claude_script_"))
    }

    func testWCRHomeOverridesConfigDirectory() {
        let url = AppPaths.configDirectory(environment: [
            AppPaths.homeOverrideEnvironmentKey: "/tmp/wcr-home-override-test"
        ])
        XCTAssertEqual(url.path, "/tmp/wcr-home-override-test")
    }

    func testWCRHomeExpandsTilde() {
        let url = AppPaths.configDirectory(environment: [
            AppPaths.homeOverrideEnvironmentKey: "~/wcr-home-tilde-test"
        ])
        XCTAssertEqual(
            url.path,
            (NSString("~/wcr-home-tilde-test").expandingTildeInPath as String)
        )
        XCTAssertFalse(url.path.contains("~"))
    }

    func testEmptyWCRHomeFallsBackToDefaultDotDir() {
        let url = AppPaths.configDirectory(environment: [
            AppPaths.homeOverrideEnvironmentKey: "   "
        ])
        XCTAssertEqual(url.lastPathComponent, AppIdentity.configDirectoryName)
    }

    func testAbsentWCRHomeUsesDefaultDotDir() {
        let url = AppPaths.configDirectory(environment: [:])
        XCTAssertEqual(url.lastPathComponent, AppIdentity.configDirectoryName)
        XCTAssertTrue(url.path.hasSuffix("/\(AppIdentity.configDirectoryName)"))
    }

    func testRelativeWCRHomeIsIgnored() {
        let url = AppPaths.configDirectory(environment: [
            AppPaths.homeOverrideEnvironmentKey: "relative-wcr-home"
        ])
        XCTAssertEqual(url.lastPathComponent, AppIdentity.configDirectoryName)
        XCTAssertNil(AppPaths.resolvedHomeOverride(environment: [
            AppPaths.homeOverrideEnvironmentKey: "./wcr-test"
        ]))
        XCTAssertFalse(AppPaths.usesHomeOverride(environment: [
            AppPaths.homeOverrideEnvironmentKey: "wcr-test"
        ]))
        XCTAssertTrue(AppPaths.usesHomeOverride(environment: [
            AppPaths.homeOverrideEnvironmentKey: "~/wcr-test"
        ]))
        XCTAssertTrue(AppPaths.usesHomeOverride(environment: [
            AppPaths.homeOverrideEnvironmentKey: "/tmp/wcr-absolute"
        ]))
    }

    func testWCRHomeDirectoryCreatedOwnerOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "wcr-perm-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: dir) }
        AppPaths.ensureConfigDirectory(at: dir, fileManager: fm)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let perms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.intValue & 0o777, 0o700)
    }

    func testLegacyMigrationSkippedWhenWCRHomeSet() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "wcr-mig-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        let legacy = fakeHome.appendingPathComponent(
            AppIdentity.legacyConfigDirectoryName,
            isDirectory: true
        )
        let isolated = root.appendingPathComponent("isolated", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "legacy-secret".write(
            to: legacy.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        AppPaths.migrateLegacyConfigIfNeeded(
            environment: [AppPaths.homeOverrideEnvironmentKey: isolated.path],
            userHome: fakeHome,
            fileManager: fm
        )

        XCTAssertTrue(fm.fileExists(atPath: isolated.path))
        XCTAssertFalse(fm.fileExists(atPath: isolated.appendingPathComponent("marker.txt").path))
        let defaultCurrent = fakeHome.appendingPathComponent(AppIdentity.configDirectoryName)
        XCTAssertFalse(fm.fileExists(atPath: defaultCurrent.path))
    }

    func testConfigManagerSharesAppPathsResolution() throws {
        let src = try String(
            contentsOf: DependencyFloorTests.root
                .appendingPathComponent("Sources/ConfigManager/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("import WCRIdentity"))
        XCTAssertTrue(src.contains("AppPaths.configDirectory"))
        XCTAssertTrue(src.contains("AppPaths.ensureConfigDirectory"))
        XCTAssertFalse(src.contains("home.appendingPathComponent(\".warp-command-runner\")"))
        XCTAssertFalse(src.contains("home.appendingPathComponent(\".claude-command-runner\")"))
    }
}

// MARK: - Remote MCP policy and OAuth helpers

final class RemotePolicyTests: XCTestCase {
    func testKeystrokeToolsDeniedByDefault() {
        for tool in ["execute_command", "execute_with_auto_retrieve", "execute_with_streaming", "run_template", "send_to_session"] {
            XCTAssertNotNil(RemotePolicy.denial(for: tool, allowKeystrokeTools: false), tool)
        }
    }

    func testPipelineAllowedRemotely() {
        XCTAssertNil(RemotePolicy.denial(for: "execute_pipeline", allowKeystrokeTools: false))
        XCTAssertNil(RemotePolicy.denial(for: "get_command_output", allowKeystrokeTools: false))
    }

    func testKeystrokeToolsAllowedWhenOptedIn() {
        XCTAssertNil(RemotePolicy.denial(for: "execute_command", allowKeystrokeTools: true))
    }

    func testShellAndKeystrokeRequireRemoteAuthorization() {
        XCTAssertTrue(RemotePolicy.requiresRemoteAuthorization("execute_pipeline"))
        XCTAssertTrue(RemotePolicy.requiresRemoteAuthorization("ssh_execute"))
        XCTAssertTrue(RemotePolicy.requiresRemoteAuthorization("execute_command"))
        XCTAssertFalse(RemotePolicy.requiresRemoteAuthorization("get_command_output"))
        XCTAssertFalse(RemotePolicy.requiresRemoteAuthorization("list_templates"))
    }
}

#if os(macOS)
final class OAuthCryptoTests: XCTestCase {
    func testS256MatchesKnownVector() {
        // RFC 7636 appendix B
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = OAuthCrypto.s256Challenge(verifier: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRegisterRejectsNonHTTPSRedirect() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-oauth-\(UUID().uuidString).json")
        let oauth = OAuthService(issuer: "https://mcp.example.com", storeURL: tmp)
        do {
            _ = try await oauth.register(clientName: "x", redirectURIs: ["http://evil.example/cb"])
            XCTFail("expected invalid redirect")
        } catch OAuthError.invalidRedirect {
            // expected
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPKCERoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let oauth = OAuthService(issuer: "https://mcp.example.com", storeURL: tmp)
        let client = try await oauth.register(
            clientName: "test",
            redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
        )
        let verifier = OAuthCrypto.randomURLSafe()
        let challenge = OAuthCrypto.s256Challenge(verifier: verifier)
        let pairing = PairingCapture()
        await oauth.setPairingDisplay { pairing.handle($0) }
        await oauth.preparePairing()
        XCTAssertEqual(pairing.code?.count, 8)
        let code = try await oauth.mintAuthorizationCode(
            clientId: client.clientId,
            redirectURI: "https://chatgpt.com/connector/oauth/callback",
            codeChallenge: challenge,
            resource: "https://mcp.example.com/mcp",
            pairingCode: pairing.code
        )
        let token = try await oauth.exchangeCode(
            code: code,
            clientId: client.clientId,
            redirectURI: "https://chatgpt.com/connector/oauth/callback",
            codeVerifier: verifier
        )
        XCTAssertTrue(token.scopes.contains("mcp"))
        let beforeRevoke = await oauth.validateAccessToken(token.token)
        XCTAssertNotNil(beforeRevoke)
        try await oauth.revoke(token: token.token)
        let afterRevoke = await oauth.validateAccessToken(token.token)
        XCTAssertNil(afterRevoke)
    }

    func testMintRequiresPairingCodeAndDoesNotBurnItOnUnknownClient() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let oauth = OAuthService(issuer: "https://mcp.example.com", storeURL: tmp)
        let client = try await oauth.register(
            clientName: "test",
            redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
        )
        let pairing = PairingCapture()
        await oauth.setPairingDisplay { pairing.handle($0) }
        await oauth.preparePairing()
        let issued = try XCTUnwrap(pairing.code)
        let challenge = OAuthCrypto.s256Challenge(verifier: OAuthCrypto.randomURLSafe())
        do {
            _ = try await oauth.mintAuthorizationCode(
                clientId: "missing-client",
                redirectURI: "https://chatgpt.com/connector/oauth/callback",
                codeChallenge: challenge,
                resource: nil,
                pairingCode: "ZZZZZZZZ"
            )
            XCTFail("unknown client must fail before pairing is consumed")
        } catch OAuthError.unknownClient {
            // expected
        }
        do {
            _ = try await oauth.mintAuthorizationCode(
                clientId: client.clientId,
                redirectURI: "https://chatgpt.com/connector/oauth/callback",
                codeChallenge: challenge,
                resource: nil,
                pairingCode: nil
            )
            XCTFail("expected pairingRequired")
        } catch OAuthError.pairingRequired {
            // expected
        }
        let authCode = try await oauth.mintAuthorizationCode(
            clientId: client.clientId,
            redirectURI: "https://chatgpt.com/connector/oauth/callback",
            codeChallenge: challenge,
            resource: nil,
            pairingCode: String(issued.prefix(4)) + "-" + String(issued.dropFirst(4))
        )
        XCTAssertFalse(authCode.isEmpty)
        do {
            _ = try await oauth.mintAuthorizationCode(
                clientId: client.clientId,
                redirectURI: "https://chatgpt.com/connector/oauth/callback",
                codeChallenge: challenge,
                resource: nil,
                pairingCode: issued
            )
            XCTFail("pairing code must be single-use")
        } catch OAuthError.pairingRequired {
            // expected
        }
    }

    func testInvalidRedirectDoesNotConsumeRegistrationQuota() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let oauth = OAuthService(issuer: "https://mcp.example.com", storeURL: tmp)
        for _ in 0..<RegistrationLimiter.maxPerWindow {
            do {
                _ = try await oauth.register(clientName: "x", redirectURIs: ["http://evil.example/cb"])
                XCTFail("expected invalidRedirect")
            } catch OAuthError.invalidRedirect {
                // expected
            }
        }
        _ = try await oauth.register(
            clientName: "ok",
            redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
        )
    }

    func testRegistrationLimitPerWindow() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let oauth = OAuthService(issuer: "https://mcp.example.com", storeURL: tmp)
        for i in 0..<RegistrationLimiter.maxPerWindow {
            _ = try await oauth.register(
                clientName: "c\(i)",
                redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
            )
        }
        do {
            _ = try await oauth.register(
                clientName: "overflow",
                redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
            )
            XCTFail("expected registrationLimited")
        } catch OAuthError.registrationLimited {
            // expected
        }
    }
}

private final class PairingCapture: @unchecked Sendable {
    var code: String?
    func handle(_ value: String) { code = value }
}

final class PairingCodeTests: XCTestCase {
    func testIssueIfNeededIsStableUntilExpiry() {
        var state = PairingCodeState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = state.issueIfNeeded(now: t)
        XCTAssertEqual(first?.count, 8)
        XCTAssertNil(state.issueIfNeeded(now: t.addingTimeInterval(60)))
        let rotated = state.issueIfNeeded(now: t.addingTimeInterval(PairingCodeState.lifetime + 1))
        XCTAssertNotNil(rotated)
        XCTAssertNotEqual(rotated, first)
    }

    func testConsumeIsSingleUseAndNormalizesHyphens() {
        var state = PairingCodeState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let raw = state.issueIfNeeded(now: t)!
        let pretty = String(raw.prefix(4)) + "-" + String(raw.dropFirst(4))
        XCTAssertTrue(state.consume(pretty.lowercased(), now: t))
        XCTAssertFalse(state.consume(pretty, now: t))
    }

    func testWrongCodeDoesNotConsumeUntilMaxFailures() {
        var state = PairingCodeState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let raw = state.issueIfNeeded(now: t)!
        for _ in 1..<PairingCodeState.maxFailures {
            XCTAssertFalse(state.consume("ZZZZZZZZ", now: t))
        }
        XCTAssertTrue(state.consume(raw, now: t))
    }

    func testMaxFailuresRotateTheCode() {
        var state = PairingCodeState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let raw = state.issueIfNeeded(now: t)!
        for _ in 0..<PairingCodeState.maxFailures {
            XCTAssertFalse(state.consume("ZZZZZZZZ", now: t))
        }
        XCTAssertFalse(state.consume(raw, now: t), "old code must be dead after max failures")
    }

    func testExpiredCodeFails() {
        var state = PairingCodeState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let raw = state.issueIfNeeded(now: t)!
        XCTAssertFalse(state.consume(raw, now: t.addingTimeInterval(PairingCodeState.lifetime + 1)))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PairingCodeState.constantTimeEquals("ABCD2345", "ABCD2345"))
        XCTAssertFalse(PairingCodeState.constantTimeEquals("ABCD2345", "ABCD2346"))
        XCTAssertFalse(PairingCodeState.constantTimeEquals("ABC", "ABCD2345"))
    }

    func testGenerateUsesUnambiguousAlphabet() {
        for _ in 0..<40 {
            let code = PairingCodeState.generate()
            XCTAssertEqual(code.count, 8)
            XCTAssertTrue(code.allSatisfy { PairingCodeState.alphabet.contains($0) })
            XCTAssertFalse(code.contains("0"))
            XCTAssertFalse(code.contains("O"))
            XCTAssertFalse(code.contains("1"))
            XCTAssertFalse(code.contains("I"))
            XCTAssertFalse(code.contains("L"))
        }
    }

    func testRegistrationLimiterCapsWindowAndTotal() {
        var limiter = RegistrationLimiter()
        let t = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<RegistrationLimiter.maxPerWindow {
            XCTAssertTrue(limiter.allow(existingClients: i, now: t), "\(i)")
        }
        XCTAssertFalse(limiter.allow(existingClients: RegistrationLimiter.maxPerWindow, now: t))
        XCTAssertTrue(limiter.allow(
            existingClients: RegistrationLimiter.maxPerWindow,
            now: t.addingTimeInterval(RegistrationLimiter.windowSeconds + 1)
        ))
        XCTAssertFalse(limiter.allow(existingClients: RegistrationLimiter.maxClients, now: t))
    }
}
#endif

final class TunnelDoctorTests: XCTestCase {
    func testDoctorMentionsUserOwnedTunnel() {
        var config = Configuration.default
        config.remote.publicBaseURL = "https://mcp.example.com"
        let report = TunnelDoctor.run(config: config)
        XCTAssertEqual(report.publicBaseURL, "https://mcp.example.com")
        XCTAssertTrue(report.lines.contains(where: { $0.contains("mcp.example.com/mcp") }))
        XCTAssertTrue(report.lines.contains(where: { $0.contains("does not host a relay") }))
    }
}

final class LaunchAgentPlistTests: XCTestCase {
    func testXmlEscapePreservesSpacesAndEscapesAmpersand() {
        let path = "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner"
        XCTAssertEqual(RemoteLaunchAgent.xmlEscape(path), path)
        XCTAssertEqual(RemoteLaunchAgent.xmlEscape("a&b"), "a&amp;b")
    }
}

final class RemoteHTTPBindPinTests: XCTestCase {
    func testBindHostIsLoopbackAndNeverWildcard() throws {
        let src = try readPinnedSource("Sources/WarpCommandRunner/Remote/RemoteHTTPServer.swift")
        XCTAssertTrue(src.contains("bind(host: \"127.0.0.1\""), "HTTP must bind loopback")
        XCTAssertFalse(src.contains("0.0.0.0"), "must not bind wildcard")
    }

    func testCLIExposesHTTPPortNotLegacyPortFlag() throws {
        let src = try readPinnedSource("Sources/WarpCommandRunner/WarpCommandRunner.swift")
        XCTAssertTrue(src.contains("var http: Bool"))
        XCTAssertTrue(src.contains("var httpPort: Int?"))
        XCTAssertFalse(src.contains("customLong(\"port\")"))
    }

    private func readPinnedSource(_ relative: String) throws -> String {
        try Self.loadPinnedSource(relative)
    }

    static func loadPinnedSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty, "pinned file missing or empty: \(relative)")
        return String(decoding: data, as: UTF8.self)
    }
}

final class PairingCodePinTests: XCTestCase {
    func testHTTPLayerNeverReturnsOrDisplaysTheSecret() throws {
        let http = try RemoteHTTPBindPinTests.loadPinnedSource("Sources/WarpCommandRunner/Remote/RemoteHTTPServer.swift")
        XCTAssertFalse(http.contains("PairingCodeDisplay"), "pairing secret must not be composed into HTTP handlers")
        XCTAssertTrue(http.contains("name=\"pairing_code\""))
        XCTAssertTrue(http.contains("await oauth.preparePairing()"))
        XCTAssertTrue(http.contains("formnovalidate"))
        let oauth = try RemoteHTTPBindPinTests.loadPinnedSource("Sources/WarpCommandRunner/Remote/OAuthService.swift")
        XCTAssertTrue(oauth.contains("Never returns the code to HTTP callers"))
        XCTAssertTrue(oauth.contains("pairing.consume(pairingCode)"))
        let pairing = try RemoteHTTPBindPinTests.loadPinnedSource("Sources/WarpCommandRunner/Remote/PairingCode.swift")
        XCTAssertTrue(pairing.contains("constantTimeEquals"))
        XCTAssertTrue(pairing.contains("SecRandomCopyBytes"))
        let bridge = try RemoteHTTPBindPinTests.loadPinnedSource("Sources/WarpCommandRunner/Remote/HTTPBridgeTransport.swift")
        XCTAssertTrue(bridge.contains("func handle(body: Data, token: OAuthService.AccessToken?)"))
        XCTAssertTrue(bridge.contains("HTTPBridgeError.unauthorized"))
    }
}
