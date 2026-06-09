import Foundation
import MCP
import Logging

// MARK: - v4.1.0 Tools: Health Check, History, and Cleanup

// MARK: - List Recent Commands Tool

/// Handle list_recent_commands tool - exposes command history from SQLite
func handleListRecentCommands(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    // Parse parameters
    var limit = 10
    var statusFilter: String? = nil
    var searchQuery: String? = nil
    
    if let arguments = params.arguments {
        if let limitValue = arguments["limit"],
           case .string(let limitStr) = limitValue,
           let parsedLimit = Int(limitStr) {
            limit = min(max(parsedLimit, 1), 50) // Clamp between 1-50
        }
        
        if let statusValue = arguments["status"],
           case .string(let status) = statusValue,
           ["all", "success", "failed"].contains(status) {
            statusFilter = status == "all" ? nil : status
        }
        
        if let searchValue = arguments["search"],
           case .string(let search) = searchValue,
           !search.isEmpty {
            searchQuery = search
        }
    }
    
    logger.info("Listing recent commands: limit=\(limit), status=\(statusFilter ?? "all"), search=\(searchQuery ?? "none")")
    
    // Fetch commands from database
    var commands: [CommandRecord]
    
    if let query = searchQuery {
        commands = DatabaseManager.shared.searchCommands(query: query, limit: limit)
    } else {
        commands = DatabaseManager.shared.getRecentCommands(limit: limit)
    }
    
    // Apply status filter if specified
    if let filter = statusFilter {
        commands = commands.filter { cmd in
            if filter == "success" {
                return cmd.exitCode == 0
            } else {
                return cmd.exitCode != nil && cmd.exitCode != 0
            }
        }
    }
    
    if commands.isEmpty {
        return CallTool.Result(
            content: [.text("📜 No commands found matching your criteria.")],
            isError: false
        )
    }
    
    // Format output
    var output = "📜 RECENT COMMANDS"
    if let query = searchQuery {
        output += " (search: \"\(query)\")"
    }
    if let filter = statusFilter {
        output += " [\(filter) only]"
    }
    output += "\n\n"
    
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
    
    var successCount = 0
    var failedCount = 0
    
    for (index, cmd) in commands.enumerated() {
        let statusIcon: String
        let exitCodeStr: String
        
        if let exitCode = cmd.exitCode {
            if exitCode == 0 {
                statusIcon = "✅"
                successCount += 1
            } else {
                statusIcon = "❌"
                failedCount += 1
            }
            exitCodeStr = String(exitCode)
        } else {
            statusIcon = "⏳"
            exitCodeStr = "-"
        }
        
        let durationStr: String
        if let durationMs = cmd.durationMs {
            if durationMs < 1000 {
                durationStr = "\(durationMs)ms"
            } else {
                durationStr = String(format: "%.1fs", Double(durationMs) / 1000.0)
            }
        } else {
            durationStr = "-"
        }
        
        let dateStr = dateFormatter.string(from: cmd.startedAt)
        
        // Truncate long commands
        var commandText = cmd.command
        if commandText.count > 60 {
            commandText = String(commandText.prefix(57)) + "..."
        }
        
        output += "#\(index + 1)  \(statusIcon) \(exitCodeStr.padding(toLength: 3, withPad: " ", startingAt: 0)) \(durationStr.padding(toLength: 8, withPad: " ", startingAt: 0)) \(dateStr)\n"
        output += "    \(commandText)\n"
        
        if let directory = cmd.directory {
            let shortDir = directory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            output += "    📁 \(shortDir)\n"
        }
        
        output += "\n"
    }
    
    // Summary
    output += "───────────────────────────────────────\n"
    output += "Summary: \(successCount) successful, \(failedCount) failed"
    if commands.count < limit {
        output += " (showing all \(commands.count))"
    }
    
    return CallTool.Result(content: [.text(output)], isError: false)
}


// MARK: - Self Check / Health Check Tool

