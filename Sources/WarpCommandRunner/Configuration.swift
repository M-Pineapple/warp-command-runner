import Foundation
import Logging

/// Configuration structure for Warp Command Runner
public struct Configuration: Codable {
    public struct Terminal: Codable {
        public var preferred: String = "auto"
        public var fallbackOrder: [String] = ["Warp", "WarpPreview", "iTerm", "Terminal"]
        public var customPaths: [String: String] = [:]
    }
    
    public struct Security: Codable {
        public var allowedCommands: [String] = []
        public var blockedCommands: [String] = [
            "rm -rf /",
            ":(){ :|:& };:",
            "dd if=/dev/random of=/dev/sda",
            "mkfs.ext4 /dev/sda",
            "chmod -R 777 /",
            "chown -R"
        ]
        public var blockedPatterns: [String] = [
            ".*>/dev/sda.*",
            ".*format.*disk.*",
            ".*delete.*system.*"
        ]
        public var requireConfirmation: [String] = [
            "sudo",
            "rm -rf",
            "git push --force",
            "npm publish",
            "pod trunk push"
        ]
        public var maxCommandLength: Int = 1000
    }
    
    public struct Output: Codable {
        public var captureTimeout: Int = 60
        public var maxOutputSize: Int = 1048576 // 1MB
        public var timestampFormat: String = "yyyy-MM-dd HH:mm:ss"
        public var colorOutput: Bool = true
    }
    
    public struct History: Codable {
        public var enabled: Bool = true
        public var maxEntries: Int = 10000
        public var retentionDays: Int = 90
        public var databasePath: String?
    }
    
    public struct Logging: Codable {
        public var level: String = "info"
        public var filePath: String?
        public var maxFileSize: Int = 10485760 // 10MB
        public var rotateCount: Int = 5
    }

    public struct Notifications: Codable {
        public var enabled: Bool = true
        public var soundEnabled: Bool = true
        public var showOnSuccess: Bool = false
        public var showOnFailure: Bool = true
        public var minimumDuration: TimeInterval = 10
    }

    public struct Workspace: Codable {
        public var autoDetectProfiles: Bool = true
        public var profilesPath: String?
    }

    public struct FileWatching: Codable {
        public var maxWatchers: Int = 5
        public var defaultDebounce: TimeInterval = 2.0
        public var autoExpireMinutes: Int = 60
    }

    public struct SSHConfig: Codable {
        public var defaultTimeout: Int = 30
        public var profilesPath: String?
        public var allowPasswordAuth: Bool = false
    }

    public struct InteractiveDetection: Codable {
        public var enabled: Bool = true
        public var customPatterns: [String] = []
    }

    /// Opt-in Streamable HTTP for phone / cloud MCP hosts.
    /// Binds loopback only. The user supplies their own public HTTPS URL
    /// (Cloudflare tunnel, Tailscale Funnel, or a reverse proxy they control).
    public struct Remote: Codable {
        /// Loopback bind. Never listen on 0.0.0.0.
        public var listenPort: Int = 8741
        /// Public origin the user created, e.g. `https://mcp.example.com`.
        /// Used as the OAuth issuer and in metadata. No trailing slash.
        public var publicBaseURL: String?
        /// Warp-routing tools (keystroke / front-tab) stay off unless the user
        /// turns this on. Remote callers should use `execute_pipeline`.
        public var allowKeystrokeTools: Bool = false
        /// Reserved. Parsed from config but not yet enforced (no Mac prompt).
        public var requireMacApproval: Bool = false
    }

    public var terminal: Terminal = Terminal()
    public var security: Security = Security()
    public var output: Output = Output()
    public var history: History = History()
    public var logging: Logging = Logging()
    public var notifications: Notifications = Notifications()
    public var workspace: Workspace = Workspace()
    public var fileWatching: FileWatching = FileWatching()
    public var ssh: SSHConfig = SSHConfig()
    public var interactiveDetection: InteractiveDetection = InteractiveDetection()
    public var remote: Remote = Remote()
    public var port: Int = 9876
    public var autoUpdate: Bool = true

    /// Default configuration
    public static var `default`: Configuration {
        return Configuration()
    }

    public init() {}

    /// Custom decoder added in v6.0.1 to tolerate older on-disk config.json
    /// files that predate one or more top-level schema fields. The
    /// auto-synthesized Codable init uses `decode` (not `decodeIfPresent`)
    /// for every property and fails hard on the first missing key — even
    /// when the property has a Swift-level default value. This decoder
    /// uses `decodeIfPresent ?? <default>` for each top-level field, so
    /// missing keys silently fall back to the in-code defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.terminal = try c.decodeIfPresent(Terminal.self, forKey: .terminal) ?? Terminal()
        self.security = try c.decodeIfPresent(Security.self, forKey: .security) ?? Security()
        self.output = try c.decodeIfPresent(Output.self, forKey: .output) ?? Output()
        self.history = try c.decodeIfPresent(History.self, forKey: .history) ?? History()
        self.logging = try c.decodeIfPresent(Logging.self, forKey: .logging) ?? Logging()
        self.notifications = try c.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        self.workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace) ?? Workspace()
        self.fileWatching = try c.decodeIfPresent(FileWatching.self, forKey: .fileWatching) ?? FileWatching()
        self.ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh) ?? SSHConfig()
        self.interactiveDetection = try c.decodeIfPresent(InteractiveDetection.self, forKey: .interactiveDetection) ?? InteractiveDetection()
        self.remote = try c.decodeIfPresent(Remote.self, forKey: .remote) ?? Remote()
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9876
        self.autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case terminal, security, output, history, logging
        case notifications, workspace, fileWatching, ssh
        case interactiveDetection, remote, port, autoUpdate
    }
}

