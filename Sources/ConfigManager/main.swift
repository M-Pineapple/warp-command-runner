#!/usr/bin/env swift

import Foundation

// Simple CLI for managing Warp Command Runner configuration

func resolvedConfigDirectory() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let current = home.appendingPathComponent(".warp-command-runner")
    let legacy = home.appendingPathComponent(".claude-command-runner")
    if FileManager.default.fileExists(atPath: current.path) { return current }
    if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
    return current
}

let configDirectory = resolvedConfigDirectory()
let configFile = configDirectory.appendingPathComponent("config.json")

enum Command: String, CaseIterable {
    case show
    case edit
    case reset
    case validate
    case help
    
    var description: String {
        switch self {
        case .show: return "Show current configuration"
        case .edit: return "Edit configuration in default editor"
        case .reset: return "Reset to default configuration"
        case .validate: return "Validate configuration"
        case .help: return "Show this help message"
        }
    }
}

func showHelp() {
    print("""
    Warp Command Runner Configuration Manager
    
    Usage: config-manager <command>
    
    Commands:
    """)
    
    for command in Command.allCases {
        print("  \(command.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(command.description)")
    }
}

func showConfig() {
    guard FileManager.default.fileExists(atPath: configFile.path) else {
        print("No configuration file found at: \(configFile.path)")
        print("Run 'warp-command-runner --init-config' to create one.")
        return
    }
    
    do {
        let data = try Data(contentsOf: configFile)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        let prettyData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        
        if let jsonString = String(data: prettyData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        print("Error reading configuration: \(error)")
    }
}

func editConfig() {
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nano"
    
    if !FileManager.default.fileExists(atPath: configFile.path) {
        print("No configuration file found. Creating default configuration...")
        createDefaultConfig()
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [editor, configFile.path]
    
    do {
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            print("Configuration saved.")
        } else {
            print("Editor exited with status: \(process.terminationStatus)")
        }
    } catch {
        print("Failed to open editor: \(error)")
    }
}

func resetConfig() {
    print("This will reset your configuration to defaults. Continue? [y/N]: ", terminator: "")
    
    guard let input = readLine()?.lowercased(), input == "y" else {
        print("Reset cancelled.")
        return
    }
    
    createDefaultConfig()
    print("Configuration reset to defaults.")
}

func createDefaultConfig() {
    try? FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: true,
        attributes: nil
    )
    
    let defaultConfig = """
    {
      "autoUpdate": true,
      "history": {
        "databasePath": null,
        "enabled": true,
        "maxEntries": 10000,
        "retentionDays": 90
      },
      "logging": {
        "filePath": null,
        "level": "info",
        "maxFileSize": 10485760,
        "rotateCount": 5
      },
      "output": {
        "captureTimeout": 60,
        "colorOutput": true,
        "maxOutputSize": 1048576,
        "timestampFormat": "yyyy-MM-dd HH:mm:ss"
      },
      "port": 9876,
      "security": {
        "allowedCommands": [],
        "blockedCommands": [
          "rm -rf /",
          ":(){ :|:& };:",
          "dd if=/dev/random of=/dev/sda",
          "mkfs.ext4 /dev/sda",
          "chmod -R 777 /",
          "chown -R"
        ],
        "blockedPatterns": [
          ".*>/dev/sda.*",
          ".*format.*disk.*",
          ".*delete.*system.*"
        ],
        "maxCommandLength": 1000,
        "requireConfirmation": [
          "sudo",
          "rm -rf",
          "git push --force",
          "npm publish",
          "pod trunk push"
        ]
      },
      "terminal": {
        "customPaths": {},
        "fallbackOrder": [
          "Warp",
          "WarpPreview",
          "iTerm",
          "Terminal"
        ],
        "preferred": "auto"
      }
    }
    """
    
    do {
        try defaultConfig.write(to: configFile, atomically: true, encoding: .utf8)
    } catch {
        print("Failed to create default configuration: \(error)")
    }
}

// Main execution
let arguments = CommandLine.arguments.dropFirst()

guard let commandString = arguments.first,
      let command = Command(rawValue: commandString) else {
    if !arguments.isEmpty {
        print("Unknown command: \(arguments.first ?? "")")
    }
    showHelp()
    exit(1)
}

switch command {
case .show:
    showConfig()
case .edit:
    editConfig()
case .reset:
    resetConfig()
case .validate:
    print("Run 'warp-command-runner --validate-config' to validate configuration")
case .help:
    showHelp()
}
