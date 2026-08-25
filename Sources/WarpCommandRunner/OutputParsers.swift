import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Output Intelligence — Structured Parsing

/// Handle execute_and_parse tool — execute command and return structured output
func handleExecuteAndParse(params: CallTool.Parameters, logger: Logger, config: Configuration) async throws -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'command' parameter")],
            isError: true
        )
    }

    var workingDirectory: String?
    if let dir = arguments["working_directory"],
       case .string(let dirString) = dir {
        workingDirectory = dirString
    }

    // Security check
    if config.isCommandBlocked(commandString) {
        return CallTool.Result(
            content: [.text("🚫 Command blocked by security policy.")],
            isError: true
        )
    }

    logger.info("Execute and parse: \(commandString)")

    // Execute command directly (captures output in-process)
    var fullCommand = commandString
    if let dir = workingDirectory {
        fullCommand = "cd \"\(escapeForDoubleQuotedShell(dir))\" && \(commandString)"
    }

    do {
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", fullCommand],
            timeout: 600
        )

        let stdout = result.stdout
        let stderr = result.timedOut
            ? result.stderr + "\n[Command timed out after 600s and was terminated]"
            : result.stderr
        let exitCode = result.exitCode

        // Detect command type and apply parser
        let parsed = applyParser(command: commandString, stdout: stdout, stderr: stderr, exitCode: exitCode, logger: logger)

        return CallTool.Result(
            content: [.text(parsed)],
            isError: exitCode != 0
        )
    } catch {
        logger.error("Execute and parse failed: \(error)")
        return CallTool.Result(
            content: [.text("❌ Execution failed: \(error.localizedDescription)")],
            isError: true
        )
    }
}

// MARK: - Parser Detection & Application

private func applyParser(command: String, stdout: String, stderr: String, exitCode: Int32, logger: Logger) -> String {
    let cmd = command.trimmingCharacters(in: .whitespaces)

    // Try JSON passthrough first
    if let jsonParsed = tryParseJSON(stdout) {
        return """
        📊 Parsed Output (JSON):
        Exit Code: \(exitCode)

        \(jsonParsed)
        """
    }

    // Git status
    if cmd.hasPrefix("git status") {
        return parseGitStatus(stdout: stdout, exitCode: exitCode)
    }

    // Git log
    if cmd.hasPrefix("git log") {
        return parseGitLog(stdout: stdout, exitCode: exitCode)
    }

    // Docker ps
    if cmd.hasPrefix("docker ps") {
        return parseDockerPs(stdout: stdout, exitCode: exitCode)
    }

    // Test runners
    if cmd.contains("pytest") || cmd.contains("python -m pytest") {
        return parseTestResults(stdout: stdout, stderr: stderr, exitCode: exitCode, runner: "pytest")
    }
    if cmd.contains("npm test") || cmd.contains("npx jest") || cmd.contains("jest") {
        return parseTestResults(stdout: stdout, stderr: stderr, exitCode: exitCode, runner: "jest/npm")
    }
    if cmd.hasPrefix("swift test") {
        return parseTestResults(stdout: stdout, stderr: stderr, exitCode: exitCode, runner: "swift test")
    }

    // ls -la
    if cmd.hasPrefix("ls -l") || cmd.hasPrefix("ls -al") || cmd.hasPrefix("ls -la") {
        return parseLsLong(stdout: stdout, exitCode: exitCode)
    }

    // Default: return raw with metadata
    return """
    📊 Command Output:
    Exit Code: \(exitCode)

    stdout:
    \(stdout.isEmpty ? "(empty)" : stdout)
    \(stderr.isEmpty ? "" : "\nstderr:\n\(stderr)")
    """
}

// MARK: - Individual Parsers

private func parseGitStatus(stdout: String, exitCode: Int32) -> String {
    // Detect the input format. `git status` (human) starts with "On branch X"
    // or "HEAD detached" or "Not a git repository". `git status --porcelain`
    // produces 2-char status codes per line (or "## branch" with --branch).
    // Earlier versions of this parser assumed porcelain unconditionally and
    // mis-parsed human output (treating "On branch main" as status code "On"
    // for file " branch main"). Fixed in v6.0.1 to dispatch by format.
    let lines = stdout.components(separatedBy: "\n")
    let isHuman = lines.contains { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("On branch ")
            || t.hasPrefix("HEAD detached")
            || t.hasPrefix("Not a git repository")
            || t == "nothing to commit, working tree clean"
            || t.hasPrefix("Changes to be committed")
            || t.hasPrefix("Changes not staged for commit")
            || t.hasPrefix("Untracked files")
    }

    return isHuman
        ? parseGitStatusHuman(lines: lines)
        : parseGitStatusPorcelain(lines: lines)
}

