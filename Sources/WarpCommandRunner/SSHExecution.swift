import Foundation
import MCP
import Logging

// MARK: - SSH Execution

/// Remote command execution via SSH.
/// Uses the system `ssh` binary — no protocol implementation needed.
/// Key-based authentication only; passwords are never stored.
///
/// Feature #10 — extends the model's reach beyond localhost.
/// Example: "Run `df -h` on my staging server"

// MARK: - SSH Profile

struct SSHProfile: Codable, Identifiable {
    let id: String
    var name: String
    var host: String
    var username: String
    var port: Int
    var identityFile: String?       // path to SSH private key
    var defaultDirectory: String?   // cd here before running commands
    var createdAt: Date
    var lastUsed: Date?

    init(
        name: String,
        host: String,
        username: String,
        port: Int = 22,
        identityFile: String? = nil,
        defaultDirectory: String? = nil
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.host = host
        self.username = username
        self.port = port
        self.identityFile = identityFile
        self.defaultDirectory = defaultDirectory
        self.createdAt = Date()
        self.lastUsed = nil
    }
}

// MARK: - SSH Profile Store

actor SSHProfileStore {
    static let shared = SSHProfileStore()

    private var profiles: [String: SSHProfile] = [:]
    private let profilesURL: URL

    private init() {
        let configDir = AppPaths.configDirectory
        let url = configDir.appendingPathComponent("ssh_profiles.json")
        self.profilesURL = url

        // Inline load to avoid actor-isolation warning from calling async method in init
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let loaded = try decoder.decode([SSHProfile].self, from: data)
                for p in loaded {
                    profiles[p.id] = p
                }
            } catch {
                // Silently start fresh if file is corrupt
            }
        }
    }

    func save(_ profile: SSHProfile) {
        profiles[profile.id] = profile
        persistToDisk()
    }

    func getByName(_ name: String) -> SSHProfile? {
        profiles.values.first { $0.name.lowercased() == name.lowercased() }
    }

    func getById(_ id: String) -> SSHProfile? {
        profiles[id]
    }

    func list() -> [SSHProfile] {
        Array(profiles.values).sorted { $0.createdAt < $1.createdAt }
    }

    func delete(id: String) -> Bool {
        guard profiles.removeValue(forKey: id) != nil else { return false }
        persistToDisk()
        return true
    }

    func markUsed(id: String) {
        guard var profile = profiles[id] else { return }
        profile.lastUsed = Date()
        profiles[id] = profile
        persistToDisk()
    }

    // MARK: Persistence
    // (the old private loadFromDisk() duplicated the inline load in init
    // verbatim and had no callers — removed)

    private func persistToDisk() {
        do {
            let configDir = profilesURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Array(profiles.values))
            try data.write(to: profilesURL)
        } catch {
            // Best-effort persistence, but never silent: a failed write means
            // profile changes are lost on restart.
            Logger(label: "com.warp-command-runner.ssh")
                .error("Failed to persist SSH profiles to \(profilesURL.path): \(error)")
        }
    }
}

// MARK: - SSH Execution Core

/// Execute a command on a remote host via the system SSH binary.
/// Returns stdout, stderr, and exit code.
func executeSSHCommand(
    host: String,
    username: String,
    command: String,
    port: Int = 22,
    identityFile: String? = nil,
    timeout: Int = 30,
    logger: Logger
) async throws -> (output: String, error: String, exitCode: Int32) {

    // Build SSH argument list
    var args: [String] = []

    // Connection timeout
    args += ["-o", "ConnectTimeout=\(timeout)"]

    // Accept new host keys automatically (don't hang on first connection)
    args += ["-o", "StrictHostKeyChecking=accept-new"]

    // Disable password auth — key-based only
    args += ["-o", "BatchMode=yes"]

    // Non-default port
    if port != 22 {
        args += ["-p", "\(port)"]
    }

    // Identity file
    if let keyPath = identityFile {
        let expanded = (keyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw SSHError.identityFileNotFound(keyPath)
        }
        args += ["-i", expanded]
    }

    // Target
    args.append("\(username)@\(host)")

    // Remote command
    args.append(command)

    logger.info("SSH: Executing on \(username)@\(host):\(port) — \(command)")

    // The `timeout` parameter is the connection timeout (ConnectTimeout above).
    // Separately cap total execution: previously a remote command that hung
    // after connecting ran unbounded with no way to cancel the handler.
    let executionTimeout: TimeInterval = 600

    let result = try await runProcess(
        executablePath: "/usr/bin/ssh",
        arguments: args,
        timeout: executionTimeout
    )

    if result.timedOut {
        logger.warning("SSH: Remote command timed out after \(Int(executionTimeout))s and was terminated")
        return (result.stdout,
                result.stderr + "\n[Remote command timed out after \(Int(executionTimeout))s and was terminated]",
                result.exitCode)
    }

    logger.info("SSH: Completed with exit code \(result.exitCode)")

    return (result.stdout, result.stderr, result.exitCode)
}

