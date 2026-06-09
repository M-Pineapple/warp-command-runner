import Foundation
import MCP
import Logging

// MARK: - File System Watcher

/// Watches file system paths for changes and triggers commands automatically.
/// Uses macOS DispatchSource.makeFileSystemObjectSource for efficient native monitoring.
///
/// Feature #6 — bridges Claude from reactive assistant to proactive development partner.
/// Example: "Run tests whenever a .swift file changes"
actor FileWatcher {

    // MARK: - Types

    /// What kind of change to watch for
    struct WatchRule: Codable, Identifiable {
        let id: String
        let path: String                    // Directory or file to watch
        let fileExtensions: [String]?       // Optional filter (e.g. ["swift", "ts"])
        let command: String                 // Command to execute on change
        let workingDirectory: String?       // Where to run the command
        let debounceSeconds: Double         // Prevent rapid re-triggers (default 2.0)
        let label: String?                  // Human-friendly name
        let createdAt: Date
        var isActive: Bool

        init(
            path: String,
            fileExtensions: [String]? = nil,
            command: String,
            workingDirectory: String? = nil,
            debounceSeconds: Double = 2.0,
            label: String? = nil
        ) {
            self.id = UUID().uuidString
            self.path = path
            self.fileExtensions = fileExtensions
            self.command = command
            self.workingDirectory = workingDirectory
            self.debounceSeconds = debounceSeconds
            self.label = label
            self.createdAt = Date()
            self.isActive = true
        }
    }

    /// Active watch session with its dispatch source
    private struct ActiveWatch {
        let rule: WatchRule
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        var lastTriggered: Date?
    }

    // MARK: - State

    static let shared = FileWatcher()

    private var activeWatches: [String: ActiveWatch] = [:]
    private var rules: [String: WatchRule] = [:]
    private let logger = Logger(label: "FileWatcher")
    private let watchQueue = DispatchQueue(label: "com.claude-command-runner.filewatcher", qos: .utility)

    private init() {}

    // MARK: - Public API

    /// Add a new watch rule and start monitoring
    func addWatch(_ rule: WatchRule) throws -> WatchRule {
        // Validate path exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rule.path, isDirectory: &isDir) else {
            throw FileWatcherError.pathNotFound(rule.path)
        }

        rules[rule.id] = rule

        // Only start the source if watching a directory (file-level watching
        // uses a slightly different approach — monitor the parent)
        let watchPath = isDir.boolValue ? rule.path : (rule.path as NSString).deletingLastPathComponent
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else {
            throw FileWatcherError.cannotOpenPath(rule.path)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: watchQueue
        )

        let ruleId = rule.id
        let ruleCommand = rule.command
        let ruleWorkDir = rule.workingDirectory
        let ruleDebounce = rule.debounceSeconds
        let ruleExtensions = rule.fileExtensions

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task {
                await self.handleFileChange(
                    ruleId: ruleId,
                    command: ruleCommand,
                    workingDirectory: ruleWorkDir,
                    debounceSeconds: ruleDebounce,
                    extensions: ruleExtensions,
                    watchPath: watchPath
                )
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()

        activeWatches[rule.id] = ActiveWatch(
            rule: rule,
            source: source,
            fileDescriptor: fd,
            lastTriggered: nil
        )

        logger.info("FileWatcher: Started watching '\(watchPath)' → '\(ruleCommand)' (ID: \(rule.id))")
        return rule
    }

    /// Remove a watch by ID
    func removeWatch(id: String) -> Bool {
        guard let watch = activeWatches[id] else { return false }
        // A suspended DispatchSource must be resumed before cancel/release —
        // cancelling while suspended is a libdispatch client error (crash on
        // release) and the cancel handler that closes the fd never runs.
        if !watch.rule.isActive {
            watch.source.resume()
        }
        watch.source.cancel()
        activeWatches.removeValue(forKey: id)
        rules.removeValue(forKey: id)
        logger.info("FileWatcher: Stopped watch ID: \(id)")
        return true
    }

    /// Pause a watch without removing it
    func pauseWatch(id: String) -> Bool {
        guard let watch = activeWatches[id] else { return false }
        // Suspending twice would unbalance the suspend count.
        guard watch.rule.isActive else { return true }
        watch.source.suspend()
        var rule = watch.rule
        rule.isActive = false
        rules[id] = rule
        activeWatches[id] = ActiveWatch(rule: rule, source: watch.source, fileDescriptor: watch.fileDescriptor, lastTriggered: watch.lastTriggered)
        return true
    }

    /// Resume a paused watch
    func resumeWatch(id: String) -> Bool {
        guard let watch = activeWatches[id] else { return false }
        // Resuming an already-active source crashes (unbalanced resume).
        guard !watch.rule.isActive else { return true }
        watch.source.resume()
        var rule = watch.rule
        rule.isActive = true
        rules[id] = rule
        activeWatches[id] = ActiveWatch(rule: rule, source: watch.source, fileDescriptor: watch.fileDescriptor, lastTriggered: watch.lastTriggered)
        return true
    }

    /// List all watches (active and paused)
    func listWatches() -> [WatchRule] {
        return Array(rules.values).sorted { $0.createdAt < $1.createdAt }
    }

    /// Remove all watches
    func removeAll() {
        for (_, watch) in activeWatches {
            if !watch.rule.isActive {
                watch.source.resume()
            }
            watch.source.cancel()
        }
        activeWatches.removeAll()
        rules.removeAll()
        logger.info("FileWatcher: All watches removed")
    }

    // MARK: - Internal

    /// Maximum wall-clock time for a watch command. Previously the command ran
    /// with no timeout while blocking the actor, so one hung command froze all
    /// file-watch tools.
    private static let watchCommandTimeout: TimeInterval = 300

    private func handleFileChange(
        ruleId: String,
        command: String,
        workingDirectory: String?,
        debounceSeconds: Double,
        extensions: [String]?,
        watchPath: String
    ) async {
        // Debounce — skip if triggered too recently
        if let lastTriggered = activeWatches[ruleId]?.lastTriggered {
            let elapsed = Date().timeIntervalSince(lastTriggered)
            if elapsed < debounceSeconds {
                return
            }
        }

        // Extension filter: scan directory for recently modified files matching extensions
        if let extensions = extensions, !extensions.isEmpty {
            let recentCutoff = Date().addingTimeInterval(-debounceSeconds - 1)
            let matchingRecent = findRecentlyModifiedFiles(
                in: watchPath,
                extensions: extensions,
                since: recentCutoff
            )
            if matchingRecent.isEmpty {
                return // Change was in a file we don't care about
            }
            logger.info("FileWatcher: Changed files matching filter: \(matchingRecent.map { $0.lastPathComponent })")
        }

        // Update last triggered timestamp
        if let watch = activeWatches[ruleId] {
            activeWatches[ruleId] = ActiveWatch(
                rule: watch.rule,
                source: watch.source,
                fileDescriptor: watch.fileDescriptor,
                lastTriggered: Date()
            )
        }

        logger.info("FileWatcher: Change detected in '\(watchPath)' — executing: \(command)")

        // Execute the command via the shared runner: pipes drained concurrently,
        // bounded by a timeout, and the actor is only suspended (not blocked)
        // while the command runs, so other watch tools stay responsive.
        do {
            let result = try await runProcess(
                executablePath: "/bin/bash",
                arguments: ["-c", command],
                currentDirectory: workingDirectory,
                timeout: Self.watchCommandTimeout
            )

            let output = result.stdout
            let error = result.stderr
            let exitCode = result.exitCode

            if result.timedOut {
                logger.warning("FileWatcher: Command timed out after \(Int(Self.watchCommandTimeout))s and was terminated")
            }

            if exitCode == 0 {
                logger.info("FileWatcher: Command succeeded (exit 0)")
                if !output.isEmpty {
                    logger.info("FileWatcher output: \(output.prefix(500))")
                }
            } else {
                logger.warning("FileWatcher: Command failed (exit \(exitCode))")
                if !error.isEmpty {
                    logger.warning("FileWatcher error: \(error.prefix(500))")
                }
            }

            // Send macOS notification for completed watch commands
            sendMacOSNotification(
                title: exitCode == 0 ? "✅ Watch triggered" : "❌ Watch failed",
                message: "\(command)\nExit code: \(exitCode)",
                logger: logger
            )

        } catch {
            logger.error("FileWatcher: Failed to execute command: \(error)")
        }
    }

    /// Find files recently modified in a directory matching given extensions
    private func findRecentlyModifiedFiles(in directory: String, extensions: [String], since: Date) -> [URL] {
        let dirURL = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [URL] = []
        let extSet = Set(extensions.map { $0.lowercased() })

        for case let fileURL as URL in enumerator {
            guard extSet.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if modDate > since {
                matches.append(fileURL)
            }
        }

        return matches
    }
}