/// Configuration manager for loading and saving config
public class ConfigurationManager {
    private static var configDirectory: URL { AppPaths.configDirectory }
    private static var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    
    private var configuration: Configuration
    private let logger: Logger?
    
    public init(logger: Logger? = nil) {
        self.logger = logger
        self.configuration = ConfigurationManager.load(logger: logger)
    }
    
    /// Get current configuration
    public var current: Configuration {
        return configuration
    }
    
    /// Load configuration from disk
    public static func load(logger: Logger? = nil) -> Configuration {
        // Ensure config directory exists
        try? FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        // Check if config file exists
        if FileManager.default.fileExists(atPath: configFile.path) {
            do {
                let data = try Data(contentsOf: configFile)
                let decoder = JSONDecoder()
                let config = try decoder.decode(Configuration.self, from: data)
                logger?.info("Configuration loaded from \(configFile.path)")
                return config
            } catch {
                logger?.error("Failed to load configuration: \(error)")
                logger?.info("Using default configuration")
            }
        } else {
            logger?.info("No configuration file found, using defaults")
            // Create default config file
            let defaultConfig = Configuration.default
            try? save(configuration: defaultConfig, logger: logger)
        }
        
        return Configuration.default
    }
    
    /// Save configuration to disk
    public static func save(configuration: Configuration, logger: Logger? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        
        try data.write(to: configFile)
        logger?.info("Configuration saved to \(configFile.path)")
    }
    
    /// Update configuration
    public func update(_ block: (inout Configuration) -> Void) throws {
        block(&configuration)
        try ConfigurationManager.save(configuration: configuration, logger: logger)
    }
    
    /// Get configuration directory path
    public static var configDirectoryPath: String {
        return configDirectory.path
    }
    
    /// Initialize configuration with example file
    public static func initializeWithExample(logger: Logger? = nil) throws {
        let exampleConfig = Configuration.default
        
        // Add some example customizations
        var config = exampleConfig
        config.terminal.preferred = "Warp"
        config.security.blockedCommands.append("custom-dangerous-command")
        config.output.timestampFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        
        try save(configuration: config, logger: logger)
        
        // Also create an example file
        let exampleFile = configDirectory.appendingPathComponent("config.example.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: exampleFile)
        
        logger?.info("Created example configuration at \(exampleFile.path)")
    }
    
    /// Validate configuration
    public func validate() -> [String] {
        var errors: [String] = []
        
        // Validate terminal
        if configuration.terminal.fallbackOrder.isEmpty {
            errors.append("Terminal fallback order cannot be empty")
        }
        
        // Validate security
        if configuration.security.maxCommandLength < 10 {
            errors.append("Maximum command length must be at least 10 characters")
        }
        
        // Validate output
        if configuration.output.captureTimeout < 1 {
            errors.append("Capture timeout must be at least 1 second")
        }
        
        if configuration.output.maxOutputSize < 1024 {
            errors.append("Maximum output size must be at least 1KB")
        }
        
        // Validate history
        if configuration.history.retentionDays < 0 {
            errors.append("Retention days cannot be negative")
        }
        
        // Validate port
        if configuration.port < 1024 || configuration.port > 65535 {
            errors.append("Port must be between 1024 and 65535")
        }

        if configuration.remote.listenPort < 1024 || configuration.remote.listenPort > 65535 {
            errors.append("remote.listenPort must be between 1024 and 65535")
        }
        if let base = configuration.remote.publicBaseURL, !base.isEmpty {
            if let url = URL(string: base), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty {
                if scheme != "https" {
                    errors.append("remote.publicBaseURL must be https (the URL Grok / ChatGPT / Claude will call)")
                }
            } else {
                errors.append("remote.publicBaseURL is not a valid URL")
            }
        }

        // Validate file watching
        if configuration.fileWatching.maxWatchers < 1 || configuration.fileWatching.maxWatchers > 50 {
            errors.append("Max file watchers must be between 1 and 50")
        }
        if configuration.fileWatching.defaultDebounce < 0.1 {
            errors.append("File watcher debounce must be at least 0.1 seconds")
        }
        if configuration.fileWatching.autoExpireMinutes < 1 {
            errors.append("File watcher auto-expire must be at least 1 minute")
        }

        // Validate SSH
        if configuration.ssh.defaultTimeout < 5 || configuration.ssh.defaultTimeout > 300 {
            errors.append("SSH timeout must be between 5 and 300 seconds")
        }

        // Validate notifications
        if configuration.notifications.minimumDuration < 0 {
            errors.append("Notification minimum duration cannot be negative")
        }

        return errors
    }
}

/// Extension for accessing configuration in command handlers
extension Configuration {
    /// Check if a command is blocked
    public func isCommandBlocked(_ command: String) -> Bool {
        // Check exact matches
        for blocked in security.blockedCommands {
            if command.contains(blocked) {
                return true
            }
        }
        
        // Check patterns
        for pattern in security.blockedPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: command.utf16.count)
                if regex.firstMatch(in: command, options: [], range: range) != nil {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if a command requires confirmation
    public func requiresConfirmation(_ command: String) -> Bool {
        for pattern in security.requireConfirmation {
            if command.contains(pattern) {
                return true
            }
        }
        return false
    }
    
    /// Get preferred terminal type
    public func getPreferredTerminal() -> TerminalConfig.TerminalType? {
        if terminal.preferred == "auto" {
            return nil // Use auto-detection
        }
        
        return TerminalConfig.TerminalType.allCases.first { 
            $0.rawValue.lowercased() == terminal.preferred.lowercased() 
        }
    }
}
