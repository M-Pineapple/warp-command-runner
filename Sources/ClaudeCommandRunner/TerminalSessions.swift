import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Multi-Terminal Orchestration

/// Represents a tracked terminal session (tab)
struct TerminalSession: Codable {
    let name: String
    let terminal: String // TerminalType rawValue
    let tabIndex: Int
    /// UUID we mint at creation time. Used by `focus_warp_session` *only*
    /// when externally bound to a real Warp session UUID (e.g. via the
    /// optional shell shim). The minted value is informational here; we
    /// don't claim it matches Warp's internal session ID. See TECH.md §4.2.
    let uuid: String
    let createdAt: Date
    var lastCommandAt: Date
    var commandCount: Int
}

/// Actor for thread-safe terminal session management
actor SessionManager {
    private var sessions: [String: TerminalSession] = [:]
    private var nextTabIndex: [String: Int] = [:] // per-terminal tab counter

    func register(name: String, terminal: TerminalConfig.TerminalType) -> TerminalSession {
        let termKey = terminal.rawValue
        let index = nextTabIndex[termKey, default: 0]
        nextTabIndex[termKey] = index + 1

        let session = TerminalSession(
            name: name,
            terminal: termKey,
            tabIndex: index,
            uuid: UUID().uuidString,
            createdAt: Date(),
            lastCommandAt: Date(),
            commandCount: 0
        )
        sessions[name] = session
        return session
    }

    func get(name: String) -> TerminalSession? {
        return sessions[name]
    }

    func updateLastCommand(name: String) {
        if var session = sessions[name] {
            session.lastCommandAt = Date()
            session.commandCount += 1
            sessions[name] = session
        }
    }

    func list() -> [TerminalSession] {
        return sessions.values.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(name: String) -> TerminalSession? {
        return sessions.removeValue(forKey: name)
    }

    func exists(name: String) -> Bool {
        return sessions[name] != nil
    }

    /// Return sessions that haven't received a command in the given interval
    func staleSessions(olderThan interval: TimeInterval) -> [TerminalSession] {
        let cutoff = Date().addingTimeInterval(-interval)
        return sessions.values
            .filter { $0.lastCommandAt < cutoff }
            .sorted { $0.lastCommandAt < $1.lastCommandAt }
    }

    /// Remove multiple sessions by name, returning the removed sessions
    func removeAll(names: [String]) -> [TerminalSession] {
        var removed: [TerminalSession] = []
        for name in names {
            if let session = sessions.removeValue(forKey: name) {
                removed.append(session)
            }
        }
        return removed
    }
}

/// Global session manager
let sessionManager = SessionManager()

// MARK: - AppleScript Generators for Tab Management

/// Generate AppleScript to open a new tab in the specified terminal
private func newTabAppleScript(for terminal: TerminalConfig.TerminalType) -> String {
    switch terminal {
    case .warp, .warpPreview:
        return """
        tell application "\(terminal.rawValue)" to activate
        delay 0.5
        tell application "System Events"
            tell process "\(terminal.rawValue)"
                click menu item "New Tab" of menu "File" of menu bar 1
            end tell
        end tell
        delay 1.0
        """

    case .iterm2:
        return """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window
                    create tab with default profile
                end tell
            end if
        end tell
        delay 0.5
        """

    case .terminal:
        return """
        tell application "Terminal"
            activate
            if (count of windows) = 0 then
                do script ""
            else
                tell application "System Events"
                    tell process "Terminal"
                        keystroke "t" using command down
                    end tell
                end tell
            end if
        end tell
        delay 0.5
        """

    case .alacritty:
        // Alacritty doesn't support multiple tabs natively; open new window
        return """
        tell application "Alacritty" to activate
        delay 0.3
        tell application "System Events"
            tell process "Alacritty"
                keystroke "n" using command down
            end tell
        end tell
        delay 1.0
        """
    }
}

/// Generate AppleScript to send a command to a specific tab in iTerm2
private func iterm2SendToTab(tabIndex: Int, command: String) -> String {
    let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    tell application "iTerm"
        activate
        tell current window
            set targetTab to tab \(tabIndex + 1)
            tell targetTab
                tell current session
                    write text "\(escapedCommand)"
                end tell
            end tell
        end tell
    end tell
    """
}

/// Generate AppleScript to send a command to a specific tab in Terminal.app
private func terminalSendToTab(tabIndex: Int, command: String) -> String {
    let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    tell application "Terminal"
        activate
        if (count of windows) > 0 then
            tell front window
                set current tab to tab \(tabIndex + 1)
                do script "\(escapedCommand)" in selected tab
            end tell
        end if
    end tell
    """
}

/// Generate AppleScript to send command to the CURRENT active tab (Warp/Alacritty — no native tab targeting)
/// Used by send_to_session to reuse existing tabs instead of opening new ones.
private func keystrokeSendToCurrentTab(terminal: TerminalConfig.TerminalType, command: String) -> String {
    let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    tell application "\(terminal.rawValue)" to activate
    delay 0.3
    tell application "System Events"
        keystroke "\(escapedCommand)"
        delay 0.2
        keystroke return
    end tell
    """
}

/// Generate AppleScript to close the current tab
private func closeTabAppleScript(for terminal: TerminalConfig.TerminalType) -> String {
    switch terminal {
    case .warp, .warpPreview:
        return """
        tell application "\(terminal.rawValue)" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(terminal.rawValue)"
                click menu item "Close Tab" of menu "File" of menu bar 1
            end tell
        end tell
        """

    case .alacritty:
        return """
        tell application "\(terminal.rawValue)" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(terminal.rawValue)"
                keystroke "w" using command down
            end tell
        end tell
        """

    case .iterm2:
        return """
        tell application "iTerm"
            tell current window
                close current tab
            end tell
        end tell
        """

    case .terminal:
        return """
        tell application "Terminal"
            if (count of windows) > 0 then
                tell front window
                    close selected tab
                end tell
            end if
        end tell
        """
    }
}

// MARK: - AppleScript Execution Helper

@discardableResult
private func executeAppleScript(_ script: String, logger: Logger) -> (success: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return (true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            logger.warning("AppleScript failed: \(error)")
            return (false, error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    } catch {
        logger.error("Failed to execute AppleScript: \(error)")
        return (false, error.localizedDescription)
    }
}

// MARK: - Tool Handlers

/// Handle open_terminal_tab tool
func handleOpenTerminalTab(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing required 'name' parameter — provide a name for this session")],
            isError: true
        )
    }

    // Check for duplicate session name
    if await sessionManager.exists(name: name) {
        return CallTool.Result(
            content: [.text("❌ Session '\(name)' already exists. Use 'send_to_session' to send commands, or 'close_session' to close it first.")],
            isError: true
        )
    }

    // Determine terminal type
    var terminal = TerminalConfig.getPreferredTerminal()
    if let termArg = arguments["terminal"], case .string(let termStr) = termArg {
        if let matched = TerminalConfig.TerminalType.allCases.first(where: {
            $0.rawValue.lowercased() == termStr.lowercased()
        }) {
            terminal = matched
        }
    }

    logger.info("Opening new terminal tab: \(name) in \(terminal.rawValue)")

    // Pull optional directory once — used by both the deeplink path (Warp)
    // and the AppleScript+keystroke path (other terminals).
    let directory: String? = {
        if let dirArg = arguments["directory"], case .string(let s) = dirArg {
            return s.isEmpty ? nil : s
        }
        return nil
    }()

    // Open new tab — deeplink for Warp, AppleScript for others.
    if terminal == .warp || terminal == .warpPreview {
        // v6.0: use warp://action/new_tab — no menu-clicking, no Accessibility
        // permission required for the open path. Directory is baked into the
        // URL so no follow-up `cd` keystroke is needed.
        let r = WarpDeeplinks.openNewTab(directory: directory, logger: logger)
        guard r.success else {
            return CallTool.Result(
                content: [.text("❌ Failed to open new Warp tab: \(r.error ?? "unknown error")")],
                isError: true
            )
        }
        // Brief delay for Warp to finish creating the tab before any
        // subsequent send_to_session keystrokes are dispatched.
        try? await Task.sleep(nanoseconds: 300_000_000)
    } else {
        let script = newTabAppleScript(for: terminal)
        let result = executeAppleScript(script, logger: logger)
        guard result.success else {
            return CallTool.Result(
                content: [.text("❌ Failed to open new tab in \(terminal.rawValue): \(result.output)")],
                isError: true
            )
        }
        if let dir = directory {
            let cdScript = keystrokeSendToCurrentTab(terminal: terminal, command: "cd \"\(dir)\"")
            executeAppleScript(cdScript, logger: logger)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // Register session
    let session = await sessionManager.register(name: name, terminal: terminal)

    var output: String
    if terminal == .warp || terminal == .warpPreview {
        // Honest reporting: `open warp://…` only confirms the URL was handed to
        // Warp, not that a tab was actually created — and Warp returns no
        // session UUID, so the tracking ID below is a local label only.
        output = """
        📨 New-tab request dispatched to \(terminal.rawValue) via warp:// deeplink: "\(name)"
        • Local tracking ID: \(session.uuid) (internal label, not Warp's session UUID)

        Note: Warp exposes no API to confirm a tab was created or to return its
        real session UUID, so this can't be verified from outside Warp. Commands
        you send next land in the currently-focused tab — Warp has no interface
        to target a specific tab.
        """
    } else {
        output = """
        ✅ New terminal tab opened: "\(name)"
        • Terminal: \(terminal.rawValue)
        • Tab index: \(session.tabIndex)
        • Session UUID: \(session.uuid)
        """
    }

    if let dir = directory {
        output += "\n• Directory: \(dir)"
    }

    output += "\n\n💡 Use 'send_to_session' with name \"\(name)\" to send commands."

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

/// Handle send_to_session tool
func handleSendToSession(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["session_name"] ?? arguments["name"],
          case .string(let name) = nameValue,
          let commandValue = arguments["command"],
          case .string(let command) = commandValue else {
        return CallTool.Result(
            content: [.text("Missing required parameters: 'session_name' and 'command'")],
            isError: true
        )
    }

    guard let session = await sessionManager.get(name: name) else {
        let available = await sessionManager.list().map { $0.name }.joined(separator: ", ")
        return CallTool.Result(
            content: [.text("❌ Session '\(name)' not found.\(available.isEmpty ? " No active sessions." : " Available: \(available)")")],
            isError: true
        )
    }

    guard let terminal = TerminalConfig.TerminalType(rawValue: session.terminal) else {
        return CallTool.Result(
            content: [.text("❌ Unknown terminal type: \(session.terminal)")],
            isError: true
        )
    }

    logger.info("Sending command to session '\(name)': \(command)")

    // Build terminal-specific script to target the right tab
    let script: String
    switch terminal {
    case .iterm2:
        script = iterm2SendToTab(tabIndex: session.tabIndex, command: command)
    case .terminal:
        script = terminalSendToTab(tabIndex: session.tabIndex, command: command)
    case .warp, .warpPreview, .alacritty:
        // Warp and Alacritty don't support tab targeting via AppleScript
        // Best effort: activate terminal and type into the current active tab (no new tab)
        script = keystrokeSendToCurrentTab(terminal: terminal, command: command)
    }

    let result = executeAppleScript(script, logger: logger)

    guard result.success else {
        return CallTool.Result(
            content: [.text("❌ Failed to send command to session '\(name)': \(result.output)")],
            isError: true
        )
    }

    await sessionManager.updateLastCommand(name: name)

    let terminalNote: String
    switch terminal {
    case .warp, .warpPreview, .alacritty:
        terminalNote = "\n⚠️  \(terminal.rawValue) does not support direct tab targeting — command sent to active tab."
    default:
        terminalNote = ""
    }

    return CallTool.Result(
        content: [.text("""
        ✅ Command sent to session "\(name)":
        $ \(command.count > 80 ? String(command.prefix(80)) + "..." : command)\(terminalNote)
        """)],
        isError: false
    )
}

/// Handle list_sessions tool
func handleListSessions(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    let sessions = await sessionManager.list()

    if sessions.isEmpty {
        return CallTool.Result(
            content: [.text("📂 No active terminal sessions.\n\n💡 Use 'open_terminal_tab' to create one.")],
            isError: false
        )
    }

    let formatter = ISO8601DateFormatter()
    var output = "📂 Active Terminal Sessions (\(sessions.count)):\n"

    for session in sessions {
        output += "\n  \(session.name)"
        output += "\n    Terminal: \(session.terminal)"
        output += "\n    Tab index: \(session.tabIndex)"
        output += "\n    Commands sent: \(session.commandCount)"
        output += "\n    Created: \(formatter.string(from: session.createdAt))"
        output += "\n    Last command: \(formatter.string(from: session.lastCommandAt))"
    }

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

/// Handle close_session tool
func handleCloseSession(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["session_name"] ?? arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing required 'session_name' parameter")],
            isError: true
        )
    }

    guard let session = await sessionManager.remove(name: name) else {
        return CallTool.Result(
            content: [.text("❌ Session '\(name)' not found.")],
            isError: true
        )
    }

    // Optionally close the actual tab
    var closeTab = false
    if let closeArg = arguments["close_tab"], case .bool(let shouldClose) = closeArg {
        closeTab = shouldClose
    }

    if closeTab, let terminal = TerminalConfig.TerminalType(rawValue: session.terminal) {
        logger.info("Closing terminal tab for session: \(name)")
        let script = closeTabAppleScript(for: terminal)
        executeAppleScript(script, logger: logger)
    }

    return CallTool.Result(
        content: [.text("""
        ✅ Session "\(name)" removed.
        • Commands sent: \(session.commandCount)
        \(closeTab ? "• Terminal tab close signal sent." : "• Terminal tab left open (pass close_tab: true to close).")
        """)],
        isError: false
    )
}

/// Handle cleanup_sessions tool — remove stale sessions and optionally close their tabs
func handleCleanupSessions(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    // Default: 30 minutes of inactivity = stale
    var staleMinutes: Double = 30
    if let arguments = params.arguments,
       let minutesValue = arguments["inactive_minutes"],
       case .string(let minsStr) = minutesValue,
       let mins = Double(minsStr) {
        staleMinutes = mins
    }

    var closeTabs = true
    if let arguments = params.arguments,
       let closeArg = arguments["close_tabs"],
       case .bool(let shouldClose) = closeArg {
        closeTabs = shouldClose
    }

    let interval = staleMinutes * 60 // convert to seconds
    let staleSessions = await sessionManager.staleSessions(olderThan: interval)

    if staleSessions.isEmpty {
        return CallTool.Result(
            content: [.text("✅ No stale sessions found (threshold: \(Int(staleMinutes)) minutes of inactivity).")],
            isError: false
        )
    }

    let staleNames = staleSessions.map { $0.name }
    let removed = await sessionManager.removeAll(names: staleNames)

    // Close terminal tabs if requested
    if closeTabs {
        for session in removed {
            if let terminal = TerminalConfig.TerminalType(rawValue: session.terminal) {
                let script = closeTabAppleScript(for: terminal)
                executeAppleScript(script, logger: logger)
                // Brief delay between tab closes to avoid AppleScript race conditions
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    let formatter = ISO8601DateFormatter()
    var output = "🧹 Cleaned up \(removed.count) stale session(s) (inactive > \(Int(staleMinutes)) min):\n"
    for session in removed {
        output += "\n  • \(session.name) — last active: \(formatter.string(from: session.lastCommandAt)), commands: \(session.commandCount)"
    }
    if closeTabs {
        output += "\n\n• Terminal tabs closed."
    } else {
        output += "\n\n• Sessions removed from tracking (tabs left open)."
    }

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}
