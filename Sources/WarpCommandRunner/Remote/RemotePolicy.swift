import Foundation

/// Tools that type into the front Warp tab. Unsafe when the user is not
/// looking at the Mac. Remote HTTP sessions refuse them unless
/// `remote.allowKeystrokeTools` is true.
enum RemotePolicy {
    static let keystrokeToolNames: Set<String> = [
        "execute_command",
        "execute_with_auto_retrieve",
        "execute_with_streaming",
        "run_template",
        "send_to_session",
    ]

    static func denial(for tool: String, allowKeystrokeTools: Bool) -> String? {
        guard !allowKeystrokeTools, keystrokeToolNames.contains(tool) else {
            return nil
        }
        return """
        Remote MCP refused \(tool). That tool types into the front Warp tab, which is unsafe when you are not at the Mac.
        Use execute_pipeline instead, or set remote.allowKeystrokeTools to true in config.json if you really want it.
        """
    }
}

/// Append-only audit of remote tool calls. Lives next to config, mode 0600.
enum RemoteAuditLog {
    static var fileURL: URL {
        AppPaths.configDirectory.appendingPathComponent("remote-audit.log")
    }

    static func append(tool: String, allowed: Bool, detail: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts)\t\(allowed ? "allow" : "deny")\t\(tool)\t\(detail.replacingOccurrences(of: "\n", with: " "))\n"
        let path = fileURL.path
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }
}
