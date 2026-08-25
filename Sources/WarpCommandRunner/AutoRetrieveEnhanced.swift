import Foundation
import MCP
import Logging

// Enhanced auto-retrieve with progressive delays for all command types
func handleExecuteWithAutoRetrieveEnhanced(params: CallTool.Parameters, logger: Logger, config: Configuration) async throws -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        throw MCPError.invalidParams("Missing or invalid 'command' parameter")
    }
    
    // First, execute the command using the stable version
    let executeResult = try await handleExecuteCommandV2NoMonitoring(params: params, logger: logger, config: config)
    
    // Extract command ID from the result text
    var resultText = ""
    if case .text(let text) = executeResult.content.first {
        resultText = text
    }
    let commandId = extractCommandId(from: resultText)
    
    if let commandId = commandId {
        logger.info("Enhanced auto-retrieve: Starting progressive monitoring for command \(commandId)")
        
        // Smart detection of command type
        let commandType = detectCommandType(commandString)
        let delays = getDelaysForCommandType(commandType)
        
        logger.info("Detected command type: \(commandType), will wait up to \(delays.reduce(0, +)) seconds")
        
        // Progressive delay monitoring
        var totalWaitTime = 0
        for (attempt, delay) in delays.enumerated() {
            // Wait for the current delay
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            totalWaitTime += delay
            
            // Try to get output
            let outputParams = CallTool.Parameters(
                name: "get_command_output",
                arguments: ["command_id": .string(commandId)]
            )
            
            let outputResult = await handleGetCommandOutput(params: outputParams, logger: logger)
            
            // Check if we got actual output
            if case .text(let outputText) = outputResult.content.first,
               !outputText.contains("No output found for command ID") {
                
                // Success! Return combined result
                let combinedResult = """
                \(resultText)
                
                ⏱️ Output retrieved automatically after \(totalWaitTime) seconds:
                
                \(outputText)
                """
                
                logger.info("Auto-retrieve successful after \(attempt + 1) attempts (\(totalWaitTime)s total)")
                return CallTool.Result(content: [.text(combinedResult)], isError: false)
            }
            
            // Progress feedback for long-running commands
            if commandType == .build && attempt < delays.count - 1 {
                logger.info("Build still running... waited \(totalWaitTime)s so far")
            }
        }
        
        // Timeout reached - provide helpful message based on command type
        let timeoutMessage = getTimeoutMessage(for: commandType, totalWaitTime: totalWaitTime, commandId: commandId)
        return CallTool.Result(content: [.text("\(resultText)\n\n\(timeoutMessage)")], isError: false)
    }
    
    // No command ID found, just return the original result
    return executeResult
}

// Command type detection for intelligent delay selection
enum CommandType {
    case quick      // Simple commands like echo, ls, pwd
    case moderate   // Git operations, file operations
    case build      // Compilation, builds
    case test       // Test suites
    case unknown    // Default for unrecognized commands
}

func detectCommandType(_ command: String) -> CommandType {
    let lowercased = command.lowercased()
    
    // Build commands
    if lowercased.contains("build") || 
       lowercased.contains("compile") ||
       lowercased.contains("swift build") ||
       lowercased.contains("xcodebuild") ||
       lowercased.contains("make") ||
       lowercased.contains("cargo build") ||
       lowercased.contains("npm build") {
        return .build
    }
    
    // Test commands
    if lowercased.contains("test") ||
       lowercased.contains("swift test") ||
       lowercased.contains("pytest") ||
       lowercased.contains("jest") {
        return .test
    }
    
    // Quick commands
    if lowercased.starts(with: "echo") ||
       lowercased.starts(with: "pwd") ||
       lowercased.starts(with: "date") ||
       lowercased.starts(with: "whoami") ||
       lowercased.starts(with: "ls") && !lowercased.contains("|") {
        return .quick
    }
    
    // Moderate commands
    if lowercased.starts(with: "git") ||
       lowercased.contains("npm install") ||
       lowercased.contains("pod install") ||
       lowercased.contains("brew") {
        return .moderate
    }
    
    return .unknown
}

// Get progressive delays based on command type
func getDelaysForCommandType(_ type: CommandType) -> [Int] {
    switch type {
    case .quick:
        // Total: 6 seconds (2, 2, 2)
        return [2, 2, 2]
        
    case .moderate:
        // Total: 20 seconds (2, 3, 5, 10)
        return [2, 3, 5, 10]
        
    case .build:
        // Total: 77 seconds (2, 5, 10, 20, 40)
        return [2, 5, 10, 20, 40]
        
    case .test:
        // Total: 40 seconds (2, 3, 5, 10, 20)
        return [2, 3, 5, 10, 20]
        
    case .unknown:
        // Total: 30 seconds (2, 3, 5, 10, 10)
        return [2, 3, 5, 10, 10]
    }
}

// Get appropriate timeout message
func getTimeoutMessage(for type: CommandType, totalWaitTime: Int, commandId: String) -> String {
    switch type {
    case .quick:
        return """
        ℹ️ Command didn't complete within \(totalWaitTime) seconds.
        This seems unusually long for a simple command.
        Use 'get_command_output' with ID: \(commandId) to check the result.
        """
        
    case .build:
        return """
        🔨 Build still in progress after \(totalWaitTime) seconds.
        Large projects can take several minutes to build.
        Use 'get_command_output' with ID: \(commandId) when ready.
        """
        
    case .test:
        return """
        🧪 Tests still running after \(totalWaitTime) seconds.
        Use 'get_command_output' with ID: \(commandId) when complete.
        """
        
    case .moderate, .unknown:
        return """
        ⏱️ Auto-retrieve timeout after \(totalWaitTime) seconds.
        The command may still be running.
        Use 'get_command_output' with ID: \(commandId) to retrieve manually.
        """
    }
}

// Helper to extract command ID from execute_command's display output.
// Internal (not private) so tests can pin this contract: the regex couples
// auto-retrieve to the exact wording "Command ID: <uuid>" — if that wording
// changes, auto-retrieve silently breaks.
func extractCommandId(from text: String) -> String? {
    let pattern = "Command ID: ([A-F0-9\\-]+)"
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
    }
    return nil
}
