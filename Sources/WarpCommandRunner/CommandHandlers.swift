import Foundation
import MCP
import Logging

// MARK: - Interactive Command Detection

/// Detects commands that require interactive terminal input (stdin, TTY)
/// and warns the user instead of hanging the runner
struct InteractiveCommandDetector {

    /// Classification of how interactive a command is
    enum InteractivityLevel: String {
        case safe           // Non-interactive, safe to execute
        case cautious       // Might prompt for input (e.g. sudo, apt install without -y)
        case interactive    // Definitely interactive (vim, ssh, top, etc.)
        case blocked        // Should never be run through the runner (rm -rf /)
    }

    /// Result of analysing a command for interactivity
    struct DetectionResult {
        let level: InteractivityLevel
        let command: String
        let matchedPattern: String?
        let explanation: String
        let suggestion: String?
    }

    /// Commands that are definitively interactive (require a TTY / stdin)
    private static let interactivePatterns: [(pattern: String, explanation: String, suggestion: String?)] = [
        // Editors
        ("^\\s*(vi|vim|nvim|nano|emacs|pico|joe|ed)\\b", "Text editor requires interactive terminal",
         "Use 'sed', 'awk', or redirect to file instead"),
        // Remote shells
        ("^\\s*ssh\\b(?!.*\\s+-[^\\s]*[fNT])", "SSH opens an interactive remote shell",
         "Use 'ssh user@host \"command\"' to run a remote command non-interactively"),
        // Interactive containers
        ("docker\\s+(exec|run)\\s+.*-[^\\s]*[it]", "Docker interactive/TTY mode requires terminal",
         "Remove -it flags or use 'docker exec container command' without TTY"),
        // Process monitors
        ("^\\s*(top|htop|btop|gtop|glances|nmon)\\b", "Process monitor requires interactive display",
         "Use 'top -l 1' (macOS) or 'ps aux' for a snapshot instead"),
        // REPLs and interpreters (without script argument)
        ("^\\s*(python3?|ruby|irb|node|swift|ghci|lua|perl)\\s*$", "REPL mode requires interactive input",
         "Provide a script file or use -c flag with inline code"),
        // Pagers
        ("^\\s*(less|more|most)\\b", "Pager requires interactive navigation",
         "Use 'cat' or redirect output to a file instead"),
        // Database CLIs (without -e or -c)
        ("^\\s*(mysql|psql|sqlite3|mongo|mongosh|redis-cli)\\s*$", "Database CLI opens interactive shell",
         "Add -e 'query' or pipe a SQL file: 'mysql < script.sql'"),
        ("^\\s*(mysql|psql)\\b(?!.*(-e|--execute|-c|--command|<))", "Database CLI may open interactive shell",
         "Use -e 'query' flag for non-interactive execution"),
        // Screen/tmux sessions
        ("^\\s*(screen|tmux)\\b(?!.*\\s+(kill|ls|list))", "Terminal multiplexer requires interactive session",
         "Use 'tmux send-keys' or 'tmux new-session -d' for non-interactive control"),
        // FTP/SFTP
        ("^\\s*(ftp|sftp|telnet)\\b", "Protocol client requires interactive session",
         "Use 'scp', 'rsync', or 'curl' for non-interactive file transfer"),
        // Interactive Git
        ("git\\s+(rebase\\s+-i|add\\s+-i|add\\s+-p|stash\\s+.*-p)", "Git interactive mode requires terminal input",
         "Use non-interactive equivalents (e.g. 'git add .' instead of 'git add -i')"),
    ]

    /// Commands that might prompt for confirmation
    private static let cautiousPatterns: [(pattern: String, explanation: String, suggestion: String?)] = [
        // Package managers without auto-yes
        ("^\\s*(apt|apt-get)\\s+install\\b(?!.*-y)", "May prompt for confirmation",
         "Add -y flag for non-interactive install"),
        ("^\\s*brew\\s+install\\b.*--cask", "Cask install may prompt for password", nil),
        // Sudo
        ("^\\s*sudo\\b", "May prompt for password",
         "Ensure passwordless sudo is configured, or run directly in terminal"),
        // Destructive commands
        ("rm\\s+.*-[^\\s]*r", "Recursive delete — confirm intent carefully", nil),
        // Overwrite prompts
        ("\\bcp\\b(?!.*-[nf])", "May prompt before overwriting files",
         "Add -f (force) or -n (no-overwrite) flag"),
        ("\\bmv\\b(?!.*-[nf])", "May prompt before overwriting files",
         "Add -f (force) or -n (no-overwrite) flag"),
        // SSH with potential key passphrase
        ("ssh\\b.*-i\\b", "May prompt for key passphrase", nil),
        // Curl/wget to pipe to shell
        ("(curl|wget)\\s+.*\\|\\s*(sudo\\s+)?(ba)?sh", "Piping remote script to shell — review before running",
         "Download the script first, inspect it, then execute"),
    ]

