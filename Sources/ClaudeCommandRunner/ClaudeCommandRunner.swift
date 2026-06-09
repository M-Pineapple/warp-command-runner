import Foundation
import ArgumentParser
import MCP
import Logging
import ServiceLifecycle
import NIOCore

// Command execution result structure
struct CommandExecutionResult: Codable {
    let commandId: String
    let command: String
    let output: String
    let error: String
    let exitCode: Int32
    let timestamp: Date
}

// Actor for thread-safe command results storage
actor CommandResultsStore {
    private var results: [String: CommandExecutionResult] = [:]
    
    func store(_ result: CommandExecutionResult) {
        results[result.commandId] = result
        results["last"] = result
    }
    
    func retrieve(_ commandId: String) -> CommandExecutionResult? {
        return results[commandId]
    }
}

// Global results store
let commandResultsStore = CommandResultsStore()

@main
struct ClaudeCommandRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-command-runner",
        abstract: "MCP server bridging Claude Desktop and Warp Terminal",
        discussion: """
            Claude Command Runner acts as a bridge between Claude Desktop and Warp Terminal,
            enabling Claude to suggest terminal commands that can be executed seamlessly 
            within Warp's Agent Mode.
            
            Version 2.0: Now with two-way communication support!
            """
    )
    
    @Option(name: [.customLong("port"), .customShort("p")], help: "Port for the command receiver (default: 9876)")
    var port: Int = 9876
    
    @Option(name: [.customLong("log-level"), .customShort("l")], help: "Log level: debug, info, warning, error")
    var logLevel: String = "info"
    
    @Flag(name: .long, help: "Enable verbose logging")
    var verbose: Bool = false
    
    @Flag(name: .long, help: "Initialize configuration with example")
    var initConfig: Bool = false
    
    @Flag(name: .long, help: "Validate configuration")
    var validateConfig: Bool = false
    
    mutating func run() async throws {
        // Configure logging
        let logLevelStr = logLevel
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = Self.parseLogLevel(logLevelStr)
            return handler
        }
        
        let logger = Logger(label: "com.claude.command-runner")
        
        // Force database initialization at startup
        logger.info("Initializing database...")
        _ = DatabaseManager.shared
        logger.info("Database initialization complete")
        
        // v4.1.0: Perform temp file cleanup on startup
        performTempCleanup(logger: logger)
        
        // Handle configuration operations
        if initConfig {
            try ConfigurationManager.initializeWithExample(logger: logger)
            print("Configuration initialized at \(ConfigurationManager.configDirectoryPath)")
            return
        }
        
        // Load configuration
        let configManager = ConfigurationManager(logger: logger)
        let config = configManager.current
        
        if validateConfig {
            let errors = configManager.validate()
            if errors.isEmpty {
                print("✅ Configuration is valid")
            } else {
                print("❌ Configuration errors:")
                for error in errors {
                    print("  - \(error)")
                }
            }
            return
        }
        
        // Override with command line arguments if provided
        let actualPort = port != 9876 ? port : config.port
        let _ = logLevel != "info" ? logLevel : config.logging.level
        
        if verbose {
            logger.info("Starting Claude Command Runner MCP Server v2.0...")
            logger.info("Port: \(actualPort)")
            logger.info("Two-way communication: ENABLED")
            logger.info("Configuration loaded from: \(ConfigurationManager.configDirectoryPath)")
        }
        
        // Create the MCP server
        let server = Server(
            name: "Claude Command Runner",
            version: "6.1.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )
        
        // Add missing MCP protocol handlers
        await Self.setupResourceHandlers(server: server, logger: logger)
        await Self.setupPromptHandlers(server: server, logger: logger)
        
        // Add tool handlers
        await server.withMethodHandler(ListTools.self) { _ in
            logger.debug("Listing available tools")
            return ListTools.Result(tools: [
                Tool(
                    name: "suggest_command",
                    description: "Suggests a terminal command based on the user's request",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("The user's request or task description")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional project directory; enables context-aware git/Swift/Node suggestions")
                            ])
                        ]),
                        "required": .array([.string("query")])
                    ])
                ),
                Tool(
                    name: "execute_command",
                    description: "Executes a terminal command and captures its output. Preferred for quick commands (ls, git status, cat, echo, etc.) that don't need a visible terminal tab. Use open_terminal_tab only for long-running processes.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory for command execution")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "execute_with_auto_retrieve",
                    description: "Executes a command and automatically waits for and returns its output. Preferred for quick commands that don't need a visible terminal tab. Use open_terminal_tab only for long-running processes like builds or servers.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory for command execution")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "preview_command",
                    description: "Preview a command without executing it",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to preview")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "get_command_output",
                    description: "Retrieve the output of a previously executed command",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command_id": .object([
                                "type": .string("string"),
                                "description": .string("The command ID to retrieve output for (use 'last' for most recent)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // NEW v4.0 TOOLS
                Tool(
                    name: "execute_pipeline",
                    description: "Execute a pipeline of commands with conditional logic (stop/continue/warn on failure)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "steps": .object([
                                "type": .string("array"),
                                "description": .string("Array of step objects with 'command', 'on_fail' (stop/continue/warn), optional 'name' and 'working_directory'")
                            ])
                        ]),
                        "required": .array([.string("steps")])
                    ])
                ),
                Tool(
                    name: "execute_with_streaming",
                    description: "Execute a command with real-time output streaming - ideal for long-running builds",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory")
                            ]),
                            "update_interval": .object([
                                "type": .string("integer"),
                                "description": .string("Seconds between output updates (default: 2)")
                            ]),
                            "max_duration": .object([
                                "type": .string("integer"),
                                "description": .string("Maximum execution time in seconds (default: 120)")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "save_template",
                    description: "Save a command template with variables for reuse",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Unique name for the template")
                            ]),
                            "template": .object([
                                "type": .string("string"),
                                "description": .string("Command template with {{variable}} placeholders")
                            ]),
                            "description": .object([
                                "type": .string("string"),
                                "description": .string("Optional description of what the template does")
                            ]),
                            "category": .object([
                                "type": .string("string"),
                                "description": .string("Optional category for organization")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("template")])
                    ])
                ),
                Tool(
                    name: "run_template",
                    description: "Execute a saved command template with variable substitution",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the template to run")
                            ]),
                            "variables": .object([
                                "type": .string("object"),
                                "description": .string("Object with variable names and their values")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "list_templates",
                    description: "List all saved command templates",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "delete_template",
                    description: "Delete a saved command template by name",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the template to delete")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                // NEW v4.1 TOOLS
                Tool(
                    name: "list_recent_commands",
                    description: "List recent commands from history with status, duration, and exit codes",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "limit": .object([
                                "type": .string("string"),
                                "description": .string("Number of commands to return (1-50, default: 10)")
                            ]),
                            "status": .object([
                                "type": .string("string"),
                                "description": .string("Filter by status: 'all', 'success', 'failed' (default: all)")
                            ]),
                            "search": .object([
                                "type": .string("string"),
                                "description": .string("Search in command text")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "self_check",
                    description: "Run health check on configuration, database, terminal, and recent error rates",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // NEW v5.0.0 TOOLS — Clipboard Bridge
                Tool(
                    name: "copy_to_clipboard",
                    description: "Copy text to the macOS system clipboard",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("The text to copy to clipboard")
                            ])
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "read_from_clipboard",
                    description: "Read the current contents of the macOS system clipboard",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // Notification Preferences
                Tool(
                    name: "set_notification_preference",
                    description: "Toggle macOS notification preferences for command completion alerts",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "enabled": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable or disable notifications")
                            ]),
                            "sound": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable or disable notification sounds")
                            ]),
                            "notify_on_success": .object([
                                "type": .string("boolean"),
                                "description": .string("Notify on successful commands")
                            ]),
                            "notify_on_failure": .object([
                                "type": .string("boolean"),
                                "description": .string("Notify on failed commands")
                            ]),
                            "minimum_duration": .object([
                                "type": .string("number"),
                                "description": .string("Minimum command duration (seconds) before notification triggers")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // Environment Context
                Tool(
                    name: "get_environment_context",
                    description: "Get current terminal environment context including git branch, active venv, node version, docker status, and working directory",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional directory to check context for (defaults to current)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // Output Intelligence
                Tool(
                    name: "execute_and_parse",
                    description: "Execute a command and return structured parsed output (supports git status, git log, docker ps, test results, ls -la, and JSON)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute and parse")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory")
                            ]),
                            "parser": .object([
                                "type": .string("string"),
                                "description": .string("Force a specific parser: git_status, git_log, docker_ps, test_results, ls, json, auto (default: auto)")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                // Environment Snapshots
                Tool(
                    name: "capture_environment",
                    description: "Capture a snapshot of the current shell environment variables with a named label",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Label for this snapshot (e.g. 'before-install', 'clean-state')")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "diff_environment",
                    description: "Compare two environment snapshots and show additions, removals, and changes",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "from": .object([
                                "type": .string("string"),
                                "description": .string("Name of the 'before' snapshot")
                            ]),
                            "to": .object([
                                "type": .string("string"),
                                "description": .string("Name of the 'after' snapshot")
                            ])
                        ]),
                        "required": .array([.string("from"), .string("to")])
                    ])
                ),
                // Workspace Profiles
                Tool(
                    name: "save_workspace_profile",
                    description: "Save current project context as a named workspace profile (directory, commands, env vars, terminal preference). Optionally also writes a Warp-native launch config to ~/.warp/launch_configurations/ so the profile appears in Warp's launch UI.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Profile name (e.g. 'my-swift-project')")
                            ]),
                            "directory": .object([
                                "type": .string("string"),
                                "description": .string("Working directory for this profile")
                            ]),
                            "default_commands": .object([
                                "type": .string("array"),
                                "description": .string("Array of commonly used commands for this project")
                            ]),
                            "environment_vars": .object([
                                "type": .string("object"),
                                "description": .string("Environment variables to set when loading this profile")
                            ]),
                            "terminal_preference": .object([
                                "type": .string("string"),
                                "description": .string("Preferred terminal for this project (Warp, iTerm, Terminal)")
                            ]),
                            "include_warp_launch_config": .object([
                                "type": .string("boolean"),
                                "description": .string("When true, also write the profile as a Warp launch config under ~/.warp/launch_configurations/<name>.yaml. Default: false. Env vars are not emitted into the launch config (Warp schema does not support them at top level).")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("directory")])
                    ])
                ),
                Tool(
                    name: "load_workspace_profile",
                    description: "Load a saved workspace profile to restore project context",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the profile to load")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "list_workspace_profiles",
                    description: "List all saved workspace profiles",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "delete_workspace_profile",
                    description: "Delete a saved workspace profile",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the profile to delete")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                // Terminal Sessions
                Tool(
                    name: "open_terminal_tab",
                    description: "Open a new named terminal tab. ONLY use for long-running commands that need their own visible tab (builds, installs, servers, cloning repos). For quick commands, prefer execute_command or execute_with_auto_retrieve instead. If a session already exists, use send_to_session to reuse it.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name/label for this terminal session")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional initial working directory")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "send_to_session",
                    description: "Send a command to an existing named terminal session, reusing its tab. Always prefer this over opening a new tab when a relevant session already exists. Use list_sessions first to check for available sessions.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "session_name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the target session")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to send")
                            ])
                        ]),
                        "required": .array([.string("session_name"), .string("command")])
                    ])
                ),
                Tool(
                    name: "list_sessions",
                    description: "List all active terminal sessions. Check this before opening new tabs to avoid creating duplicates. Reuse existing sessions with send_to_session whenever possible.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "close_session",
                    description: "Close a named terminal session and optionally close its tab. Use to clean up sessions that are no longer needed. Pass close_tab: true to also close the terminal tab.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "session_name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the session to close")
                            ]),
                            "close_tab": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, also closes the terminal tab (default: false)")
                            ])
                        ]),
                        "required": .array([.string("session_name")])
                    ])
                ),
                Tool(
                    name: "cleanup_sessions",
                    description: "Remove stale terminal sessions that have been inactive. Use periodically to clean up accumulated tabs. Sessions inactive longer than inactive_minutes (default: 30) are removed. Set close_tabs to true to also close the terminal tabs.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "inactive_minutes": .object([
                                "type": .string("number"),
                                "description": .string("Minutes of inactivity before a session is considered stale (default: 30)")
                            ]),
                            "close_tabs": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, also closes the terminal tabs for stale sessions (default: true)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // File Watching
                Tool(
                    name: "add_file_watch",
                    description: "Set up a file system watcher that triggers a command when files change",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Directory path to watch")
                            ]),
                            "pattern": .object([
                                "type": .string("string"),
                                "description": .string("Glob pattern to filter (e.g. '*.swift', '*.ts')")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to run when files change")
                            ]),
                            "debounce_seconds": .object([
                                "type": .string("number"),
                                "description": .string("Debounce interval in seconds (default: 2.0)")
                            ])
                        ]),
                        "required": .array([.string("path"), .string("command")])
                    ])
                ),
                Tool(
                    name: "remove_file_watch",
                    description: "Remove an active file system watcher",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "watcher_id": .object([
                                "type": .string("string"),
                                "description": .string("ID of the watcher to remove")
                            ])
                        ]),
                        "required": .array([.string("watcher_id")])
                    ])
                ),
                Tool(
                    name: "list_file_watches",
                    description: "List all active file system watchers",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // SSH Execution
                Tool(
                    name: "ssh_execute",
                    description: "Execute a command on a remote host via SSH (key-based authentication only)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "host": .object([
                                "type": .string("string"),
                                "description": .string("Remote hostname or IP address")
                            ]),
                            "username": .object([
                                "type": .string("string"),
                                "description": .string("SSH username")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to execute remotely")
                            ]),
                            "identity_file": .object([
                                "type": .string("string"),
                                "description": .string("Path to SSH private key (optional)")
                            ]),
                            "port": .object([
                                "type": .string("integer"),
                                "description": .string("SSH port (default: 22)")
                            ]),
                            "timeout": .object([
                                "type": .string("integer"),
                                "description": .string("Connection timeout in seconds (default: 30)")
                            ]),
                            "profile": .object([
                                "type": .string("string"),
                                "description": .string("Name of saved SSH profile to use instead of specifying host/username/key")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "save_ssh_profile",
                    description: "Save an SSH connection profile for quick reuse",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Profile name")
                            ]),
                            "host": .object([
                                "type": .string("string"),
                                "description": .string("Remote hostname or IP")
                            ]),
                            "username": .object([
                                "type": .string("string"),
                                "description": .string("SSH username")
                            ]),
                            "identity_file": .object([
                                "type": .string("string"),
                                "description": .string("Path to SSH private key")
                            ]),
                            "port": .object([
                                "type": .string("integer"),
                                "description": .string("SSH port (default: 22)")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("host"), .string("username")])
                    ])
                ),
                Tool(
                    name: "list_ssh_profiles",
                    description: "List all saved SSH connection profiles",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "delete_ssh_profile",
                    description: "Delete a saved SSH connection profile",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the SSH profile to delete")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                // Interactive Command Detection
                Tool(
                    name: "check_interactive",
                    description: "Check if a command is interactive (requires TTY/stdin) before executing it. Returns safety level: safe, cautious, interactive, or blocked with suggestions for non-interactive alternatives",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to analyse for interactivity")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                // Warp v6.0 — deeplink + OSC 777 surface
                Tool(
                    name: "focus_warp_session",
                    description: "Focus an existing Warp pane by its session UUID via warp://session/<uuid>. The UUID must be one Warp itself recognises (typically obtained from the optional shell shim's OSC 777 session_start event). Locally-minted UUIDs returned by open_terminal_tab are NOT valid here.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "warp_uuid": .object([
                                "type": .string("string"),
                                "description": .string("Warp's own session UUID for the target pane")
                            ])
                        ]),
                        "required": .array([.string("warp_uuid")])
                    ])
                ),
                Tool(
                    name: "emit_warp_event",
                    description: "Build a printf invocation that emits an OSC 777 warp://cli-agent JSON event into Warp's notification UI. The returned printf must be executed inside a Warp pane (e.g. via execute_command) to take effect — our MCP stdout is the JSON-RPC channel and cannot directly write to Warp's PTY.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "event_type": .object([
                                "type": .string("string"),
                                "description": .string("One of: session_start, prompt_submit, tool_complete, stop, permission_request, idle_prompt")
                            ]),
                            "payload": .object([
                                "type": .string("string"),
                                "description": .string("JSON-encoded object string for the event payload (default: '{}')")
                            ]),
                            "session_id": .object([
                                "type": .string("string"),
                                "description": .string("Optional session_id to attach to the event")
                            ])
                        ]),
                        "required": .array([.string("event_type")])
                    ])
                ),
                Tool(
                    name: "shell_shim_status",
                    description: "Report the status of the optional shell shim — socket path, whether the MCP server is listening, total events received, and the most recent events. The shim is opt-in (helper/install-shim.sh); when active inside a Warp pane it streams preexec/command_finished events to the MCP via a per-uid Unix socket. Observability surface in v6.0; execute_command auto-routing through shim events is deferred to v6.0.x.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                )
            ])
        }
        
        await server.withMethodHandler(CallTool.self) { params in
            logger.info("Tool called: \(params.name)")
            
            switch params.name {
            case "suggest_command":
                return try await handleSuggestCommand(params: params, logger: logger)
            case "execute_command":
                // Use V2 without background monitoring to prevent crashes
                return try await handleExecuteCommandV2NoMonitoring(params: params, logger: logger, config: config)
            case "execute_with_auto_retrieve":
                // Use enhanced auto-retrieve with progressive delays
                return try await handleExecuteWithAutoRetrieveEnhanced(params: params, logger: logger, config: config)
            case "preview_command":
                return await handlePreviewCommand(params: params, logger: logger)
            case "get_command_output":
                return await handleGetCommandOutput(params: params, logger: logger)
            // NEW v4.0 TOOL HANDLERS
            case "execute_pipeline":
                return try await handleExecutePipeline(params: params, logger: logger, config: config)
            case "execute_with_streaming":
                return try await handleExecuteWithStreaming(params: params, logger: logger, config: config)
            case "save_template":
                return await handleSaveTemplate(params: params, logger: logger)
            case "run_template":
                return try await handleRunTemplate(params: params, logger: logger, config: config)
            case "list_templates":
                return await handleListTemplates(params: params, logger: logger)
            case "delete_template":
                return await handleDeleteTemplate(params: params, logger: logger)
            // NEW v4.1 TOOL HANDLERS
            case "list_recent_commands":
                return await handleListRecentCommands(params: params, logger: logger)
            case "self_check":
                return await handleSelfCheck(params: params, logger: logger)
            // NEW v5.0.0 TOOL HANDLERS — Clipboard
            case "copy_to_clipboard":
                return await handleCopyToClipboard(params: params, logger: logger)
            case "read_from_clipboard":
                return await handleReadFromClipboard(params: params, logger: logger)
            // Notifications
            case "set_notification_preference":
                return await handleSetNotificationPreference(params: params, logger: logger)
            // Environment Context
            case "get_environment_context":
                return await handleGetEnvironmentContext(params: params, logger: logger, config: config)
            // Output Intelligence
            case "execute_and_parse":
                return try await handleExecuteAndParse(params: params, logger: logger, config: config)
            // Environment Snapshots
            case "capture_environment":
                return await handleCaptureEnvironment(params: params, logger: logger)
            case "diff_environment":
                return await handleDiffEnvironment(params: params, logger: logger)
            // Workspace Profiles
            case "save_workspace_profile":
                return await handleSaveWorkspaceProfile(params: params, logger: logger)
            case "load_workspace_profile":
                return await handleLoadWorkspaceProfile(params: params, logger: logger)
            case "list_workspace_profiles":
                return await handleListWorkspaceProfiles(params: params, logger: logger)
            case "delete_workspace_profile":
                return await handleDeleteWorkspaceProfile(params: params, logger: logger)
            // Terminal Sessions
            case "open_terminal_tab":
                return await handleOpenTerminalTab(params: params, logger: logger)
            case "send_to_session":
                return await handleSendToSession(params: params, logger: logger)
            case "list_sessions":
                return await handleListSessions(params: params, logger: logger)
            case "close_session":
                return await handleCloseSession(params: params, logger: logger)
            case "cleanup_sessions":
                return await handleCleanupSessions(params: params, logger: logger)
            // File Watching
            case "add_file_watch":
                return await handleAddFileWatch(params: params, logger: logger)
            case "remove_file_watch":
                return await handleRemoveFileWatch(params: params, logger: logger)
            case "list_file_watches":
                return await handleListFileWatches(params: params, logger: logger)
            // Interactive Command Detection
            case "check_interactive":
                return await handleCheckInteractive(params: params, logger: logger)
            // SSH Execution
            case "ssh_execute":
                return await handleSSHExecute(params: params, logger: logger, config: config)
            case "save_ssh_profile":
                return await handleSaveSSHProfile(params: params, logger: logger)
            case "list_ssh_profiles":
                return await handleListSSHProfiles(params: params, logger: logger)
            case "delete_ssh_profile":
                return await handleDeleteSSHProfile(params: params, logger: logger)
            // Warp v6.0 — deeplink + OSC 777 surface
            case "focus_warp_session":
                return await handleFocusWarpSession(params: params, logger: logger)
            case "emit_warp_event":
                return await handleEmitWarpEvent(params: params, logger: logger)
            case "shell_shim_status":
                return await handleShellShimStatus(params: params, logger: logger)
            default:
                return CallTool.Result(
                    content: [.text("Unknown tool: \(params.name)")],
                    isError: true
                )
            }
        }
        
        // Create transport and start server
        let transport = StdioTransport(logger: logger)
        let mcpService = MCPService(server: server, transport: transport)

        // Tier E: optional shell-shim Unix-socket listener. Non-fatal on
        // failure — shim is opt-in observability.
        let shimChannel = startShellShimSocketIfPossible(logger: logger)

        // Create service group
        let serviceGroup = ServiceGroup(
            services: [mcpService],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )

        logger.info("MCP Server started successfully")
        if shimChannel != nil {
            logger.info("Shell shim socket active at \(shellShimSocketPath())")
        }
        
        // Add error handling for port conflicts
        do {
            // Run the service group
            try await serviceGroup.run()
        } catch {
            logger.error("Service group error: \(error)")
            
            // Check if it's a port binding error
            if let error = error as? NIOCore.IOError, error.errnoCode == EADDRINUSE {
                logger.error("Port \(actualPort) is already in use. Please stop any existing instances or use a different port.")
                print("\n❌ Error: Port \(actualPort) is already in use.")
                print("Try: lsof -i :\(actualPort) to find the process using this port")
                Foundation.exit(1)
            }
            
            throw error
        }
    }
    
    private static func parseLogLevel(_ level: String) -> Logger.Level {
        switch level.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        default: return .info
        }
    }
}

