import Foundation

enum RemoteLaunchAgent {
    static let label = "com.m-pineapple.warp-command-runner"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static func binaryPath() -> String {
        let bundled = "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") { return argv0 }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(argv0).path
    }

    static func install() throws -> String {
        let agents = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let stderr = AppPaths.configDirectory.appendingPathComponent("http-stderr.log").path
        let program = binaryPath()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(program))</string>
                <string>--http</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(stderr))</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = try runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        let load = try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return "Installed LaunchAgent \(label)\nBinary: \(program)\n\(load)"
    }

    static func uninstall() throws -> String {
        _ = try runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        return "Removed LaunchAgent \(label)"
    }

    /// Escape XML text so paths with `&`, `<`, or `>` stay valid plist.
    /// Spaces in `/Applications/Warp Command Runner.app/...` are legal in element text.
    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func runLaunchctl(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let combined = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            + (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
