import Foundation
import MCP
import Logging

/// Tool handlers for Warp-specific v6.0 surface:
///   - `focus_warp_session` — dispatch `warp://session/<uuid>` to focus a pane
///   - `emit_warp_event`    — emit OSC 777 `warp://cli-agent` JSON to Warp's UI
///
/// Both rely on Warp being installed and registered as the handler for the
/// `warp://` URL scheme; no dependency on Warp's source.

// MARK: - focus_warp_session

func handleFocusWarpSession(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let uuidValue = arguments["warp_uuid"] ?? arguments["uuid"],
          case .string(let uuid) = uuidValue,
          !uuid.isEmpty else {
        return CallTool.Result(
            content: [.text("""
                Missing required 'warp_uuid' parameter.

                Note: this must be a UUID Warp itself recognises — typically
                obtained from an OSC 777 `session_start` event surfaced by
                the optional shell shim. Our locally-minted session UUIDs
                (returned by `open_terminal_tab`) are NOT valid here.
                """)],
            isError: true
        )
    }

    let r = WarpDeeplinks.focusSession(uuid: uuid, logger: logger)
    if r.success {
        return CallTool.Result(
            content: [.text("✅ Dispatched warp://session/\(uuid). If the UUID is unknown to Warp, focus is a no-op.")],
            isError: false
        )
    }
    return CallTool.Result(
        content: [.text("❌ Failed to dispatch focus deeplink: \(r.error ?? "unknown error")")],
        isError: true
    )
}

// MARK: - emit_warp_event

func handleEmitWarpEvent(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let typeValue = arguments["event_type"],
          case .string(let typeStr) = typeValue,
          let eventType = WarpCliAgentEventType(rawValue: typeStr) else {
        let allowed = [
            WarpCliAgentEventType.sessionStart,
            .promptSubmit, .toolComplete, .stop, .permissionRequest, .idlePrompt
        ].map { $0.rawValue }.joined(separator: ", ")
        return CallTool.Result(
            content: [.text("Missing/invalid 'event_type'. Allowed: \(allowed)")],
            isError: true
        )
    }

    // Payload — accept either an already-stringified JSON object or an
    // empty value (treated as `{}`).
    let payloadJSON: String = {
        if let payloadValue = arguments["payload"], case .string(let p) = payloadValue, !p.isEmpty {
            return p
        }
        return "{}"
    }()

    let sessionId: String? = {
        if let v = arguments["session_id"], case .string(let s) = v, !s.isEmpty {
            return s
        }
        return nil
    }()

    let event: WarpCliAgentEvent
    do {
        event = try OSCEmitter.event(type: eventType, sessionId: sessionId, payloadJSON: payloadJSON)
    } catch {
        return CallTool.Result(
            content: [.text("❌ Could not build event: \(error)")],
            isError: true
        )
    }

    // We can't write directly to Warp's PTY from this process (our stdout
    // is the MCP protocol channel with the client). The supported path is
    // to return the printf invocation; the caller (or LLM) runs it via
    // execute_command in the target Warp pane.
    let printfCmd: String
    do {
        printfCmd = try OSCEmitter.printfCommand(for: event)
    } catch {
        return CallTool.Result(
            content: [.text("❌ Could not encode OSC sequence: \(error)")],
            isError: true
        )
    }

    let raw: String
    do {
        raw = try OSCEmitter.sequence(for: event)
    } catch {
        raw = "<encode error: \(error)>"
    }

    let result = """
    ✅ OSC 777 event prepared (type: \(eventType.rawValue))

    To emit into a Warp pane, run via execute_command:
    \(printfCmd)

    Raw escape sequence (for reference):
    \(escapeForDisplay(raw))

    Schema reference: warp/app/src/terminal/cli_agent_sessions/event/v1.rs (AGPL).
    """

    logger.info("emit_warp_event prepared printf for type=\(eventType.rawValue)")
    return CallTool.Result(
        content: [.text(result)],
        isError: false
    )
}

/// Render ESC and BEL as visible mnemonics so the result text is safe to
/// display in a chat UI without corrupting it.
private func escapeForDisplay(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\u{1B}", with: "\\033")
        .replacingOccurrences(of: "\u{07}", with: "\\007")
}
