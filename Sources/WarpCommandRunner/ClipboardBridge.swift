import Foundation
import MCP
import Logging

#if canImport(AppKit)
import AppKit
#endif

// MARK: - v5.0.0: Clipboard Bridge Tools

/// Handle copy_to_clipboard tool — writes text to macOS pasteboard
func handleCopyToClipboard(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let textValue = arguments["text"],
          case .string(let text) = textValue else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'text' parameter")],
            isError: true
        )
    }

    #if canImport(AppKit)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let success = pasteboard.setString(text, forType: .string)

    if success {
        let charCount = text.count
        let lineCount = text.components(separatedBy: "\n").count
        let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text

        logger.info("Copied \(charCount) characters to clipboard")

        return CallTool.Result(
            content: [.text("""
            ✅ Copied to clipboard:
            • Characters: \(charCount)
            • Lines: \(lineCount)
            • Preview: \(preview)
            """)],
            isError: false
        )
    } else {
        logger.error("Failed to write to clipboard")
        return CallTool.Result(
            content: [.text("❌ Failed to write to clipboard")],
            isError: true
        )
    }
    #else
    return CallTool.Result(
        content: [.text("❌ Clipboard operations require macOS with AppKit")],
        isError: true
    )
    #endif
}

/// Handle read_from_clipboard tool — reads text from macOS pasteboard
func handleReadFromClipboard(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    #if canImport(AppKit)
    let pasteboard = NSPasteboard.general

    if let content = pasteboard.string(forType: .string) {
        let charCount = content.count
        let lineCount = content.components(separatedBy: "\n").count

        logger.info("Read \(charCount) characters from clipboard")

        return CallTool.Result(
            content: [.text("""
            📋 Clipboard Content:
            • Characters: \(charCount)
            • Lines: \(lineCount)

            Content:
            \(content)
            """)],
            isError: false
        )
    } else {
        logger.info("Clipboard is empty or contains non-text data")
        return CallTool.Result(
            content: [.text("📋 Clipboard is empty or contains non-text data")],
            isError: false
        )
    }
    #else
    return CallTool.Result(
        content: [.text("❌ Clipboard operations require macOS with AppKit")],
        isError: true
    )
    #endif
}
