import XCTest
import Foundation
import Logging
import MCP
import ServiceLifecycle
@testable import WarpCommandRunner

/// Guards for Linux container builds (for example Glama's): the tool list
/// stays the same everywhere, macOS-only tools answer with a clear error off
/// macOS, the empty list methods all answer, and the process exits cleanly
/// on stdin EOF and on SIGTERM.
final class PlatformAndLifecycleTests: XCTestCase {

    private func text(_ result: CallTool.Result?) -> String? {
        guard case .text(let text, _, _)? = result?.content.first else { return nil }
        return text
    }

    // MARK: macOS-only tools

    func testMacOSOnlyToolsAnswerNeedsMacOSOffMacOS() {
        XCTAssertFalse(PlatformSupport.macOSOnlyToolNames.isEmpty)
        for tool in PlatformSupport.macOSOnlyToolNames {
            let result = PlatformSupport.unavailableResult(for: tool, isMacOS: false)
            XCTAssertEqual(result?.isError, true, tool)
            let message = text(result) ?? ""
            XCTAssertTrue(message.contains("needs macOS"), message)
            XCTAssertTrue(message.contains(tool), message)
        }
    }

    func testNothingIsRefusedOnMacOS() {
        for tool in PlatformSupport.macOSOnlyToolNames {
            XCTAssertNil(PlatformSupport.unavailableResult(for: tool, isMacOS: true), tool)
        }
    }

    func testPortableToolsStayAvailableOffMacOS() {
        for tool in ["execute_pipeline", "execute_and_parse", "ssh_execute", "list_recent_commands",
                     "self_check", "list_templates", "check_interactive", "emit_warp_event"] {
            XCTAssertNil(PlatformSupport.unavailableResult(for: tool, isMacOS: false), tool)
        }
    }

    func testEveryKeystrokeToolIsMacOSOnly() {
        XCTAssertTrue(RemotePolicy.keystrokeToolNames.isSubset(of: PlatformSupport.macOSOnlyToolNames))
    }

    // MARK: process output

    /// Output larger than a pipe buffer comes back whole through the read loop
    /// that replaced readDataToEndOfFile (which traps on EINTR on Linux).
    func testRunProcessReadsLargeOutputWhole() throws {
        let result = try runProcessBlocking(executablePath: "/bin/sh",
                                            arguments: ["-c", "yes x | head -c 200000; echo err >&2"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200_000)
        XCTAssertEqual(result.stderr, "err\n")
    }

    // MARK: list methods

    func testEmptyListMethodsAllAnswer() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "test", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        let logger = Logger(label: "test")
        await WarpCommandRunner.setupResourceHandlers(server: server, logger: logger)
        await WarpCommandRunner.setupPromptHandlers(server: server, logger: logger)
        try await server.start(transport: serverTransport)
        let client = Client(name: "probe", version: "0")
        _ = try await client.connect(transport: clientTransport)

        let templates = try await client.listResourceTemplates()
        XCTAssertTrue(templates.templates.isEmpty)
        let resources = try await client.listResources()
        XCTAssertTrue(resources.resources.isEmpty)
        let prompts = try await client.listPrompts()
        XCTAssertTrue(prompts.prompts.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    // MARK: lifecycle

    private func makeGroup() async -> (ServiceGroup, InMemoryTransport) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "test", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        let service = MCPService(server: server, transport: serverTransport)
        let group = MCPService.makeServiceGroup(mcpService: service, extraServices: [], logger: Logger(label: "test"))
        try? await clientTransport.connect()
        return (group, clientTransport)
    }

    /// SIGTERM triggers a graceful shutdown. The server must stop even though
    /// the client never closes stdin.
    func testGracefulShutdownStopsServerWhileClientStaysConnected() async throws {
        let (group, clientTransport) = await makeGroup()
        let exited = expectation(description: "service group exited")
        let runner = Task {
            try? await group.run()
            exited.fulfill()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await group.triggerGracefulShutdown()
        await fulfillment(of: [exited], timeout: 5)
        runner.cancel()
        _ = clientTransport
    }

    /// stdin EOF ends the transport. The group must finish without an error
    /// so the process exits 0.
    func testClientDisconnectEndsGroupWithoutError() async throws {
        let (group, clientTransport) = await makeGroup()
        let exited = expectation(description: "service group exited")
        let failure = LockedBox<String?>(nil)
        let runner = Task {
            do { try await group.run() } catch { failure.set("\(error)") }
            exited.fulfill()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await clientTransport.disconnect()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertNil(failure.get())
        runner.cancel()
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