/// Parse human-readable `git status` output. Tracks the current section
/// ("Changes to be committed", "Changes not staged", "Untracked files")
/// and assigns indented file lines accordingly.
private func parseGitStatusHuman(lines: [String]) -> String {
    var staged: [String] = []
    var unstaged: [String] = []
    var untracked: [String] = []
    var branch = "unknown"

    enum Section { case none, staged, unstaged, untracked }
    var section: Section = .none

    for raw in lines {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("On branch ") {
            branch = String(trimmed.dropFirst("On branch ".count))
            section = .none
            continue
        }
        if trimmed.hasPrefix("HEAD detached") {
            branch = "(detached HEAD)"
            section = .none
            continue
        }

        if trimmed.hasPrefix("Changes to be committed") {
            section = .staged; continue
        }
        if trimmed.hasPrefix("Changes not staged for commit") {
            section = .unstaged; continue
        }
        if trimmed.hasPrefix("Untracked files") {
            section = .untracked; continue
        }

        // Section terminators / informational lines we explicitly skip.
        if trimmed.isEmpty
            || trimmed.hasPrefix("(use ")
            || trimmed.hasPrefix("Your branch")
            || trimmed == "nothing to commit, working tree clean"
            || trimmed == "no changes added to commit (use \"git add\" and/or \"git commit -a\")" {
            continue
        }

        // File entries are indented with at least one tab/space.
        guard raw.first == " " || raw.first == "\t" else { continue }

        switch section {
        case .staged:
            // Format: "modified:   path", "new file:   path", "deleted:    path", "renamed:    old -> new"
            staged.append(trimmed)
        case .unstaged:
            unstaged.append(trimmed)
        case .untracked:
            untracked.append(trimmed)
        case .none:
            break
        }
    }

    return formatGitStatus(branch: branch, staged: staged, unstaged: unstaged, untracked: untracked)
}

/// Parse porcelain v1 `git status --porcelain` output. Each line is
/// "XY <path>" where X is the staged status, Y the worktree status,
/// and "??" indicates untracked.
private func parseGitStatusPorcelain(lines: [String]) -> String {
    var staged: [String] = []
    var unstaged: [String] = []
    var untracked: [String] = []
    var branch = "unknown"

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // --branch header line, e.g. "## main...origin/main"
        if trimmed.hasPrefix("##") {
            let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let first = body.split(separator: ".").first {
                branch = String(first).trimmingCharacters(in: .whitespaces)
            }
            continue
        }

        // Need at least "XY " + a filename.
        guard line.count >= 4 else { continue }

        let chars = Array(line)
        let staged_ch = chars[0]
        let work_ch = chars[1]
        // Path begins after the 2-char code and a separator space.
        let file = String(line.dropFirst(3))

        if staged_ch == "?" && work_ch == "?" {
            untracked.append(file)
            continue
        }
        if staged_ch != " " {
            staged.append("\(staged_ch) \(file)")
        }
        if work_ch != " " {
            unstaged.append("\(work_ch) \(file)")
        }
    }

    return formatGitStatus(branch: branch, staged: staged, unstaged: unstaged, untracked: untracked)
}

private func formatGitStatus(branch: String, staged: [String], unstaged: [String], untracked: [String]) -> String {
    var out = "🔀 Git Status (parsed):\n"
    out += "Branch: \(branch)\n"
    out += "Staged: \(staged.isEmpty ? "none" : "\(staged.count) file(s)")"
    if !staged.isEmpty {
        out += "\n" + staged.map { "  • \($0)" }.joined(separator: "\n")
    }
    out += "\nUnstaged: \(unstaged.isEmpty ? "none" : "\(unstaged.count) file(s)")"
    if !unstaged.isEmpty {
        out += "\n" + unstaged.map { "  • \($0)" }.joined(separator: "\n")
    }
    out += "\nUntracked: \(untracked.isEmpty ? "none" : "\(untracked.count) file(s)")"
    if !untracked.isEmpty {
        out += "\n" + untracked.map { "  • \($0)" }.joined(separator: "\n")
    }
    return out
}

