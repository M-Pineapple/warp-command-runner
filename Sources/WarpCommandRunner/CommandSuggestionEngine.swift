import Foundation
import MCP
import Logging

/// Smart command suggestion system based on context and history
class CommandSuggestionEngine {
    private let database = DatabaseManager.shared
    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Generate command suggestions based on user query
    func suggestCommand(query: String, context: CommandContext? = nil) -> [CommandSuggestion] {
        var suggestions: [CommandSuggestion] = []
        
        // 1. Check for exact template matches
        if let templateSuggestions = getTemplateSuggestions(for: query) {
            suggestions.append(contentsOf: templateSuggestions)
        }
        
        // 2. Search command history for similar commands
        let historySuggestions = database.searchCommands(query: query, limit: 10)
            .map { record in
                CommandSuggestion(
                    command: record.command,
                    description: "Previously used command",
                    confidence: 0.8,
                    source: .history,
                    metadata: [
                        "last_used": record.startedAt.ISO8601Format(),
                        "success_rate": record.exitCode == 0 ? "100%" : "0%"
                    ]
                )
            }
        suggestions.append(contentsOf: historySuggestions)
        
        // 3. Generate contextual suggestions
        if let context = context {
            suggestions.append(contentsOf: generateContextualSuggestions(query: query, context: context))
        }
        
        // 4. Apply smart transformations and patterns
        suggestions.append(contentsOf: generateSmartSuggestions(query: query))
        
        // Sort by confidence and deduplicate
        let uniqueSuggestions = Array(Set(suggestions)).sorted { $0.confidence > $1.confidence }
        
        return Array(uniqueSuggestions.prefix(10))
    }
    
    private func getTemplateSuggestions(for query: String) -> [CommandSuggestion]? {
        // Search templates by name or command content
        let templates = database.getTemplates()
            .filter { template in
                template.name.lowercased().contains(query.lowercased()) ||
                template.command.lowercased().contains(query.lowercased()) ||
                (template.description?.lowercased().contains(query.lowercased()) ?? false)
            }
        
        return templates.map { template in
            CommandSuggestion(
                command: template.command,
                description: template.description ?? "Template: \(template.name)",
                confidence: 0.9,
                source: .template,
                metadata: [
                    "template_id": template.id,
                    "category": template.category ?? "general",
                    "usage_count": String(template.usageCount)
                ]
            )
        }
    }
    
    private func generateContextualSuggestions(query: String, context: CommandContext) -> [CommandSuggestion] {
        var suggestions: [CommandSuggestion] = []
        
        // Git-related suggestions
        if FileManager.default.fileExists(atPath: "\(context.workingDirectory)/.git") {
            suggestions.append(contentsOf: generateGitSuggestions(query: query))
        }
        
        // Swift/Xcode project suggestions
        let swiftFiles = try? FileManager.default.contentsOfDirectory(atPath: context.workingDirectory)
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        
        if let swiftFiles = swiftFiles, !swiftFiles.isEmpty {
            suggestions.append(contentsOf: generateSwiftSuggestions(query: query, files: swiftFiles))
        }
        
        // Package.json/Node.js suggestions
        if FileManager.default.fileExists(atPath: "\(context.workingDirectory)/package.json") {
            suggestions.append(contentsOf: generateNodeSuggestions(query: query))
        }
        
        return suggestions
    }
    
    private func generateGitSuggestions(query: String) -> [CommandSuggestion] {
        let gitCommands: [(String, String, String)] = [
            ("status", "git status", "Check the current status of your repository"),
            ("commit", "git add . && git commit -m \"\"", "Stage all changes and commit"),
            ("push", "git push origin main", "Push changes to remote repository"),
            ("pull", "git pull origin main", "Pull latest changes from remote"),
            ("branch", "git checkout -b feature/", "Create and switch to new feature branch"),
            ("log", "git log --oneline -10", "View recent commit history"),
            ("diff", "git diff", "Show unstaged changes"),
            ("stash", "git stash", "Temporarily save current changes")
        ]
        
        return gitCommands
            .filter { $0.0.contains(query.lowercased()) || query.lowercased().contains("git") }
            .map { CommandSuggestion(
                command: $0.1,
                description: $0.2,
                confidence: 0.85,
                source: .contextual,
                metadata: ["context": "git"]
            )}
    }
    
    private func generateSwiftSuggestions(query: String, files: [String]) -> [CommandSuggestion] {
        let hasPackageSwift = files.contains("Package.swift")
        let hasXcodeProject = files.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        
        var suggestions: [CommandSuggestion] = []
        
        if hasPackageSwift {
            let spmCommands: [(String, String, String)] = [
                ("build", "swift build", "Build the Swift package"),
                ("test", "swift test", "Run tests"),
                ("run", "swift run", "Build and run the executable"),
                ("clean", "swift package clean", "Clean build artifacts"),
                ("update", "swift package update", "Update dependencies"),
                ("release", "swift build -c release", "Build in release mode")
            ]
            
            suggestions.append(contentsOf: spmCommands
                .filter { $0.0.contains(query.lowercased()) || query.lowercased().contains("swift") }
                .map { CommandSuggestion(
                    command: $0.1,
                    description: $0.2,
                    confidence: 0.9,
                    source: .contextual,
                    metadata: ["context": "swift-package-manager"]
                )}
            )
        }
        
        if hasXcodeProject {
            suggestions.append(CommandSuggestion(
                command: "xcodebuild -list",
                description: "List available schemes and targets",
                confidence: 0.85,
                source: .contextual,
                metadata: ["context": "xcode"]
            ))
        }
        
        return suggestions
    }
    