// MARK: - Errors

enum SSHError: Swift.Error, LocalizedError {
    case identityFileNotFound(String)
    case missingParameters(String)
    case commandBlocked(String)
    case profileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .identityFileNotFound(let path):
            return "SSH identity file not found: \(path)"
        case .missingParameters(let detail):
            return "Missing required SSH parameters: \(detail)"
        case .commandBlocked(let cmd):
            return "Command blocked by security policy: \(cmd)"
        case .profileNotFound(let name):
            return "SSH profile not found: \(name)"
        }
    }
}

// MARK: - MCP Tool Handlers

/// Execute a command on a remote host via SSH
func handleSSHExecute(params: CallTool.Parameters, logger: Logger, config: Configuration) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return CallTool.Result(content: [.text("❌ Missing arguments")], isError: true)
    }

    // Accept either direct host/username or a profile name
    var host: String?
    var username: String?
    var port: Int = 22
    var identityFile: String?
    var timeout: Int = 30

    // Check for profile-based connection
    if let profileValue = arguments["profile"], case .string(let profileName) = profileValue {
        guard let profile = await SSHProfileStore.shared.getByName(profileName) else {
            return CallTool.Result(
                content: [.text("❌ SSH profile not found: \(profileName)\nUse 'list_ssh_profiles' to see available profiles.")],
                isError: true
            )
        }
        host = profile.host
        username = profile.username
        port = profile.port
        identityFile = profile.identityFile
        await SSHProfileStore.shared.markUsed(id: profile.id)
    }

    // Direct parameters override profile values.
    // port/timeout accept JSON numbers as declared in the schema (the old
    // string-only parsing silently ignored numeric values).
    if let v = arguments["host"], case .string(let s) = v { host = s }
    if let v = arguments["username"], case .string(let s) = v { username = s }
    if let p = intArgument(arguments["port"]) { port = p }
    if let v = arguments["identity_file"], case .string(let s) = v { identityFile = s }
    if let t = intArgument(arguments["timeout"]) { timeout = t }

    guard let finalHost = host else {
        return CallTool.Result(content: [.text("❌ Missing required parameter: 'host' (or use 'profile')")], isError: true)
    }
    guard let finalUsername = username else {
        return CallTool.Result(content: [.text("❌ Missing required parameter: 'username' (or use 'profile')")], isError: true)
    }
    guard let commandValue = arguments["command"], case .string(let command) = commandValue else {
        return CallTool.Result(content: [.text("❌ Missing required parameter: 'command'")], isError: true)
    }

    // Security: apply blocked-command checks to remote commands too
    if config.isCommandBlocked(command) {
        return CallTool.Result(
            content: [.text("🛑 Command blocked by security policy: \(command)")],
            isError: true
        )
    }

    // Prepend directory change if profile has a default directory
    var remoteCommand = command
    if let profileValue = arguments["profile"], case .string(let profileName) = profileValue,
       let profile = await SSHProfileStore.shared.getByName(profileName),
       let dir = profile.defaultDirectory {
        remoteCommand = "cd \(dir) && \(command)"
    }

    do {
        let (stdout, stderr, exitCode) = try await executeSSHCommand(
            host: finalHost,
            username: finalUsername,
            command: remoteCommand,
            port: port,
            identityFile: identityFile,
            timeout: timeout,
            logger: logger
        )

        let statusIcon = exitCode == 0 ? "✅" : "❌"
        var output = """
        \(statusIcon) SSH Command Result
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Host: \(finalUsername)@\(finalHost):\(port)
        Command: \(command)
        Exit Code: \(exitCode)

        """

        if !stdout.isEmpty {
            output += "📤 Output:\n\(stdout)\n"
        }
        if !stderr.isEmpty {
            output += "⚠️ Stderr:\n\(stderr)\n"
        }
        if stdout.isEmpty && stderr.isEmpty {
            output += "(no output)\n"
        }

        return CallTool.Result(content: [.text(output)], isError: exitCode != 0)
    } catch {
        return CallTool.Result(
            content: [.text("❌ SSH execution failed: \(error.localizedDescription)")],
            isError: true
        )
    }
}

