import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Shell Environment Snapshots

/// Actor for thread-safe environment snapshot storage
actor EnvironmentStore {
    private var snapshots: [String: EnvironmentSnapshotData] = [:]

    func store(name: String, snapshot: EnvironmentSnapshotData) {
        snapshots[name] = snapshot
    }

    func retrieve(name: String) -> EnvironmentSnapshotData? {
        return snapshots[name]
    }

    func list() -> [(name: String, timestamp: Date, count: Int)] {
        return snapshots.map { (name: $0.key, timestamp: $0.value.timestamp, count: $0.value.variables.count) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func remove(name: String) -> Bool {
        return snapshots.removeValue(forKey: name) != nil
    }
}

struct EnvironmentSnapshotData: Codable {
    let name: String
    let variables: [String: String]
    let timestamp: Date
    let directory: String
}

/// Global environment store
let environmentStore = EnvironmentStore()

// MARK: - Tool Handlers

/// Handle capture_environment tool — takes a snapshot of current shell environment
func handleCaptureEnvironment(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let nameValue = arguments["name"],
          case .string(let name) = nameValue else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'name' parameter — provide a name for this snapshot")],
            isError: true
        )
    }

    var workingDirectory: String?
    if let dir = arguments["working_directory"],
       case .string(let dirString) = dir {
        workingDirectory = dirString
    }

    logger.info("Capturing environment snapshot: \(name)")

    // Capture the user's REAL interactive-login shell environment (sources
    // ~/.zprofile, ~/.zshrc, etc.) rather than the MCP server's own minimal
    // inherited environment. Falls back to the process environment on failure.
    let capture = captureRealShellEnvironment(workingDirectory: workingDirectory, logger: logger)
    let variables = capture.variables
    let cwd = variables["PWD"] ?? workingDirectory ?? capture.directory

    let snapshot = EnvironmentSnapshotData(
        name: name,
        variables: variables,
        timestamp: Date(),
        directory: cwd
    )

    await environmentStore.store(name: name, snapshot: snapshot)
    persistSnapshot(snapshot, logger: logger)

    let sourceNote = capture.viaFallback
        ? "\n⚠️ Source: MCP process environment (shell capture unavailable) — PATH and profile-defined vars may be missing."
        : "\n• Source: your \(capture.shell) login shell (~/.zshrc / profile sourced)"

    return CallTool.Result(
        content: [.text("""
        ✅ Environment snapshot captured: "\(name)"
        • Variables: \(variables.count)
        • Directory: \(cwd)\(sourceNote)
        • Timestamp: \(ISO8601DateFormatter().string(from: snapshot.timestamp))

        💡 Use 'diff_environment' with two snapshot names to compare.
        """)],
        isError: false
    )
}

/// Handle diff_environment tool — compares two snapshots
func handleDiffEnvironment(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let fromValue = arguments["from"],
          case .string(let fromName) = fromValue,
          let toValue = arguments["to"],
          case .string(let toName) = toValue else {
        return CallTool.Result(
            content: [.text("Missing parameters: 'from' and 'to' snapshot names are required")],
            isError: true
        )
    }

    logger.info("Diffing environments: \(fromName) → \(toName)")

    guard let fromSnapshot = await environmentStore.retrieve(name: fromName) else {
        return CallTool.Result(
            content: [.text("❌ Snapshot '\(fromName)' not found. Use 'capture_environment' first.")],
            isError: true
        )
    }

    guard let toSnapshot = await environmentStore.retrieve(name: toName) else {
        return CallTool.Result(
            content: [.text("❌ Snapshot '\(toName)' not found. Use 'capture_environment' first.")],
            isError: true
        )
    }

    // Compute diff
    let fromVars = fromSnapshot.variables
    let toVars = toSnapshot.variables

    let allKeys = Set(fromVars.keys).union(Set(toVars.keys)).sorted()

    var added: [String] = []
    var removed: [String] = []
    var changed: [(key: String, from: String, to: String)] = []
    var unchanged = 0

    for key in allKeys {
        let fromVal = fromVars[key]
        let toVal = toVars[key]

        if fromVal == nil && toVal != nil {
            added.append("\(key)=\(toVal!)")
        } else if fromVal != nil && toVal == nil {
            removed.append("\(key)=\(fromVal!)")
        } else if fromVal != toVal {
            changed.append((key: key, from: fromVal!, to: toVal!))
        } else {
            unchanged += 1
        }
    }

    let formatter = ISO8601DateFormatter()

    var output = """
    🔄 Environment Diff: "\(fromName)" → "\(toName)"
    From: \(formatter.string(from: fromSnapshot.timestamp)) (\(fromSnapshot.directory))
    To:   \(formatter.string(from: toSnapshot.timestamp)) (\(toSnapshot.directory))

    Summary: +\(added.count) added, -\(removed.count) removed, ~\(changed.count) changed, \(unchanged) unchanged
    """

    if !added.isEmpty {
        output += "\n\n➕ Added (\(added.count)):"
        for item in added.prefix(20) {
            output += "\n  \(item)"
        }
        if added.count > 20 { output += "\n  ... and \(added.count - 20) more" }
    }

    if !removed.isEmpty {
        output += "\n\n➖ Removed (\(removed.count)):"
        for item in removed.prefix(20) {
            output += "\n  \(item)"
        }
        if removed.count > 20 { output += "\n  ... and \(removed.count - 20) more" }
    }

    if !changed.isEmpty {
        output += "\n\n🔀 Changed (\(changed.count)):"
        for item in changed.prefix(20) {
            let fromTrunc = item.from.count > 60 ? String(item.from.prefix(60)) + "..." : item.from
            let toTrunc = item.to.count > 60 ? String(item.to.prefix(60)) + "..." : item.to
            output += "\n  \(item.key):"
            output += "\n    - \(fromTrunc)"
            output += "\n    + \(toTrunc)"
        }
        if changed.count > 20 { output += "\n  ... and \(changed.count - 20) more" }
    }

    return CallTool.Result(
        content: [.text(output)],
        isError: false
    )
}

