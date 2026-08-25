import Foundation
import ServiceLifecycle
import MCP

/// Wraps the MCP `Server` + `Transport` pair as a ServiceLifecycle `Service`
/// so it can participate in the process-wide service group with graceful
/// shutdown on SIGTERM/SIGINT.
///
/// Extracted from the now-deleted CommandReceiverService.swift in v6.0;
/// the orphan TCP listener that shared that file was unreachable, but this
/// wrapper is the live MCP transport entrypoint used by WarpCommandRunner.
struct MCPService: Service {
    let server: Server
    let transport: any Transport

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    func shutdown() async {
        await server.stop()
    }
}
