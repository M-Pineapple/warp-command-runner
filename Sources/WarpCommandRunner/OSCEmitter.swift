import Foundation
import Logging

/// Emits OSC 777 `warp://cli-agent` events into Warp's UI.
///
/// Wire format observed from Warp source (AGPL — referenced, not vendored):
///   `app/src/terminal/cli_agent_sessions/event/v1.rs:14-76`
/// The escape sequence is:
///   ESC ] 777 ; notify ; warp://cli-agent ; <json-payload> BEL
/// Warp's terminal parser decodes the payload as JSON and routes it to its
/// cli-agent notification UI (see `app/src/terminal/view.rs`).
///
/// Since our MCP server's stdout is the JSON-RPC channel with the host,
/// we cannot emit OSC sequences directly to Warp's PTY. Instead this emitter
/// builds a `printf` invocation that the caller arranges to run *inside* a
/// Warp pane (via the existing AppleScript keystroke path used by
/// `execute_command`). For v6.0 we expose this as the `emit_warp_event` tool
/// and let the caller (or the LLM) decide which Warp pane is the target.
enum WarpCliAgentEventType: String, Codable {
    case sessionStart    = "session_start"
    case promptSubmit    = "prompt_submit"
    case toolComplete    = "tool_complete"
    case stop            = "stop"
    case permissionRequest = "permission_request"
    case idlePrompt      = "idle_prompt"
}

/// Generic envelope. Schema reimplemented from `event/v1.rs`; the payload is
/// kept opaque (`[String: AnyEncodable]`-equivalent via `Data` round-trip)
/// so we don't need to mirror every payload shape Warp accepts.
struct WarpCliAgentEvent: Encodable {
    let type: WarpCliAgentEventType
    let sessionId: String?
    /// JSON object payload. Stored as a pre-serialized `Data` so callers can
    /// pass through arbitrary keys without us having to model every variant.
    let payloadJSON: Data

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let sessionId { try c.encode(sessionId, forKey: .sessionId) }
        // Re-encode the opaque payload as a generic JSON value.
        if let obj = try? JSONSerialization.jsonObject(with: payloadJSON) {
            // Convert Foundation object back to JSON in the outer encoder by
            // re-serializing with sortedKeys for stable byte output.
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            if let str = String(data: data, encoding: .utf8),
               let pass = str.data(using: .utf8) {
                // Encode as raw JSON via a single-value container that takes
                // a JSONDecoder-shaped Decodable surrogate.
                let decoded = try JSONDecoder().decode(JSONValue.self, from: pass)
                try c.encode(decoded, forKey: .payload)
            }
        } else {
            // Fallback: empty object
            try c.encode([String: String](), forKey: .payload)
        }
    }
}

/// Minimal recursive JSON value — used only inside this file to round-trip
/// arbitrary payloads through Codable without losing type fidelity.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

enum OSCEmitter {

    /// Build the OSC 777 escape sequence as a String literal. Use `printfCommand`
    /// to wrap it for shell execution.
    static func sequence(for event: WarpCliAgentEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(event)
        guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
            throw OSCEmitterError.encodingFailed
        }
        // ESC = \x1B, BEL = \x07
        return "\u{1B}]777;notify;warp://cli-agent;\(jsonStr)\u{07}"
    }

    /// Build a `printf` command line that emits the OSC 777 sequence when
    /// run inside a Warp pane. The escape and BEL bytes are encoded as
    /// `\033` and `\007` so the shell expands them to the raw control bytes.
    /// JSON is single-quoted; embedded single quotes (rare in JSON keys/values
    /// but possible in strings) are escaped via `'\''`.
    static func printfCommand(for event: WarpCliAgentEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(event)
        guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
            throw OSCEmitterError.encodingFailed
        }
        let escaped = jsonStr.replacingOccurrences(of: "'", with: "'\\''")
        return "printf '\\033]777;notify;warp://cli-agent;\(escaped)\\007'"
    }

    /// Convenience: build an event from JSON-string payload.
    static func event(
        type: WarpCliAgentEventType,
        sessionId: String?,
        payloadJSON: String
    ) throws -> WarpCliAgentEvent {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw OSCEmitterError.encodingFailed
        }
        // Validate it's actual JSON (object).
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw OSCEmitterError.invalidPayload
        }
        return WarpCliAgentEvent(type: type, sessionId: sessionId, payloadJSON: data)
    }
}

enum OSCEmitterError: Error, CustomStringConvertible {
    case encodingFailed
    case invalidPayload

    var description: String {
        switch self {
        case .encodingFailed: return "Failed to encode OSC 777 event as JSON"
        case .invalidPayload: return "Payload must be a JSON object"
        }
    }
}
