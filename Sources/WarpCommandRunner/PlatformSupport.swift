import Foundation
import MCP

/// Linux builds (for example the container Glama runs) list the same tools as
/// macOS so every host sees one surface. Tools that need macOS answer with a
/// clear error there instead of failing part-way through.
enum PlatformSupport {
    /// Tools that drive Warp or another macOS terminal through AppleScript or
    /// deeplinks, or use the pasteboard or file-system events.
    static let macOSOnlyToolNames: Set<String> = [
        "execute_command",
        "execute_with_auto_retrieve",
        "execute_with_streaming",
        "run_template",
        "send_to_session",
        "open_terminal_tab",
        "focus_warp_session",
        "copy_to_clipboard",
        "read_from_clipboard",
        "add_file_watch",
    ]

    static var isMacOS: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func needsMacOSMessage(for tool: String) -> String {
        """
        \(tool) needs macOS. It uses AppleScript, Warp deeplinks, the pasteboard or file-system events, which are not available in this Linux build.
        execute_pipeline, execute_and_parse, ssh_execute and the history, template and analysis tools work here.
        """
    }

    static let remoteModeNeedsMacOSMessage = """
        --http, --install-agent and --uninstall-agent need macOS. The remote mode uses CryptoKit, Security and launchd.
        Run without flags for the stdio MCP server.
        """

    /// `nil` when the tool can run on this platform.
    static func unavailableResult(for tool: String, isMacOS: Bool = PlatformSupport.isMacOS) -> CallTool.Result? {
        guard !isMacOS, macOSOnlyToolNames.contains(tool) else { return nil }
        return CallTool.Result(content: [.text(needsMacOSMessage(for: tool))], isError: true)
    }
}
