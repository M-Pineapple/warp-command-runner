import Foundation
import NIO
import NIOFoundationCompat
import Logging

// MARK: - Event model

/// One event line received from a shell-shim instance.
struct ShellShimEvent: Codable, Sendable {
    let type: String              // "preexec" | "command_finished"
    let command: String?
    let exitCode: Int?
    let warpSessionId: String?
    let startedAt: String?        // unix timestamp string (preexec ts)
    let ts: String                // unix timestamp string (event time)

    enum CodingKeys: String, CodingKey {
        case type
        case command
        case exitCode = "exit_code"
        case warpSessionId = "warp_session_id"
        case startedAt = "started_at"
        case ts
    }
}

// MARK: - Event bus

/// Holds recently-received shell shim events. Bounded ring buffer; the
/// shim is observability-only in v6.0 — `execute_command` integration
/// (auto-routing through shim events) is deferred to v6.0.x.
actor ShellShimEventBus {
    private var events: [ShellShimEvent] = []
    private(set) var lastConnectedAt: Date? = nil
    private(set) var totalReceived: Int = 0
    private let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    func append(_ event: ShellShimEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        totalReceived += 1
        lastConnectedAt = Date()
    }

    func recent(limit: Int = 20) -> [ShellShimEvent] {
        let n = min(limit, events.count)
        return Array(events.suffix(n))
    }

    func snapshot() -> (count: Int, total: Int, lastAt: Date?) {
        return (events.count, totalReceived, lastConnectedAt)
    }

    /// Find the most recent `command_finished` event whose command line
    /// references the given command id. `execute_command` injects
    /// `bash /tmp/wcr_script_<id>.sh`, so the shim observes that path —
    /// letting us confirm completion and read the authoritative shell exit code.
    func finishedEvent(forCommandId id: String) -> ShellShimEvent? {
        let needles = TempFiles.scriptNeedle(commandId: id)
        return events.last { event in
            guard event.type == "command_finished", let command = event.command else { return false }
            return needles.contains(where: { command.contains($0) })
        }
    }
}

/// Global bus.
let shellShimEventBus = ShellShimEventBus()

// MARK: - Server

/// Per-user socket path so multiple users on the same machine don't collide.
func shellShimSocketPath() -> String {
    TempFiles.shellShimSocketPath()
}

/// NIO inbound handler: receives raw bytes, splits on newline, decodes each
/// JSON line into `ShellShimEvent`, and pushes to the bus.
private final class ShimLineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let logger: Logger
    private var carry = Data()

    init(logger: Logger) {
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        carry.append(contentsOf: bytes)

        while let nl = carry.firstIndex(of: 0x0A) {
            let line = carry.prefix(upTo: nl)
            carry = carry.suffix(from: carry.index(after: nl))
            guard !line.isEmpty else { continue }

            do {
                let event = try JSONDecoder().decode(ShellShimEvent.self, from: line)
                Task { await shellShimEventBus.append(event) }
            } catch {
                logger.debug("shim socket: skipping malformed line: \(error)")
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("shim socket: connection error: \(error)")
        context.close(promise: nil)
    }
}

/// Start the Unix-domain socket listener. Returns a handle the caller can
/// keep alive for the duration of the MCP server's lifetime. Failure to
/// bind is logged but non-fatal — shim is opt-in observability.
@discardableResult
func startShellShimSocketIfPossible(logger: Logger) -> Channel? {
    let path = shellShimSocketPath()

    // Unlink any stale socket file from a previous (possibly-crashed) run.
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(ShimLineHandler(logger: logger))
        }

    do {
        let address = try SocketAddress(unixDomainSocketPath: path)
        let channel = try bootstrap.bind(to: address).wait()
        // Restrict permissions so only the owner can connect (matches the
        // per-uid path naming).
        chmod(path, 0o600)
        logger.info("shell shim socket listening at \(path)")
        return channel
    } catch {
        logger.warning("shell shim socket: bind failed at \(path): \(error). Shim integration disabled this run.")
        try? group.syncShutdownGracefully()
        return nil
    }
}

// MARK: - Tool handler

import MCP

func handleShellShimStatus(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    let path = shellShimSocketPath()
    let listening = FileManager.default.fileExists(atPath: path)
    let snap = await shellShimEventBus.snapshot()

    let formatter = ISO8601DateFormatter()
    let lastSeen = snap.lastAt.map { formatter.string(from: $0) } ?? "never"

    var lines: [String] = []
    lines.append("🔌 Shell Shim Status")
    lines.append("• Socket path: \(path)")
    lines.append("• Listening: \(listening ? "yes" : "no")")
    lines.append("• Total events received: \(snap.total)")
    lines.append("• Buffered events: \(snap.count)")
    lines.append("• Last event at: \(lastSeen)")

    let recent = await shellShimEventBus.recent(limit: 5)
    if !recent.isEmpty {
        lines.append("\nMost recent events:")
        for ev in recent {
            switch ev.type {
            case "preexec":
                lines.append("  → preexec: \(ev.command ?? "?") @ \(ev.ts)")
            case "command_finished":
                let exit = ev.exitCode.map { "\($0)" } ?? "?"
                lines.append("  ← finished (exit=\(exit)): \(ev.command ?? "?") @ \(ev.ts)")
            default:
                lines.append("  · \(ev.type) @ \(ev.ts)")
            }
        }
    } else {
        lines.append("")
        lines.append("No events received yet. To enable, run:")
        lines.append("  helper/install-shim.sh")
        lines.append("Then open a new shell inside a Warp pane.")
    }

    return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
}
