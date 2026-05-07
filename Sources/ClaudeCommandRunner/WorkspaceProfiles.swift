import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Session Persistence & Workspace Profiles

struct WorkspaceProfile: Codable {
    let name: String
    var directory: String
    var defaultCommands: [String]
    var environmentVars: [String: String]
    var terminalPreference: String
    var createdAt: Date
    var lastUsed: Date
}

/// Actor for thread-safe workspace profile management
actor WorkspaceProfileManager {
    private var profiles: [String: WorkspaceProfile] = [:]
    private let profilesPath: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-command-runner")
        let path = dir.appendingPathComponent("profiles.json")
        profilesPath = path

        // Inline load to avoid actor-isolation warning from calling async method in init
        if FileManager.default.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([String: WorkspaceProfile].self, from: data) {
                profiles = loaded
            }
        }
    }

    // MARK: - CRUD

    func save(profile: WorkspaceProfile) {
        var p = profile
        p.lastUsed = Date()
        profiles[p.name] = p
        persistToDisk()
    }

    func load(name: String) -> WorkspaceProfile? {
        guard var profile = profiles[name] else { return nil }
        profile.lastUsed = Date()
        profiles[name] = profile
        persistToDisk()
        return profile
    }

    func list() -> [WorkspaceProfile] {
        return profiles.values.sorted { $0.lastUsed > $1.lastUsed }
    }

    func delete(name: String) -> Bool {
        let removed = profiles.removeValue(forKey: name) != nil
        if removed { persistToDisk() }
        return removed
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: profilesPath.path),
              let data = try? Data(contentsOf: profilesPath) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([String: WorkspaceProfile].self, from: data) {
            profiles = loaded
        }
    }

    private func persistToDisk() {
        let dir = profilesPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(profiles) {
            try? data.write(to: profilesPath)
        }
    }
}

/// Global workspace profile manager
let workspaceProfileManager = WorkspaceProfileManager()

// MARK: - Tool Handlers

/// Handle save_workspace_profile tool
func handleSaveWorkspaceProfile(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing required 'name' parameter")],
            isError: true
        )
    }

    var directory = "~"
    if let dir = arguments["directory"], case .string(let d) = dir {
        directory = d
    }

    var defaultCommands: [String] = []
    if let cmds = arguments["default_commands"], case .array(let arr) = cmds {
        defaultCommands = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    var environmentVars: [String: String] = [:]
    if let envs = arguments["environment_vars"], case .object(let obj) = envs {
        for (key, val) in obj {
            if case .string(let v) = val {
                environmentVars[key] = v
            }
        }
    }

    var terminalPreference = "Warp"
    if let term = arguments["terminal"], case .string(let t) = term {
        terminalPreference = t
    }

    let profile = WorkspaceProfile(
        name: name,
        directory: directory,
        defaultCommands: defaultCommands,
        environmentVars: environmentVars,
        terminalPreference: terminalPreference,
        createdAt: Date(),
        lastUsed: Date()
    )

    await workspaceProfileManager.save(profile: profile)

    logger.info("Workspace profile saved: \(name)")

    // v6.0 Tier C: optionally also write a Warp-native launch config so it
    // appears in Warp's launch UI. Off by default; opt in per call.
    var includeWarpConfig = false
    if let flag = arguments["include_warp_launch_config"] {
        if case .bool(let b) = flag { includeWarpConfig = b }
        else if case .string(let s) = flag { includeWarpConfig = (s == "true" || s == "1") }
    }

    var warpConfigLine: String? = nil
    if includeWarpConfig {
        do {
            let url = try WarpLaunchConfig.write(profile: profile, logger: logger)
            warpConfigLine = "• Warp launch config: \(url.path)"
        } catch {
            warpConfigLine = "• Warp launch config: ⚠️ failed to write — \(error.localizedDescription)"
        }
    }

    var output = """
    ✅ Workspace profile saved: "\(name)"
    • Directory: \(directory)
    • Commands: \(defaultCommands.isEmpty ? "none" : defaultCommands.joined(separator: ", "))
    • Env vars: \(environmentVars.isEmpty ? "none" : "\(environmentVars.count) variable(s)")
    • Terminal: \(terminalPreference)
    """
    if let line = warpConfigLine {
        output += "\n\(line)"
    }

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

/// Handle load_workspace_profile tool
func handleLoadWorkspaceProfile(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing required 'name' parameter")],
            isError: true
        )
    }

    guard let profile = await workspaceProfileManager.load(name: name) else {
        return CallTool.Result(
            content: [.text("❌ Profile '\(name)' not found. Use 'list_workspace_profiles' to see available profiles.")],
            isError: true
        )
    }

    let formatter = ISO8601DateFormatter()

    var output = """
    📂 Workspace Profile: "\(profile.name)"
    • Directory: \(profile.directory)
    • Terminal: \(profile.terminalPreference)
    • Created: \(formatter.string(from: profile.createdAt))
    • Last used: \(formatter.string(from: profile.lastUsed))
    """

    if !profile.defaultCommands.isEmpty {
        output += "\n\n🔧 Default Commands:"
        for cmd in profile.defaultCommands {
            output += "\n  • \(cmd)"
        }
    }

    if !profile.environmentVars.isEmpty {
        output += "\n\n🌍 Environment Variables:"
        for (key, val) in profile.environmentVars.sorted(by: { $0.key < $1.key }) {
            output += "\n  \(key)=\(val)"
        }
    }

    logger.info("Workspace profile loaded: \(name)")

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

/// Handle list_workspace_profiles tool
func handleListWorkspaceProfiles(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    let profiles = await workspaceProfileManager.list()

    if profiles.isEmpty {
        return CallTool.Result(
            content: [.text("📂 No workspace profiles saved yet.\n\n💡 Use 'save_workspace_profile' to create one.")],
            isError: false
        )
    }

    let formatter = ISO8601DateFormatter()
    var output = "📂 Workspace Profiles (\(profiles.count)):\n"

    for profile in profiles {
        output += "\n  \(profile.name)"
        output += "\n    Directory: \(profile.directory)"
        output += "\n    Terminal: \(profile.terminalPreference)"
        output += "\n    Commands: \(profile.defaultCommands.count) | Env vars: \(profile.environmentVars.count)"
        output += "\n    Last used: \(formatter.string(from: profile.lastUsed))"
    }

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

/// Handle delete_workspace_profile tool
func handleDeleteWorkspaceProfile(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing required 'name' parameter")],
            isError: true
        )
    }

    let removed = await workspaceProfileManager.delete(name: name)

    if removed {
        logger.info("Workspace profile deleted: \(name)")
        // Tier C: best-effort cleanup of any companion Warp launch config.
        // Silent if absent. Reported in the response for transparency.
        let warpRemoved = WarpLaunchConfig.remove(profileName: name, logger: logger)
        let warpLine = warpRemoved
            ? "\n• Removed Warp launch config: \(WarpLaunchConfig.fileURL(forProfile: name).path)"
            : ""
        return CallTool.Result(
            content: [.text("✅ Workspace profile '\(name)' deleted.\(warpLine)")],
            isError: false
        )
    } else {
        return CallTool.Result(
            content: [.text("❌ Profile '\(name)' not found.")],
            isError: true
        )
    }
}