// Import the enhanced suggest command handler
// The basic implementation is replaced by CommandSuggestionEngine.swift

func handlePreviewCommand(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'command' parameter")],
            isError: true
        )
    }
    
    logger.debug("Previewing command: \(commandString)")
    
    let preview = """
    Command Preview:
    ================
    \(commandString)
    
    This command will be executed in your current shell environment.
    Use 'execute_command' to run it.
    """
    
    return CallTool.Result(content: [.text(preview)], isError: false)
}

// New tool handler to retrieve command output
func handleGetCommandOutput(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    var commandId = "last" // Default to last command
    
    if let arguments = params.arguments,
       let id = arguments["command_id"],
       case .string(let idString) = id {
        commandId = idString
    }
    
    logger.info("Retrieving output for command ID: \(commandId)")
    
    // First try to get from memory
    var result = await commandResultsStore.retrieve(commandId)

    // If not in memory, fall back to disk. For the documented "last" alias,
    // resolve to the most recently modified output file (the in-memory store
    // may not hold it if the result was never explicitly stored).
    if result == nil {
        var outputFile: String? = nil
        if commandId == "last" {
            let tempDir = "/tmp"
            outputFile = (try? FileManager.default.contentsOfDirectory(atPath: tempDir))?
                .filter { $0.hasPrefix("claude_output_") && $0.hasSuffix(".json") }
                .compactMap { name -> (path: String, mtime: Date)? in
                    let path = "\(tempDir)/\(name)"
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { return nil }
                    return (path, mtime)
                }
                .max(by: { $0.mtime < $1.mtime })?
                .path
        } else {
            let candidate = "/tmp/claude_output_\(commandId).json"
            if FileManager.default.fileExists(atPath: candidate) { outputFile = candidate }
        }

        if let outputFile = outputFile {
            logger.info("Reading command output from disk: \(outputFile)")
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: outputFile))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                result = try decoder.decode(CommandExecutionResult.self, from: data)
                if let result = result {
                    await commandResultsStore.store(result)
                }
            } catch {
                logger.error("Failed to read/decode output file: \(error)")
            }
        }
    }
    
    if let result = result {
        // Shim confirmation (Tier E): if the optional shell shim observed this
        // command finishing, its exit code came straight from the shell and is
        // authoritative (the /tmp wrapper can mis-record or fail to write).
        let shimEvent = await shellShimEventBus.finishedEvent(forCommandId: result.commandId)
        let authoritativeExit: Int32 = shimEvent?.exitCode.map { Int32($0) } ?? result.exitCode

        // Persist the completed result to the history DB (exit code + duration).
        // No-op if the id isn't a tracked command (e.g. a "last"-resolved file).
        _ = DatabaseManager.shared.updateCommand(
            result.commandId,
            stdout: result.output,
            stderr: result.error,
            exitCode: Int(authoritativeExit),
            completedAt: result.timestamp
        )
        var output = """
        📊 Command Output Retrieved:
        ========================
        Command: \(result.command)
        Exit Code: \(authoritativeExit)
        Timestamp: \(result.timestamp)

        Output:
        \(result.output)
        """

        if !result.error.isEmpty && result.error != "\n" {
            output += "\n\nError Output:\n\(result.error)"
        }

        if let shimExit = shimEvent?.exitCode {
            if Int32(shimExit) == result.exitCode {
                output += "\n\n🔌 Completion confirmed by shell shim (exit \(shimExit))."
            } else {
                output += "\n\n🔌 Shell shim reports exit \(shimExit) (capture file recorded \(result.exitCode)); using the shim value as authoritative."
            }
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    } else {
        // No /tmp capture file. If the shim saw this exact command finish, we can
        // still confirm completion + the authoritative exit code even though the
        // output itself wasn't captured.
        if commandId != "last",
           let shimEvent = await shellShimEventBus.finishedEvent(forCommandId: commandId),
           let shimExit = shimEvent.exitCode {
            _ = DatabaseManager.shared.updateCommand(
                commandId, stdout: nil, stderr: nil, exitCode: shimExit, completedAt: Date()
            )
            return CallTool.Result(content: [.text("""
            🔌 Command finished (exit \(shimExit)) — confirmed by the shell shim.
            The output-capture file for ID \(commandId) isn't available, so stdout/stderr couldn't be returned, but the command did complete.
            """)], isError: false)
        }

        // List available output files for debugging
        let tempDir = "/tmp"
        let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir)
            .filter { $0.starts(with: "claude_output_") && $0.hasSuffix(".json") }
            .sorted()
            .suffix(5)

        var message = "No output found for command ID: \(commandId). The command may still be running or hasn't been executed yet."
        if let files = files, !files.isEmpty {
            message += "\n\nRecent output files available:\n" + files.joined(separator: "\n")
        }
        
        return CallTool.Result(content: [.text(message)], isError: false)
    }
}