private func parseGitLog(stdout: String, exitCode: Int32) -> String {
    var commits: [String] = []

    for line in stdout.components(separatedBy: "\n") where !line.isEmpty {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            commits.append(trimmed)
        }
    }

    return """
    📜 Git Log (parsed):
    Commits: \(commits.count)

    \(commits.prefix(20).enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
    \(commits.count > 20 ? "\n  ... and \(commits.count - 20) more" : "")
    """
}

private func parseDockerPs(stdout: String, exitCode: Int32) -> String {
    let lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard lines.count > 1 else {
        return "🐳 Docker: No running containers"
    }

    var containers: [String] = []
    for line in lines.dropFirst() {
        containers.append("  • \(line.trimmingCharacters(in: .whitespaces))")
    }

    return """
    🐳 Docker Containers (parsed):
    Running: \(containers.count)

    \(containers.joined(separator: "\n"))
    """
}

private func parseTestResults(stdout: String, stderr: String, exitCode: Int32, runner: String) -> String {
    let combined = stdout + "\n" + stderr
    var passed = 0
    var failed = 0
    var skipped = 0
    var errors: [String] = []

    // pytest patterns
    if runner == "pytest" {
        // Look for summary line like "5 passed, 2 failed, 1 skipped"
        for line in combined.components(separatedBy: "\n") {
            if line.contains("passed") || line.contains("failed") || line.contains("error") {
                if let match = line.range(of: #"(\d+) passed"#, options: .regularExpression) {
                    passed = Int(line[match].split(separator: " ").first ?? "0") ?? 0
                }
                if let match = line.range(of: #"(\d+) failed"#, options: .regularExpression) {
                    failed = Int(line[match].split(separator: " ").first ?? "0") ?? 0
                }
                if let match = line.range(of: #"(\d+) skipped"#, options: .regularExpression) {
                    skipped = Int(line[match].split(separator: " ").first ?? "0") ?? 0
                }
            }
            if line.contains("FAILED") || line.contains("ERROR") {
                errors.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // Swift test patterns
    if runner == "swift test" {
        for line in combined.components(separatedBy: "\n") {
            if line.contains("Test Suite") && line.contains("passed") {
                // "Test Suite 'All tests' passed" pattern
            }
            if line.contains("Executed") {
                // "Executed 5 tests, with 0 failures" pattern
                if let match = line.range(of: #"Executed (\d+) test"#, options: .regularExpression) {
                    let numStr = line[match].split(separator: " ").dropFirst().first ?? "0"
                    passed = Int(numStr) ?? 0
                }
                if let match = line.range(of: #"(\d+) failure"#, options: .regularExpression) {
                    failed = Int(line[match].split(separator: " ").first ?? "0") ?? 0
                }
            }
        }
        passed = max(0, passed - failed)
    }

    let status = exitCode == 0 ? "✅ PASSED" : "❌ FAILED"

    return """
    🧪 Test Results (\(runner)):
    Status: \(status)
    Passed: \(passed)
    Failed: \(failed)
    Skipped: \(skipped)
    \(errors.isEmpty ? "" : "\nErrors:\n\(errors.prefix(10).map { "  • \($0)" }.joined(separator: "\n"))")
    """
}

private func parseLsLong(stdout: String, exitCode: Int32) -> String {
    let lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
    var entries: [String] = []
    var totalLine = ""

    for line in lines {
        if line.hasPrefix("total ") {
            totalLine = line
        } else {
            entries.append("  \(line)")
        }
    }

    return """
    📁 Directory Listing (parsed):
    \(totalLine.isEmpty ? "" : "\(totalLine)\n")Entries: \(entries.count)

    \(entries.joined(separator: "\n"))
    """
}

private func tryParseJSON(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }

    guard let data = trimmed.data(using: .utf8),
          let _ = try? JSONSerialization.jsonObject(with: data) else {
        return nil
    }

    // Re-serialize with pretty printing
    if let prettyData = try? JSONSerialization.data(withJSONObject: try! JSONSerialization.jsonObject(with: data), options: .prettyPrinted),
       let prettyString = String(data: prettyData, encoding: .utf8) {
        return prettyString
    }

    return trimmed
}
