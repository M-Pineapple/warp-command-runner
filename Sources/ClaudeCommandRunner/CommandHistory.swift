#if compiler(>=5.9)
import Foundation
#else
import Foundation
#endif
import Logging

/// Command history entry structure
public struct CommandHistoryEntry: Codable {
    public let id: String
    public let command: String
    public let output: String
    public let error: String
    public let exitCode: Int32
    public let timestamp: Date
    public let workingDirectory: String?
    public let terminal: String?
    public let duration: TimeInterval?
    
    public init(
        id: String,
        command: String,
        output: String,
        error: String,
        exitCode: Int32,
        timestamp: Date,
        workingDirectory: String? = nil,
        terminal: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.command = command
        self.output = output
        self.error = error
        self.exitCode = exitCode
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.duration = duration
    }
}

/// Command history exporter with multiple format support
public class CommandHistoryExporter {
    private let logger: Logger?
    
    public enum ExportFormat {
        case json
        case csv
        case markdown
    }
    
    public init(logger: Logger? = nil) {
        self.logger = logger
    }
    
    /// Export command history to specified format
    public func export(
        entries: [CommandHistoryEntry],
        format: ExportFormat,
        to url: URL
    ) throws {
        logger?.info("Exporting \(entries.count) entries to \(format)")
        
        let data: Data
        switch format {
        case .json:
            data = try exportToJSON(entries: entries)
        case .csv:
            data = try exportToCSV(entries: entries)
        case .markdown:
            data = try exportToMarkdown(entries: entries)
        }
        
        try data.write(to: url)
        logger?.info("Export completed to \(url.path)")
    }
    
    /// Export to JSON format
    private func exportToJSON(entries: [CommandHistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }
    
    /// Export to CSV format
    private func exportToCSV(entries: [CommandHistoryEntry]) throws -> Data {
        var csv = "ID,Command,Exit Code,Timestamp,Working Directory,Terminal,Duration,Has Output,Has Error\n"
        
        let dateFormatter = ISO8601DateFormatter()
        
        for entry in entries {
            let command = entry.command.replacingOccurrences(of: "\"", with: "\"\"")
            let hasOutput = !entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasError = !entry.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let workingDir = entry.workingDirectory ?? "N/A"
            let terminal = entry.terminal ?? "N/A"
            let duration = entry.duration.map { String(format: "%.2f", $0) } ?? "N/A"
            
            csv += "\"\(entry.id)\",\"\(command)\",\(entry.exitCode),\"\(dateFormatter.string(from: entry.timestamp))\",\"\(workingDir)\",\"\(terminal)\",\(duration),\(hasOutput),\(hasError)\n"
        }
        
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        
        return data
    }
    
    /// Export to Markdown format
    private func exportToMarkdown(entries: [CommandHistoryEntry]) throws -> Data {
        var markdown = "# Command History Export\n\n"
        markdown += "Generated on: \(Date())\n\n"
        markdown += "Total commands: \(entries.count)\n\n"
        
        // Summary statistics
        let successCount = entries.filter { $0.exitCode == 0 }.count
        let failureCount = entries.count - successCount
        
        markdown += "## Summary\n\n"
        markdown += "- **Successful commands**: \(successCount)\n"
        markdown += "- **Failed commands**: \(failureCount)\n"
        markdown += "- **Success rate**: \(String(format: "%.1f%%", Double(successCount) / Double(entries.count) * 100))\n\n"
        
        // Command details
        markdown += "## Command Details\n\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        
        for (index, entry) in entries.enumerated() {
            markdown += "### \(index + 1). \(entry.command)\n\n"
            markdown += "- **ID**: `\(entry.id)`\n"
            markdown += "- **Timestamp**: \(dateFormatter.string(from: entry.timestamp))\n"
            markdown += "- **Exit Code**: \(entry.exitCode) \(entry.exitCode == 0 ? "✅" : "❌")\n"
            
            if let workingDir = entry.workingDirectory {
                markdown += "- **Working Directory**: `\(workingDir)`\n"
            }
            
            if let terminal = entry.terminal {
                markdown += "- **Terminal**: \(terminal)\n"
            }
            
            if let duration = entry.duration {
                markdown += "- **Duration**: \(String(format: "%.2f", duration)) seconds\n"
            }
            
            // Output section
            if !entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "\n**Output:**\n```\n\(entry.output)\n```\n"
            }
            
            // Error section
            if !entry.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "\n**Error:**\n```\n\(entry.error)\n```\n"
            }
            
            markdown += "\n---\n\n"
        }
        
        guard let data = markdown.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        
        return data
    }
    
    /// Filter entries based on criteria
    public func filter(
        entries: [CommandHistoryEntry],
        startDate: Date? = nil,
        endDate: Date? = nil,
        exitCode: Int32? = nil,
        pattern: String? = nil
    ) -> [CommandHistoryEntry] {
        var filtered = entries
        
        // Filter by date range
        if let start = startDate {
            filtered = filtered.filter { $0.timestamp >= start }
        }
        
        if let end = endDate {
            filtered = filtered.filter { $0.timestamp <= end }
        }
        
        // Filter by exit code
        if let code = exitCode {
            filtered = filtered.filter { $0.exitCode == code }
        }
        
        // Filter by pattern
        if let pattern = pattern,
           let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            filtered = filtered.filter { entry in
                let range = NSRange(location: 0, length: entry.command.utf16.count)
                return regex.firstMatch(in: entry.command, options: [], range: range) != nil
            }
        }
        
        return filtered
    }
}

/// Export errors
public enum ExportError: Error {
    case encodingFailed
    case invalidFormat
    case writeError(Error)
}

/// Command history manager for loading from various sources
public class CommandHistoryManager {
    private let logger: Logger?

    public init(logger: Logger? = nil) {
        self.logger = logger
    }
    
    /// Load history from Claude Command Runner's execution cache
    public func loadFromCache() -> [CommandHistoryEntry] {
        var entries: [CommandHistoryEntry] = []
        
        // Look for output files in /tmp
        let fileManager = FileManager.default
        let tmpDir = "/tmp"
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: tmpDir)
                .filter { $0.starts(with: "claude_output_") && $0.hasSuffix(".json") }
            
            for file in files {
                let path = "\(tmpDir)/\(file)"
                if let data = fileManager.contents(atPath: path),
                   let result = try? JSONDecoder().decode(CommandExecutionResult.self, from: data) {
                    let entry = CommandHistoryEntry(
                        id: result.commandId,
                        command: result.command,
                        output: result.output,
                        error: result.error,
                        exitCode: result.exitCode,
                        timestamp: result.timestamp
                    )
                    entries.append(entry)
                }
            }
        } catch {
            logger?.error("Failed to load cache: \(error)")
        }
        
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
    
}
