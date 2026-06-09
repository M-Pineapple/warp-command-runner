import Foundation
import Logging

// MARK: - Shared process execution
//
// Every spawn site in the server used the same fragile pattern:
//
//     try process.run()
//     process.waitUntilExit()                      // 1
//     pipe.fileHandleForReading.readDataToEndOfFile()  // 2
//
// That has two failure modes:
//
// 1. Pipe deadlock — if the child writes more than the pipe buffer (~64 KB)
//    to stdout or stderr, it blocks on write while the parent blocks in
//    waitUntilExit(). Permanent deadlock. Build logs, `git log`, or a remote
//    `journalctl` hit this easily.
// 2. Unbounded hangs — no execution timeout anywhere, and waitUntilExit()
//    called from an async MCP handler parks a Swift cooperative-pool thread.
//    The pool has roughly one thread per core, so a few concurrent slow
//    calls starve the whole server, including the transport.
//
// runProcess() fixes both: pipes are drained concurrently while the child
// runs, the blocking wait happens on a GCD global-pool thread (not the
// cooperative pool), and an optional timeout escalates SIGTERM → SIGKILL.

/// Result of a completed (or timed-out) process run.
struct ProcessRunnerResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    /// True when the process was killed because it exceeded the timeout.
    let timedOut: Bool
}

/// Small lock-protected box for values shared between GCD threads.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Default grace period between SIGTERM and SIGKILL on timeout.
private let killGracePeriod: TimeInterval = 2.0

/// Run an external process safely.
///
/// - Pipes are drained concurrently (no 64 KB pipe deadlock).
/// - The wait happens on a GCD thread, never the Swift cooperative pool.
/// - `timeout` (seconds) sends SIGTERM, then SIGKILL after a grace period.
///
/// Throws only if the process fails to launch.
func runProcess(
    executablePath: String,
    arguments: [String],
    currentDirectory: String? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil
) async throws -> ProcessRunnerResult {
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runProcessBlocking(
                    executablePath: executablePath,
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    timeout: timeout
                )
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Blocking core of runProcess. Safe to call from a GCD thread or other
/// non-cooperative context; never call this directly from an async handler.
func runProcessBlocking(
    executablePath: String,
    arguments: [String],
    currentDirectory: String? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil
) throws -> ProcessRunnerResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    if let currentDirectory = currentDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    }
    if let environment = environment {
        process.environment = environment
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutData = Locked(Data())
    let stderrData = Locked(Data())
    let timedOut = Locked(false)

    // Drain both pipes concurrently so the child can never block on a full
    // pipe buffer. readDataToEndOfFile returns at EOF (i.e. process exit).
    let drainGroup = DispatchGroup()
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stdoutData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stderrData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }

    try process.run()

    // Timeout watchdog: SIGTERM first, SIGKILL after a grace period.
    var watchdog: DispatchWorkItem?
    if let timeout = timeout, timeout > 0 {
        let item = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        watchdog = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    process.waitUntilExit()
    watchdog?.cancel()
    drainGroup.wait()

    return ProcessRunnerResult(
        stdout: String(data: stdoutData.value, encoding: .utf8) ?? "",
        stderr: String(data: stderrData.value, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus,
        timedOut: timedOut.value
    )
}
