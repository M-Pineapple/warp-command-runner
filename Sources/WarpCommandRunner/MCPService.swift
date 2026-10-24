import Foundation
import Logging
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

    /// ServiceLifecycle never calls a `shutdown()` method on a service. It
    /// signals graceful shutdown (SIGTERM/SIGINT) or cancels the task, so the
    /// server is stopped from those handlers. Without this the process kept
    /// running after SIGTERM until stdin closed.
    func run() async throws {
        try await server.start(transport: transport)
        await withTaskCancellationOrGracefulShutdownHandler {
            await server.waitUntilCompleted()
        } onCancelOrGracefulShutdown: {
            Task { await server.stop() }
        }
    }

    /// The process-wide group. When the MCP service finishes (stdin EOF) the
    /// group shuts down gracefully, so the process exits 0 instead of failing
    /// with "service finished unexpectedly".
    static func makeServiceGroup(
        mcpService: MCPService,
        extraServices: [any Service],
        logger: Logger
    ) -> ServiceGroup {
        ServiceGroup(
            configuration: .init(
                services: [.init(service: mcpService, successTerminationBehavior: .gracefullyShutdownGroup)]
                    + extraServices.map { .init(service: $0) },
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )
    }
}