/// Save or update an SSH connection profile
func handleSaveSSHProfile(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"], case .string(let name) = nameValue,
          let hostValue = arguments["host"], case .string(let host) = hostValue,
          let userValue = arguments["username"], case .string(let username) = userValue else {
        return CallTool.Result(
            content: [.text("❌ Missing required parameters: 'name', 'host', 'username'")],
            isError: true
        )
    }

    var port = 22
    if let v = arguments["port"], case .string(let s) = v, let p = Int(s) { port = p }

    var identityFile: String? = nil
    if let v = arguments["identity_file"], case .string(let s) = v { identityFile = s }

    var defaultDir: String? = nil
    if let v = arguments["default_directory"], case .string(let s) = v { defaultDir = s }

    // Check if profile name already exists and update it
    if let existing = await SSHProfileStore.shared.getByName(name) {
        var updated = existing
        updated.host = host
        updated.username = username
        updated.port = port
        updated.identityFile = identityFile
        updated.defaultDirectory = defaultDir
        await SSHProfileStore.shared.save(updated)

        return CallTool.Result(
            content: [.text("""
            ✅ SSH profile updated: \(name)

            Host: \(username)@\(host):\(port)
            Identity: \(identityFile ?? "default")
            Directory: \(defaultDir ?? "home")
            """)],
            isError: false
        )
    }

    let profile = SSHProfile(
        name: name,
        host: host,
        username: username,
        port: port,
        identityFile: identityFile,
        defaultDirectory: defaultDir
    )

    await SSHProfileStore.shared.save(profile)

    return CallTool.Result(
        content: [.text("""
        ✅ SSH profile saved: \(name)

        ID: \(profile.id)
        Host: \(username)@\(host):\(port)
        Identity: \(identityFile ?? "default")
        Directory: \(defaultDir ?? "home")

        Use with: ssh_execute --profile "\(name)" --command "your command"
        """)],
        isError: false
    )
}

/// List all saved SSH profiles
func handleListSSHProfiles(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    let profiles = await SSHProfileStore.shared.list()

    if profiles.isEmpty {
        return CallTool.Result(
            content: [.text("📋 No SSH profiles saved.\n\nUse 'save_ssh_profile' to create one.")],
            isError: false
        )
    }

    var output = "🔑 SSH PROFILES (\(profiles.count))\n"
    output += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

    for profile in profiles {
        let lastUsedStr = profile.lastUsed?.ISO8601Format() ?? "never"
        output += """
        📡 \(profile.name)
        ├─ ID: \(profile.id)
        ├─ Host: \(profile.username)@\(profile.host):\(profile.port)
        ├─ Identity: \(profile.identityFile ?? "default key")
        ├─ Directory: \(profile.defaultDirectory ?? "~")
        ├─ Created: \(profile.createdAt.ISO8601Format())
        └─ Last Used: \(lastUsedStr)

        """
    }

    return CallTool.Result(content: [.text(output)], isError: false)
}

/// Delete an SSH profile
func handleDeleteSSHProfile(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return CallTool.Result(content: [.text("❌ Missing arguments")], isError: true)
    }

    // Accept either id or name
    var profileId: String?

    if let v = arguments["profile_id"], case .string(let id) = v {
        profileId = id
    } else if let v = arguments["name"], case .string(let name) = v {
        if let profile = await SSHProfileStore.shared.getByName(name) {
            profileId = profile.id
        }
    }

    guard let id = profileId else {
        return CallTool.Result(
            content: [.text("❌ Missing parameter: 'profile_id' or 'name'")],
            isError: true
        )
    }

    if await SSHProfileStore.shared.delete(id: id) {
        return CallTool.Result(content: [.text("✅ SSH profile deleted.")], isError: false)
    } else {
        return CallTool.Result(content: [.text("❌ SSH profile not found.")], isError: true)
    }
}
