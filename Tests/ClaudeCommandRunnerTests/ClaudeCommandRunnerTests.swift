import XCTest
import Foundation
import MCP
@testable import ClaudeCommandRunner

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
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", "pwd"],
            currentDirectory: "/private/tmp"
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "/private/tmp")
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
            try? FileManager.default.removeItem(atPath: "/tmp/claude_output_\(commandId).json")
            try? FileManager.default.removeItem(atPath: "/tmp/claude_output_\(commandId).json.complete")
        }

        let run = try await runProcess(executablePath: "/bin/bash", arguments: [scriptPath], timeout: 30)
        XCTAssertEqual(run.exitCode, 7, "Capture script must propagate the command's exit code")

        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/claude_output_\(commandId).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(CommandExecutionResult.self, from: data)

        XCTAssertEqual(result.commandId, commandId)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.output.contains(#"tricky "quoted" → unicode"#))
    }
}