    private func generateNodeSuggestions(query: String) -> [CommandSuggestion] {
        let nodeCommands: [(String, String, String)] = [
            ("install", "npm install", "Install dependencies"),
            ("start", "npm start", "Start the application"),
            ("test", "npm test", "Run tests"),
            ("build", "npm run build", "Build the project"),
            ("dev", "npm run dev", "Start development server"),
            ("lint", "npm run lint", "Run linter")
        ]
        
        return nodeCommands
            .filter { $0.0.contains(query.lowercased()) || query.lowercased().contains("npm") }
            .map { CommandSuggestion(
                command: $0.1,
                description: $0.2,
                confidence: 0.85,
                source: .contextual,
                metadata: ["context": "node.js"]
            )}
    }
    
    private func generateSmartSuggestions(query: String) -> [CommandSuggestion] {
        var suggestions: [CommandSuggestion] = []
        
        // Common command patterns
        let patterns: [(String, (String) -> String?, String)] = [
            ("find.*file", { q in
                if let match = q.range(of: "file[s]?\\s+(.+)", options: .regularExpression) {
                    let raw = String(q[match])
                        .replacingOccurrences(of: "files ", with: "")
                        .replacingOccurrences(of: "file ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    // Only emit a glob for a clean single token. A natural-language
                    // query ("...files modified in the last day") would otherwise
                    // produce a nonsense pattern full of spaces, so skip it and let
                    // the contextual/history suggestions stand on their own.
                    guard !raw.isEmpty, !raw.contains(" ") else { return nil }
                    return "find . -name \"*\(raw)*\" -type f"
                }
                return nil
            }, "Find files matching pattern"),
            
            ("search.*text", { q in
                if let match = q.range(of: "text\\s+['\"]?(.+)['\"]?", options: .regularExpression) {
                    let text = String(q[match])
                        .replacingOccurrences(of: "text ", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    return "grep -r \"\(text)\" ."
                }
                return nil
            }, "Search for text in files"),
            
            ("list.*process", { _ in "ps aux | grep" }, "List running processes"),
            ("kill.*process", { _ in "kill -9" }, "Kill a process by PID"),
            ("disk.*space", { _ in "df -h" }, "Check disk space"),
            ("memory|ram", { _ in "top -l 1 | grep PhysMem" }, "Check memory usage")
        ]
        
        for (pattern, generator, description) in patterns {
            if query.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                if let command = generator(query) {
                    suggestions.append(CommandSuggestion(
                        command: command,
                        description: description,
                        confidence: 0.7,
                        source: .pattern,
                        metadata: ["pattern": pattern]
                    ))
                }
            }
        }
        
        return suggestions
    }
}

// MARK: - Supporting Types

struct CommandContext {
    let workingDirectory: String
    let recentCommands: [String]
    let environment: [String: String]
}

struct CommandSuggestion: Hashable {
    let command: String
    let description: String
    let confidence: Double
    let source: SuggestionSource
    let metadata: [String: String]
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(command)
    }
    
    static func == (lhs: CommandSuggestion, rhs: CommandSuggestion) -> Bool {
        lhs.command == rhs.command
    }
}

enum SuggestionSource {
    case history
    case template
    case contextual
    case pattern
}

// MARK: - MCP Tool Handler

func handleSuggestCommand(params: CallTool.Parameters, logger: Logger) async throws -> CallTool.Result {
    guard let arguments = params.arguments,
          let query = arguments["query"],
          case .string(let queryString) = query else {
        throw MCPError.invalidParams("Missing or invalid 'query' parameter")
    }
    
    let engine = CommandSuggestionEngine(logger: logger)

    // Use the caller-provided working directory so the context-aware
    // (git / Swift / Node) suggestions actually fire. The MCP server's own CWD
    // is `/`, which would otherwise suppress every contextual suggestion.
    let workingDirectory: String
    if let dirValue = arguments["working_directory"],
       case .string(let dir) = dirValue, !dir.isEmpty {
        workingDirectory = (dir as NSString).expandingTildeInPath
    } else {
        workingDirectory = FileManager.default.currentDirectoryPath
    }

    let context = CommandContext(
        workingDirectory: workingDirectory,
        recentCommands: DatabaseManager.shared.getRecentCommands(limit: 5).map { $0.command },
        environment: ProcessInfo.processInfo.environment
    )
    
    let suggestions = engine.suggestCommand(query: queryString, context: context)
    
    if suggestions.isEmpty {
        return CallTool.Result(
            content: [.text("No command suggestions found for: \(queryString)")],
            isError: false
        )
    }
    
    var response = "🎯 Command Suggestions for: \(queryString)\n\n"
    
    for (index, suggestion) in suggestions.enumerated() {
        // Skip empty commands
        guard !suggestion.command.isEmpty else { continue }
        
        response += "\(index + 1). `\(suggestion.command)`\n"
        response += "   \(suggestion.description)\n"
        response += "   Confidence: \(Int(suggestion.confidence * 100))%"
        
        if suggestion.source == .history {
            response += " (from history)"
        } else if suggestion.source == .template {
            response += " (from template)"
        }
        
        response += "\n\n"
    }
    
    response += "\n💡 Use 'execute_command' to run any of these suggestions."
    
    return CallTool.Result(content: [.text(response)], isError: false)
}