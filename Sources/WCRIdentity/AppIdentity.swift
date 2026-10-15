import Darwin
import Foundation
import Logging

/// Product identity for Warp Command Runner.
///
/// Previously shipped as "Claude Command Runner" (`claude-command-runner`).
/// v7.0 rebrands the same MCP server: the protocol is host-agnostic (any
/// MCP client can spawn us over stdio); Warp is the terminal we drive.
/// Legacy paths are still read so existing v6 installs keep working.
///
/// Shared by the MCP server and ConfigManager so `WCR_HOME` resolves once.
public enum AppIdentity {
    public static let displayName = "Warp Command Runner"
    public static let commandName = "warp-command-runner"
    public static let bundleIdentifier = "com.m-pineapple.warp-command-runner"
    public static let version = "8.0.3"
    public static let loggerLabel = "com.warp-command-runner"

    public static let configDirectoryName = ".warp-command-runner"
    public static let legacyConfigDirectoryName = ".claude-command-runner"
    public static let databaseFileName = "warp_commands.db"
    public static let legacyDatabaseFileName = "claude_commands.db"

    public static let outputPrefix = "wcr_output_"
    public static let streamPrefix = "wcr_stream_"
    public static let streamScriptPrefix = "wcr_stream_script_"
    public static let scriptPrefix = "wcr_script_"
    public static let stderrPrefix = "wcr_stderr_"
    public static let healthPrefix = "wcr_health_check_"

    public static let legacyOutputPrefix = "claude_output_"
    public static let legacyStreamPrefix = "claude_stream_"
    public static let legacyScriptPrefix = "claude_script_"

    public static let tempFilePrefixes: [String] = [
        outputPrefix, streamPrefix, streamScriptPrefix, scriptPrefix,
        stderrPrefix, healthPrefix,
        legacyOutputPrefix, legacyStreamPrefix, legacyScriptPrefix,
        "claude_stream_script_", "claude_stderr_", "claude_health_check_",
    ]
}

public enum AppPaths {
    public static let homeOverrideEnvironmentKey = "WCR_HOME"
    public static let directoryPOSIXPermissions: Int = 0o700

    /// Data folder. `WCR_HOME` overrides `~/.warp-command-runner` so a host
    /// can isolate config (clean-install tests, extra profiles) without
    /// touching the default directory. `homeDirectoryForCurrentUser` ignores
    /// a process `HOME=` on macOS, which is why this dedicated variable exists.
    ///
    /// `WCR_HOME` must be an absolute path or start with `~/`. Relative values
    /// are ignored (same as unset).
    public static var configDirectory: URL {
        configDirectory(environment: ProcessInfo.processInfo.environment)
    }

    public static func configDirectory(
        environment: [String: String],
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = resolvedHomeOverride(environment: environment) {
            return override
        }
        return userHome.appendingPathComponent(AppIdentity.configDirectoryName)
    }

    /// Non-nil when `WCR_HOME` is set to an absolute path or `~/…`.
    public static func resolvedHomeOverride(environment: [String: String]) -> URL? {
        guard let raw = environment[homeOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        if raw == "~" || raw.hasPrefix("~/") || raw.hasPrefix("/") {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return nil
    }

    public static func usesHomeOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolvedHomeOverride(environment: environment) != nil
    }

    public static var legacyConfigDirectory: URL {
        legacyConfigDirectory(userHome: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func legacyConfigDirectory(userHome: URL) -> URL {
        userHome.appendingPathComponent(AppIdentity.legacyConfigDirectoryName)
    }

    public static var databaseURL: URL {
        configDirectory.appendingPathComponent(AppIdentity.databaseFileName)
    }

    /// Create the data folder with owner-only permissions (`0700`).
    public static func ensureConfigDirectory(
        at url: URL? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let target = url ?? configDirectory(environment: environment, userHome: userHome)
        try? fileManager.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPOSIXPermissions]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: directoryPOSIXPermissions],
            ofItemAtPath: target.path
        )
    }

    /// Copy `~/.claude-command-runner` → `~/.warp-command-runner` once.
    /// Does not delete the old directory. Safe to call on every launch.
    /// Skipped when `WCR_HOME` is a valid override so an isolated data dir
    /// is not seeded from the real user folder.
    public static func migrateLegacyConfigIfNeeded(
        logger: Logger? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let fm = fileManager
        let current = configDirectory(environment: environment, userHome: userHome)
        if usesHomeOverride(environment: environment) {
            ensureConfigDirectory(at: current, fileManager: fm)
            return
        }
        let legacy = legacyConfigDirectory(userHome: userHome)

        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.copyItem(at: legacy, to: current)
                logger?.info("Migrated config from \(legacy.path) to \(current.path)")
            } catch {
                logger?.error("Failed to migrate legacy config directory: \(error)")
            }
        }

        ensureConfigDirectory(at: current, fileManager: fm)

        let oldDb = current.appendingPathComponent(AppIdentity.legacyDatabaseFileName)
        let newDb = current.appendingPathComponent(AppIdentity.databaseFileName)
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

public enum TempFiles {
    public static func outputPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.outputPrefix)\(commandId).json"
    }

    public static func scriptPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.scriptPrefix)\(commandId).sh"
    }

    public static func streamLogPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamPrefix)\(commandId).log"
    }

    public static func streamExitPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamPrefix)\(commandId).exit"
    }

    public static func streamScriptPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.streamScriptPrefix)\(commandId).sh"
    }

    public static func stderrPath(commandId: String) -> String {
        "/tmp/\(AppIdentity.stderrPrefix)\(commandId).tmp"
    }

    /// Prefer the current prefix; fall back to the v6 `claude_*` name so
    /// in-flight commands survive an upgrade.
    public static func existingOutputPath(commandId: String) -> String? {
        let candidates = [
            "/tmp/\(AppIdentity.outputPrefix)\(commandId).json",
            "/tmp/\(AppIdentity.legacyOutputPrefix)\(commandId).json",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public static func shellShimSocketPath(uid: uid_t = getuid()) -> String {
        "/tmp/wcr-shell-shim-\(uid).sock"
    }

    public static func scriptNeedle(commandId: String) -> [String] {
        ["\(AppIdentity.scriptPrefix)\(commandId)", "\(AppIdentity.legacyScriptPrefix)\(commandId)"]
    }
}