// MARK: - Persistence

private func persistSnapshot(_ snapshot: EnvironmentSnapshotData, logger: Logger) {
    let dir = AppPaths.configDirectory
        .appendingPathComponent("snapshots")

    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let file = dir.appendingPathComponent("\(snapshot.name).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601

    if let data = try? encoder.encode(snapshot) {
        try? data.write(to: file)
        logger.debug("Snapshot persisted to \(file.path)")
    }
}

// MARK: - Real shell environment capture

/// Capture the user's actual interactive-login shell environment.
///
/// The MCP server runs as a child of whichever MCP host spawned it, so its own environment is
/// a minimal inherited set (often ~9 vars, CWD `/`). To represent what the
/// user's terminal actually sees, we spawn their login + interactive shell
/// (`$SHELL -l -i -c env`), which sources ~/.zprofile, ~/.zshrc, etc. A watchdog
/// terminates the shell if a slow rc file would otherwise hang the capture, and
/// on any failure we fall back to the process environment so the tool never
/// breaks.
func captureRealShellEnvironment(
    workingDirectory: String?,
    timeout: TimeInterval = 8.0,
    logger: Logger
) -> (variables: [String: String], shell: String, directory: String, viaFallback: Bool) {
    let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let shellName = (shellPath as NSString).lastPathComponent
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let workDir = workingDirectory ?? homeDir

    func fallback() -> (variables: [String: String], shell: String, directory: String, viaFallback: Bool) {
        let env = ProcessInfo.processInfo.environment
        return (env, shellName, env["PWD"] ?? workDir, true)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    // -l (login) sources ~/.zprofile/.profile; -i (interactive) sources
    // ~/.zshrc/.bashrc — where most users actually set PATH and exports.
    process.arguments = ["-l", "-i", "-c", "env"]
    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
    // Detach stdin so an interactive shell can't block waiting for input.
    process.standardInput = FileHandle.nullDevice
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()  // discard rc-file chatter

    do {
        try process.run()
    } catch {
        logger.error("capture_environment: failed to spawn \(shellPath): \(error)")
        return fallback()
    }

    // Watchdog: wait for exit up to `timeout`; if a slow rc hangs it, terminate
    // and fall back rather than blocking the tool indefinitely.
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        process.waitUntilExit()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        logger.warning("capture_environment: \(shellName) capture timed out after \(Int(timeout))s; terminating and falling back.")
        process.terminate()
        _ = done.wait(timeout: .now() + 1.0)
        return fallback()
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    var variables: [String: String] = [:]
    for line in output.components(separatedBy: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eq])
        // Real env keys are identifiers; skip any noise an interactive rc might
        // print to stdout that happens to contain '='.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
        variables[key] = String(line[line.index(after: eq)...])
    }

    // If the shell yielded essentially nothing, prefer the fallback over storing
    // a misleadingly-empty snapshot.
    if variables.count <= 1 {
        logger.warning("capture_environment: \(shellName) produced \(variables.count) var(s); falling back to process env.")
        return fallback()
    }

    return (variables, shellName, variables["PWD"] ?? workDir, false)
}