// MARK: - Errors

enum FileWatcherError: Swift.Error, LocalizedError {
    case pathNotFound(String)
    case cannotOpenPath(String)
    case watchNotFound(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path): return "Path not found: \(path)"
        case .cannotOpenPath(let path): return "Cannot open path for watching: \(path)"
        case .watchNotFound(let id): return "Watch not found with ID: \(id)"
        }
    }
}

// MARK: - MCP Tool Handlers

/// Derive bare file extensions from a glob pattern.
/// "*.swift" -> ["swift"]; "*.{ts,tsx}" -> ["ts","tsx"]; "*"/"" -> nil (match all files).
private func extensionsFromGlob(_ glob: String) -> [String]? {
    var p = glob.trimmingCharacters(in: .whitespaces)
    guard !p.isEmpty, p != "*", p != "*.*" else { return nil }
    if let dotIdx = p.lastIndex(of: ".") {
        p = String(p[p.index(after: dotIdx)...])
    }
    p = p.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    let parts = p.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: "*", with: "")
          .lowercased()
    }
    let cleaned = parts.filter { !$0.isEmpty }
    return cleaned.isEmpty ? nil : cleaned
}

/// Add a file watcher rule
func handleAddFileWatch(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let pathValue = arguments["path"],
          case .string(let path) = pathValue,
          let commandValue = arguments["command"],
          case .string(let command) = commandValue else {
        return CallTool.Result(
            content: [.text("❌ Missing required parameters: 'path' and 'command'")],
            isError: true
        )
    }

    // Optional parameters.
    // The tool schema exposes `pattern` (a glob like "*.swift"); derive the bare
    // extensions the matcher expects from it. Also accept a `file_extensions`
    // array for back-compat.
    var extensions: [String]? = nil
    if let patternValue = arguments["pattern"],
       case .string(let glob) = patternValue, !glob.isEmpty {
        extensions = extensionsFromGlob(glob)
    }
    if extensions == nil,
       let extValue = arguments["file_extensions"],
       case .array(let extArray) = extValue {
        extensions = extArray.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    var debounce: Double = 2.0
    if let debounceValue = arguments["debounce_seconds"],
       case .string(let debounceStr) = debounceValue,
       let d = Double(debounceStr) {
        debounce = d
    }

    var workDir: String? = nil
    if let dirValue = arguments["working_directory"],
       case .string(let dir) = dirValue {
        workDir = dir
    }

    var label: String? = nil
    if let labelValue = arguments["label"],
       case .string(let l) = labelValue {
        label = l
    }

    let rule = FileWatcher.WatchRule(
        path: path,
        fileExtensions: extensions,
        command: command,
        workingDirectory: workDir,
        debounceSeconds: debounce,
        label: label
    )

    do {
        let created = try await FileWatcher.shared.addWatch(rule)
        let extDisplay = extensions?.joined(separator: ", ") ?? "all files"

        return CallTool.Result(
            content: [.text("""
            👁️ File watcher created!

            ID: \(created.id)
            Path: \(path)
            Extensions: \(extDisplay)
            Command: \(command)
            Debounce: \(debounce)s
            \(label.map { "Label: \($0)" } ?? "")

            The command will run automatically when matching files change.
            Use 'remove_file_watch' to stop, or 'list_file_watches' to see all.
            """)],
            isError: false
        )
    } catch {
        return CallTool.Result(
            content: [.text("❌ Failed to create file watcher: \(error.localizedDescription)")],
            isError: true
        )
    }
}

/// Remove a file watcher
func handleRemoveFileWatch(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let idValue = arguments["watcher_id"],
          case .string(let watchId) = idValue else {
        return CallTool.Result(
            content: [.text("❌ Missing required parameter: 'watcher_id'")],
            isError: true
        )
    }

    let removed = await FileWatcher.shared.removeWatch(id: watchId)

    if removed {
        return CallTool.Result(
            content: [.text("✅ File watcher removed: \(watchId)")],
            isError: false
        )
    } else {
        return CallTool.Result(
            content: [.text("❌ No file watcher found with ID: \(watchId)")],
            isError: true
        )
    }
}

/// List all file watchers
func handleListFileWatches(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    let watches = await FileWatcher.shared.listWatches()

    if watches.isEmpty {
        return CallTool.Result(
            content: [.text("📋 No active file watchers.\n\nUse 'add_file_watch' to create one.")],
            isError: false
        )
    }

    var output = "👁️ FILE WATCHERS (\(watches.count))\n"
    output += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

    for watch in watches {
        let statusIcon = watch.isActive ? "🟢" : "⏸️"
        let name = watch.label ?? watch.id.prefix(8).description
        let extDisplay = watch.fileExtensions?.joined(separator: ", ") ?? "all"

        output += """
        \(statusIcon) \(name)
        ├─ ID: \(watch.id)
        ├─ Path: \(watch.path)
        ├─ Extensions: \(extDisplay)
        ├─ Command: \(watch.command)
        ├─ Debounce: \(watch.debounceSeconds)s
        └─ Created: \(watch.createdAt.ISO8601Format())

        """
    }

    return CallTool.Result(content: [.text(output)], isError: false)
}