/// Handle self_check tool - comprehensive health verification
func handleSelfCheck(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    logger.info("Running health check...")
    
    var checks: [(name: String, status: String, detail: String)] = []
    var warnings = 0
    var errors = 0
    
    // 1. Configuration Check
    let configManager = ConfigurationManager(logger: logger)
    let configErrors = configManager.validate()
    if configErrors.isEmpty {
        checks.append(("Configuration", "✅", "Valid (loaded from \(ConfigurationManager.configDirectoryPath))"))
    } else {
        checks.append(("Configuration", "⚠️", "\(configErrors.count) issue(s): \(configErrors.first ?? "unknown")"))
        warnings += 1
    }
    
    // 2. Database Check
    let dbCheck = checkDatabaseHealth()
    checks.append(("Database", dbCheck.status, dbCheck.detail))
    if dbCheck.status == "⚠️" { warnings += 1 }
    if dbCheck.status == "❌" { errors += 1 }
    
    // 3. Terminal Check
    let terminalCheck = await checkTerminalAvailability()
    checks.append(("Terminal", terminalCheck.status, terminalCheck.detail))
    if terminalCheck.status == "⚠️" { warnings += 1 }
    if terminalCheck.status == "❌" { errors += 1 }
    
    // 4. Temp Directory Check
    let tempCheck = checkTempDirectory()
    checks.append(("Temp Directory", tempCheck.status, tempCheck.detail))
    if tempCheck.status == "⚠️" { warnings += 1 }
    if tempCheck.status == "❌" { errors += 1 }
    
    // 5. Error Rate Check (last 10 commands)
    let errorRateCheck = checkRecentErrorRate()
    checks.append(("Error Rate", errorRateCheck.status, errorRateCheck.detail))
    if errorRateCheck.status == "⚠️" { warnings += 1 }
    if errorRateCheck.status == "❌" { errors += 1 }
    
    // Format output
    var output = """
    🏥 HEALTH CHECK
    
    """
    
    for check in checks {
        output += "\(check.status) \(check.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(check.detail)\n"
    }
    
    // Overall status
    let overallStatus: String
    if errors > 0 {
        overallStatus = "UNHEALTHY (\(errors) error(s))"
    } else if warnings > 0 {
        overallStatus = "HEALTHY (\(warnings) warning(s))"
    } else {
        overallStatus = "HEALTHY"
    }
    
    output += "\n───────────────────────────────────────\n"
    output += "Overall: \(overallStatus)"
    
    return CallTool.Result(content: [.text(output)], isError: errors > 0)
}

/// Check database health and statistics
private func checkDatabaseHealth() -> (status: String, detail: String) {
    _ = DatabaseManager.shared.getRecentCommands(limit: 1)

    // Get database file info
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let dbPath = homeDir.appendingPathComponent(".claude-command-runner/claude_commands.db").path
    
    guard FileManager.default.fileExists(atPath: dbPath) else {
        return ("❌", "Database file not found")
    }
    
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        let fileSize = attrs[.size] as? Int64 ?? 0
        let sizeStr: String
        if fileSize < 1024 {
            sizeStr = "\(fileSize) B"
        } else if fileSize < 1024 * 1024 {
            sizeStr = String(format: "%.1f KB", Double(fileSize) / 1024.0)
        } else {
            sizeStr = String(format: "%.1f MB", Double(fileSize) / (1024.0 * 1024.0))
        }
        
        // Get total command count via COUNT(*) — the old approach materialised
        // up to 9,999 full records (including stdout/stderr blobs) just to count.
        let totalCount = DatabaseManager.shared.commandCount()
        
        return ("✅", "OK (\(totalCount) commands, \(sizeStr))")
    } catch {
        return ("⚠️", "Cannot read database attributes: \(error.localizedDescription)")
    }
}

/// Check if preferred terminal is available
private func checkTerminalAvailability() async -> (status: String, detail: String) {
    let preferredTerminal = TerminalConfig.getPreferredTerminal()
    
    // Match the running process by app path rather than process name. Warp's
    // executable is named "stable" (not "Warp"), so a name match always fails;
    // pgrep -f matches the full command line, which contains "<Name>.app".
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "\(preferredTerminal.rawValue).app"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return ("✅", "\(preferredTerminal.rawValue) detected and running")
        } else {
            return ("⚠️", "\(preferredTerminal.rawValue) not running (commands may fail)")
        }
    } catch {
        return ("⚠️", "Cannot detect terminal status")
    }
}

