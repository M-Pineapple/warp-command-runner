import Foundation
import MCP
import Logging

/// Live execute_command path (no background monitoring — the prior monitoring
/// implementation triggered server crashes under concurrent dispatch).
///
/// Order of operations matters here:
/// 1. Validate + security checks (interactive detection, blocklist, length)
/// 2. Only then persist to history/analytics — previously the command was
///    recorded BEFORE the blocked-command check, so blocked commands showed
///    up in history as if they had executed.
/// 3. Dispatch to the terminal.
func handleExecuteCommandV2NoMonitoring(params: CallTool.Parameters, logger: Logger, config: Configuration) async throws -> CallTool.Result {
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

    // --- Interactive command detection ---
    // Ported from the retired V2 handler: the live path never applied this
    // guard, so editors/REPLs/pagers would hang the capture script.
    let interactivityCheck = InteractiveCommandDetector.analyse(commandString)

    switch interactivityCheck.level {
    case .interactive:
        // Block interactive commands — they'll hang the runner
        logger.warning("Blocked interactive command: \(commandString)")
        let warning = InteractiveCommandDetector.formatWarning(interactivityCheck)
        return CallTool.Result(content: [.text(warning)], isError: true)

    case .cautious:
        // Log a warning but proceed
        logger.info("Cautious command detected: \(commandString) — \(interactivityCheck.explanation)")

    case .safe, .blocked:
        break
    }

    // --- Security checks (before anything is persisted) ---
    // Build the full command first so the blocklist sees exactly what will
    // run, including the cd prefix derived from working_directory.
    var fullCommand = commandString
    if let dir = workingDirectory {
        fullCommand = "cd \"\(escapeForDoubleQuotedShell(dir))\" && \(commandString)"
    }

    if config.isCommandBlocked(commandString) || config.isCommandBlocked(fullCommand) {
        logger.warning("Blocked command attempted: \(fullCommand)")
        return CallTool.Result(
            content: [.text("🚫 Command blocked by security policy. This command matches a blocked pattern.")],
            isError: true
        )
    }

    if commandString.count > config.security.maxCommandLength {
        return CallTool.Result(
            content: [.text("📏 Command too long. Maximum length: \(config.security.maxCommandLength) characters.")],
            isError: true
        )
    }

    // Generate unique command ID and record in database
    let commandId = UUID().uuidString
    logger.info("Executing command with ID: \(commandId)")
    logger.info("Command: \(commandString)")

    // Start database record
    let terminalType = config.getPreferredTerminal() ?? TerminalConfig.getPreferredTerminal()
    let projectId = DatabaseManager.shared.detectProjectFromDirectory(workingDirectory ?? FileManager.default.currentDirectoryPath)

    let commandRecord = CommandRecord(
        id: commandId,
        command: commandString,
        directory: workingDirectory,
        terminalType: terminalType.rawValue,
        projectId: projectId
    )

    _ = DatabaseManager.shared.saveCommand(commandRecord)

    // Record analytics event
    DatabaseManager.shared.recordAnalyticsEvent("command_executed", data: [
        "terminal": terminalType.rawValue,
        "has_project": projectId != nil
    ])

    let preferredTerminal = terminalType
    logger.info("Using terminal: \(preferredTerminal.rawValue)")

    // Create the output capture script
    let scriptContent = createOutputCaptureScript(command: fullCommand, commandId: commandId)
    let tempScriptFile = TempFiles.scriptPath(commandId: commandId)

    do {
        try scriptContent.write(toFile: tempScriptFile, atomically: true, encoding: .utf8)
        // Make script executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptFile)
    } catch {
        logger.error("Failed to write script file: \(error)")
        return CallTool.Result(
            content: [.text("Failed to prepare command: \(error.localizedDescription)")],
            isError: true
        )
    }

    // Send to terminal using AppleScript (via the shared runner: concurrent
    // pipe drain + timeout, and no cooperative-pool blocking)
    let bashCommand = "bash \(tempScriptFile)"
    let appleScript = createAppleScript(for: preferredTerminal, command: bashCommand)

    do {
        let dispatch = try await runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: 30
        )

        if dispatch.timedOut {
            logger.error("osascript timed out dispatching to \(preferredTerminal.rawValue)")
            return CallTool.Result(
                content: [.text("Failed to send command: AppleScript dispatch timed out after 30s (is \(preferredTerminal.rawValue) responding?)")],
                isError: true
            )
        }

        if dispatch.exitCode == 0 {
            // Command sent successfully
            logger.info("Command sent to \(preferredTerminal.rawValue)")

            // Include caution warning if command was flagged
            let cautionPrefix: String
            if interactivityCheck.level == .cautious {
                cautionPrefix = InteractiveCommandDetector.formatWarning(interactivityCheck) + "\n\n"
            } else {
                cautionPrefix = ""
            }

            let result = """
            \(cautionPrefix)✅ Command sent to \(preferredTerminal.rawValue):
            \(commandString)

            📋 Command ID: \(commandId)

            💡 Command executes automatically. After it completes, use 'get_command_output' with ID: \(commandId)
            """

            return CallTool.Result(content: [.text(result)], isError: false)
        } else {
            let error = dispatch.stderr.isEmpty ? "Unknown error" : dispatch.stderr
            logger.error("Failed to send command to \(preferredTerminal.rawValue): \(error)")

            // Provide helpful error message
            let installedTerminals = TerminalConfig.detectInstalledTerminals()
            var errorMessage = "Failed to send command to \(preferredTerminal.rawValue): \(error)"

            if !installedTerminals.contains(preferredTerminal) {
                errorMessage += "\n\n⚠️ \(preferredTerminal.rawValue) is not installed."
                if !installedTerminals.isEmpty {
                    errorMessage += "\nAvailable terminals: \(installedTerminals.map { $0.rawValue }.joined(separator: ", "))"
                }
            }

            return CallTool.Result(
                content: [.text(errorMessage)],
                isError: true
            )
        }
    } catch {
        logger.error("Failed to send command: \(error)")
        return CallTool.Result(
            content: [.text("Failed to send command: \(error.localizedDescription)")],
            isError: true
        )
    }
}
