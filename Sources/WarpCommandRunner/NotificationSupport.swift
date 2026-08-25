import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Terminal Notification Hooks

/// Actor for thread-safe notification preference storage
actor NotificationPreferenceStore {
    private var preferences = NotificationPreferences()

    struct NotificationPreferences: Codable {
        var enabled: Bool = true
        var soundEnabled: Bool = true
        var showOnSuccess: Bool = false
        var showOnFailure: Bool = true
        var minimumDuration: TimeInterval = 10 // Only notify if command took >10s
    }

    func get() -> NotificationPreferences {
        return preferences
    }

    func update(enabled: Bool? = nil, soundEnabled: Bool? = nil, showOnSuccess: Bool? = nil, showOnFailure: Bool? = nil, minimumDuration: TimeInterval? = nil) -> NotificationPreferences {
        if let v = enabled { preferences.enabled = v }
        if let v = soundEnabled { preferences.soundEnabled = v }
        if let v = showOnSuccess { preferences.showOnSuccess = v }
        if let v = showOnFailure { preferences.showOnFailure = v }
        if let v = minimumDuration { preferences.minimumDuration = v }
        return preferences
    }
}

/// Global notification preference store
let notificationPreferenceStore = NotificationPreferenceStore()

// MARK: - macOS Notification Dispatch

/// Send a native macOS notification via osascript
func sendMacOSNotification(title: String, message: String, sound: Bool = true, logger: Logger) {
    let soundClause = sound ? " sound name \"Blow\"" : ""
    let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")

    let script = "display notification \"\(escapedMessage)\" with title \"\(escapedTitle)\"\(soundClause)"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            logger.debug("macOS notification sent: \(title)")
        } else {
            logger.warning("osascript notification returned non-zero exit code")
        }
    } catch {
        logger.error("Failed to send macOS notification: \(error)")
    }
}

/// Send a command completion notification (called from command execution paths)
func sendCommandCompletionNotification(command: String, exitCode: Int32, duration: TimeInterval, logger: Logger) async {
    let prefs = await notificationPreferenceStore.get()

    guard prefs.enabled else { return }
    guard duration >= prefs.minimumDuration else { return }

    let succeeded = exitCode == 0
    if succeeded && !prefs.showOnSuccess { return }
    if !succeeded && !prefs.showOnFailure { return }

    let title = succeeded ? "Command Completed" : "Command Failed"
    let truncatedCmd = command.count > 60 ? String(command.prefix(60)) + "..." : command
    let durationStr = String(format: "%.1fs", duration)
    let message = "\(truncatedCmd)\nExit code: \(exitCode) | Duration: \(durationStr)"

    sendMacOSNotification(title: title, message: message, sound: prefs.soundEnabled, logger: logger)
}

// MARK: - Tool Handler

/// Handle set_notification_preference tool
func handleSetNotificationPreference(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    var enabled: Bool?
    var soundEnabled: Bool?
    var showOnSuccess: Bool?
    var showOnFailure: Bool?
    var minimumDuration: TimeInterval?

    if let arguments = params.arguments {
        if let v = arguments["enabled"], case .bool(let b) = v { enabled = b }
        if let v = arguments["sound"] ?? arguments["sound_enabled"], case .bool(let b) = v { soundEnabled = b }
        if let v = arguments["notify_on_success"] ?? arguments["show_on_success"], case .bool(let b) = v { showOnSuccess = b }
        if let v = arguments["notify_on_failure"] ?? arguments["show_on_failure"], case .bool(let b) = v { showOnFailure = b }
        if let v = arguments["minimum_duration"], case .double(let n) = v { minimumDuration = n }
        // Also handle integer values for minimum_duration
        if minimumDuration == nil, let v = arguments["minimum_duration"], case .int(let n) = v { minimumDuration = TimeInterval(n) }

        // Handle "show" action — just display current prefs
        if let action = arguments["action"], case .string(let actionStr) = action, actionStr == "show" {
            let prefs = await notificationPreferenceStore.get()
            return CallTool.Result(
                content: [.text("""
                🔔 Notification Preferences:
                • Enabled: \(prefs.enabled)
                • Sound: \(prefs.soundEnabled)
                • Notify on success: \(prefs.showOnSuccess)
                • Notify on failure: \(prefs.showOnFailure)
                • Minimum duration: \(prefs.minimumDuration)s
                """)],
                isError: false
            )
        }
    }

    // If no parameters at all, show current prefs
    if enabled == nil && soundEnabled == nil && showOnSuccess == nil && showOnFailure == nil && minimumDuration == nil {
        let prefs = await notificationPreferenceStore.get()
        return CallTool.Result(
            content: [.text("""
            🔔 Notification Preferences:
            • Enabled: \(prefs.enabled)
            • Sound: \(prefs.soundEnabled)
            • Notify on success: \(prefs.showOnSuccess)
            • Notify on failure: \(prefs.showOnFailure)
            • Minimum duration: \(prefs.minimumDuration)s

            💡 Pass parameters to update: enabled, sound_enabled, show_on_success, show_on_failure, minimum_duration
            """)],
            isError: false
        )
    }

    let updated = await notificationPreferenceStore.update(
        enabled: enabled,
        soundEnabled: soundEnabled,
        showOnSuccess: showOnSuccess,
        showOnFailure: showOnFailure,
        minimumDuration: minimumDuration
    )

    logger.info("Notification preferences updated: enabled=\(updated.enabled)")

    // Send a test notification to confirm it works
    if updated.enabled {
        sendMacOSNotification(
            title: AppIdentity.displayName,
            message: "Notifications configured successfully",
            sound: updated.soundEnabled,
            logger: logger
        )
    }

    return CallTool.Result(
        content: [.text("""
        ✅ Notification preferences updated:
        • Enabled: \(updated.enabled)
        • Sound: \(updated.soundEnabled)
        • Notify on success: \(updated.showOnSuccess)
        • Notify on failure: \(updated.showOnFailure)
        • Minimum duration: \(updated.minimumDuration)s
        \(updated.enabled ? "\n🔔 A test notification was sent to verify it works." : "")
        """)],
        isError: false
    )
}