/// Check temp directory writability and cleanup status
private func checkTempDirectory() -> (status: String, detail: String) {
    let tempDir = "/tmp"
    
    // Check writability
    let testFile = "\(tempDir)/claude_health_check_\(UUID().uuidString)"
    do {
        try "test".write(toFile: testFile, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: testFile)
    } catch {
        return ("❌", "Cannot write to /tmp: \(error.localizedDescription)")
    }
    
    // Count orphaned claude files
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        let claudeFiles = files.filter { $0.hasPrefix("claude_") }
        
        if claudeFiles.count > 50 {
            return ("⚠️", "Writable (\(claudeFiles.count) orphaned files - run cleanup)")
        } else if claudeFiles.count > 0 {
            return ("✅", "Writable (\(claudeFiles.count) temp files)")
        } else {
            return ("✅", "Writable (clean)")
        }
    } catch {
        return ("⚠️", "Writable but cannot list contents")
    }
}

/// Check recent command error rate
private func checkRecentErrorRate() -> (status: String, detail: String) {
    let recentCommands = DatabaseManager.shared.getRecentCommands(limit: 10)
    
    guard !recentCommands.isEmpty else {
        return ("✅", "No recent commands")
    }
    
    let completedCommands = recentCommands.filter { $0.exitCode != nil }
    guard !completedCommands.isEmpty else {
        return ("✅", "No completed commands to analyze")
    }
    
    let failures = completedCommands.filter { $0.exitCode != 0 }.count
    let errorRate = Double(failures) / Double(completedCommands.count) * 100
    
    if errorRate >= 50 {
        return ("⚠️", String(format: "%.0f%% failures in last %d commands", errorRate, completedCommands.count))
    } else if errorRate >= 30 {
        return ("⚠️", String(format: "%.0f%% failures in last %d commands", errorRate, completedCommands.count))
    } else {
        return ("✅", String(format: "%.0f%% success rate (last %d commands)", 100 - errorRate, completedCommands.count))
    }
}


// MARK: - Temp File Cleanup

/// Cleanup orphaned temp files (called on startup)
func performTempCleanup(logger: Logger) {
    let tempDir = "/tmp"
    let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours
    let now = Date()
    
    let patterns = [
        "claude_output_",
        "claude_stream_",
        "claude_script_"
    ]
    
    var cleanedCount = 0
    var cleanedBytes: Int64 = 0
    
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        
        for file in files {
            // Check if file matches our patterns
            guard patterns.contains(where: { file.hasPrefix($0) }) else { continue }
            
            let filePath = "\(tempDir)/\(file)"
            
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
                guard let modDate = attrs[.modificationDate] as? Date else { continue }
                
                // Check if older than maxAge
                if now.timeIntervalSince(modDate) > maxAge {
                    let fileSize = attrs[.size] as? Int64 ?? 0
                    try FileManager.default.removeItem(atPath: filePath)
                    cleanedCount += 1
                    cleanedBytes += fileSize
                    logger.debug("Cleaned up: \(file)")
                }
            } catch {
                logger.warning("Failed to cleanup \(file): \(error.localizedDescription)")
            }
        }
        
        if cleanedCount > 0 {
            let sizeStr: String
            if cleanedBytes < 1024 {
                sizeStr = "\(cleanedBytes) B"
            } else if cleanedBytes < 1024 * 1024 {
                sizeStr = String(format: "%.1f KB", Double(cleanedBytes) / 1024.0)
            } else {
                sizeStr = String(format: "%.1f MB", Double(cleanedBytes) / (1024.0 * 1024.0))
            }
            logger.info("Temp cleanup: removed \(cleanedCount) files (\(sizeStr))")
        } else {
            logger.debug("Temp cleanup: no old files to remove")
        }
    } catch {
        logger.warning("Temp cleanup failed: \(error.localizedDescription)")
    }
}