    /// Analyse a command string and return detection result
    static func analyse(_ command: String) -> DetectionResult {
        // Normalise: collapse whitespace, trim
        let normalised = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for piped commands — analyse each segment, plus the full
        // command. The full string matters for patterns that span a pipe
        // (e.g. "curl … | sh"): splitting first removed the pipe, so those
        // patterns could never match.
        let segments = splitPipeline(normalised) + [normalised]

        // Check interactive patterns (highest severity first)
        for segment in segments {
            for (pattern, explanation, suggestion) in interactivePatterns {
                if segment.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return DetectionResult(
                        level: .interactive,
                        command: normalised,
                        matchedPattern: pattern,
                        explanation: explanation,
                        suggestion: suggestion
                    )
                }
            }
        }

        // Check cautious patterns
        for segment in segments {
            for (pattern, explanation, suggestion) in cautiousPatterns {
                if segment.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return DetectionResult(
                        level: .cautious,
                        command: normalised,
                        matchedPattern: pattern,
                        explanation: explanation,
                        suggestion: suggestion
                    )
                }
            }
        }

        // Safe
        return DetectionResult(
            level: .safe,
            command: normalised,
            matchedPattern: nil,
            explanation: "Command appears safe for non-interactive execution",
            suggestion: nil
        )
    }

    /// Split a pipeline command (e.g. "cat file | grep x | sort") into segments
    private static func splitPipeline(_ command: String) -> [String] {
        // Naive split on | but respect quotes
        var segments: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                current.append(char)
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(char)
                continue
            }
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(char)
                continue
            }
            if char == "|" && !inSingleQuote && !inDoubleQuote {
                segments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.isEmpty {
            segments.append(current.trimmingCharacters(in: .whitespaces))
        }
        return segments
    }

    /// Format a detection result as a user-friendly warning message
    static func formatWarning(_ result: DetectionResult) -> String {
        var warning = ""

        switch result.level {
        case .interactive:
            warning += "⚠️  INTERACTIVE COMMAND DETECTED\n"
            warning += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            warning += "Command: \(result.command)\n"
            warning += "Issue: \(result.explanation)\n\n"
            warning += "This command requires an interactive terminal (TTY) and\n"
            warning += "will likely hang or fail when run through the command runner.\n"
            if let suggestion = result.suggestion {
                warning += "\n💡 Alternative: \(suggestion)\n"
            }
            warning += "\nRun this command directly in your terminal instead."

        case .cautious:
            warning += "⚡ CAUTION: Command may require input\n"
            warning += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            warning += "Command: \(result.command)\n"
            warning += "Note: \(result.explanation)\n"
            if let suggestion = result.suggestion {
                warning += "💡 Tip: \(suggestion)\n"
            }
            warning += "\nProceeding with execution, but it may hang if input is required."

        case .safe, .blocked:
            break // No warning needed
        }

        return warning
    }
}

// MARK: - MCP Tool Handler for Interactive Detection

/// Standalone tool: check if a command is interactive before running it
func handleCheckInteractive(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'command' parameter")],
            isError: true
        )
    }

    let result = InteractiveCommandDetector.analyse(commandString)

    var response = "🔍 Interactive Command Analysis\n"
    response += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    response += "Command: \(commandString)\n"
    response += "Level: \(result.level.rawValue.uppercased())\n"
    response += "Assessment: \(result.explanation)\n"

    if let pattern = result.matchedPattern {
        response += "Matched: \(pattern)\n"
    }
    if let suggestion = result.suggestion {
        response += "\n💡 Suggestion: \(suggestion)\n"
    }

    switch result.level {
    case .safe:
        response += "\n✅ Safe to execute through the command runner."
    case .cautious:
        response += "\n⚡ Proceed with caution — may prompt for input."
    case .interactive:
        response += "\n❌ Not recommended for command runner. Run directly in terminal."
    case .blocked:
        response += "\n🚫 This command should not be run through the command runner."
    }

    return CallTool.Result(content: [.text(response)], isError: false)
}

// NOTE: the retired handleExecuteCommandV2 (a near-verbatim copy of the live
// handler in CommandHandlersStable.swift, unreachable since v6.0) was removed.
// Its interactive-command guard now lives in the live path.
// createAppleScript is in TerminalUtilities.swift.
