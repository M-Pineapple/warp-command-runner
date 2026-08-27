import Foundation
import Logging

/// Product identity for Warp Command Runner.
///
/// Previously shipped as "Claude Command Runner" (`claude-command-runner`).
/// v7.0 rebrands the same MCP server: the protocol is host-agnostic (any
/// MCP client can spawn us over stdio); Warp is the terminal we drive.
/// Legacy paths are still read so existing v6 installs keep working.
enum AppIdentity {
    static let displayName = "Warp Command Runner"
    static let commandName = "warp-command-runner"
    static let bundleIdentifier = "com.m-pineapple.warp-command-runner"
    static let version = "8.0.0"
    static let loggerLabel = "com.warp-command-runner"

    static let configDirectoryName = ".warp-command-runner"
    static let legacyConfigDirectoryName = ".claude-command-runner"
    static let databaseFileName = "warp_commands.db"
    static let legacyDatabaseFileName = "claude_commands.db"

    static let outputPrefix = "wcr_output_"
    static let streamPrefix = "wcr_stream_"
    static let streamScriptPrefix = "wcr_stream_script_"
    static let scriptPrefix = "wcr_script_"
    static let stderrPrefix = "wcr_stderr_"
    static let healthPrefix = "wcr_health_check_"

    static let legacyOutputPrefix = "claude_output_"
    static let legacyStreamPrefix = "claude_stream_"
    static let legacyScriptPrefix = "claude_script_"

    static let tempFilePrefixes: [String] = [
        outputPrefix, streamPrefix, streamScriptPrefix, scriptPrefix,
        stderrPrefix, healthPrefix,
        legacyOutputPrefix, legacyStreamPrefix, legacyScriptPrefix,
        "claude_stream_script_", "claude_stderr_", "claude_health_check_",
    ]
}

enum AppPaths {
    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppIdentity.configDirectoryName)
    }

    static var legacyConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppIdentity.legacyConfigDirectoryName)
    }

    static var databaseURL: URL {
        configDirectory.appendingPathComponent(AppIdentity.databaseFileName)
    }

    /// Copy `~/.claude-command-runner` → `~/.warp-command-runner` once.
    /// Does not delete the old directory. Safe to call on every launch.
    static func migrateLegacyConfigIfNeeded(logger: Logger? = nil) {
        let fm = FileManager.default
        let current = configDirectory
        let legacy = legacyConfigDirectory

        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.copyItem(at: legacy, to: current)
                logger?.info("Migrated config from \(legacy.path) to \(current.path)")
            } catch {
                logger?.error("Failed to migrate legacy config directory: \(error)")
            }
        }

        try? fm.createDirectory(at: current, withIntermediateDirectories: true)

        let oldDb = current.appendingPathComponent(AppIdentity.legacyDatabaseFileName)
        let newDb = databaseURL
        if fm.fileExists(atPath: oldDb.path), !fm.fileExists(atPath: newDb.path) {
            do {
                try fm.moveItem(at: oldDb, to: newDb)
                logger?.info("Renamed database to \(newDb.path)")
            } catch {
                logger?.error("Failed to rename legacy database: \(error)")
            }
        }
    }
}

enum TempFiles {
    static func outputPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.outputPrefix)\(commandId).json"
    }

    static func scriptPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.scriptPrefix)\(commandId).sh"
    }

    static func streamLogPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamPrefix)\(commandId).log"
    }

    static func streamExitPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamPrefix)\(commandId).exit"
    }

    static func streamScriptPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamScriptPrefix)\(commandId).sh"
    }

    static func stderrPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.stderrPrefix)\(commandId).tmp"
    }

    /// Prefer the current prefix; fall back to the v6 `claude_*` name so
    /// in-flight commands survive an upgrade.
    static func existingOutputPath(commandId: String) -> String? {
        let candidates = [
            "/tmp/\(AppIdentity.outputPrefix)\(commandId).json",
            "/tmp/\(AppIdentity.legacyOutputPrefix)\(commandId).json",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func shellShimSocketPath(uid: uid_t = getuid()) -> String {
        "/tmp/wcr-shell-shim-\(uid).sock"
    }

    static func scriptNeedle(commandId: String) -> [String] {
        ["\(AppIdentity.scriptPrefix)\(commandId)", "\(AppIdentity.legacyScriptPrefix)\(commandId)"]
    }
}