// createOutputCaptureScript and createAppleScript are now in TerminalUtilities.swift

// Function to wait for and retrieve command output
func waitForCommandOutput(commandId: String, timeout: TimeInterval = 30, logger: Logger) async throws -> CommandExecutionResult? {
    let outputFile = "/tmp/claude_output_\(commandId).json"
    let markerFile = "\(outputFile).complete"
    
    let startTime = Date()
    
    // Poll for completion
    while Date().timeIntervalSince(startTime) < timeout {
        if FileManager.default.fileExists(atPath: markerFile) {
            // Small delay to ensure file is fully written
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // Read the output file
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: outputFile))
                
                // Configure decoder with proper date format
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                let result = try decoder.decode(CommandExecutionResult.self, from: data)
                
                logger.info("Successfully decoded command output for \(commandId)")
                
                // Clean up files
                try? FileManager.default.removeItem(atPath: outputFile)
                try? FileManager.default.removeItem(atPath: markerFile)
                
                return result
            } catch {
                logger.error("Failed to decode command output: \(error)")
                // Try to read the raw content for debugging
                if let rawContent = try? String(contentsOf: URL(fileURLWithPath: outputFile)) {
                    logger.error("Raw JSON content: \(rawContent)")
                }
                // Don't remove files on error so we can debug
                return nil
            }
        }
        
        // Wait a bit before checking again
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    logger.info("Timeout reached waiting for command output")
    return nil
}
