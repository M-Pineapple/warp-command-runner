import Foundation
import Security

/// One-time pairing code that authorizes a new remote OAuth client.
///
/// The code is shown only on the Mac (stderr of the `--http` process, the
/// server log, and a macOS notification). It is never sent in any HTTP
/// response. Each code is single-use, expires after `lifetime`, and is
/// rotated after `maxFailures` wrong attempts.
struct PairingCodeState: Sendable {
    static let lifetime: TimeInterval = 600
    static let maxFailures = 5
    /// Unambiguous alphabet (no 0/O/1/I/L).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 8

    private(set) var code: String?
    private(set) var expiresAt: Date = .distantPast
    private(set) var failures = 0

    /// Returns a fresh code when none is active, else nil (the current one stays valid).
    mutating func issueIfNeeded(now: Date = Date()) -> String? {
        if code != nil, expiresAt > now { return nil }
        let fresh = Self.generate()
        code = fresh
        expiresAt = now.addingTimeInterval(Self.lifetime)
        failures = 0
        return fresh
    }

    /// Constant-time check. Consumes the code on success. Rotates it out after
    /// too many failures.
    mutating func consume(_ supplied: String?, now: Date = Date()) -> Bool {
        guard let current = code, expiresAt > now else {
            code = nil
            return false
        }
        let normalized = (supplied ?? "")
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
        if Self.constantTimeEquals(normalized, current) {
            code = nil
            failures = 0
            return true
        }
        failures += 1
        if failures >= Self.maxFailures {
            code = nil
        }
        return false
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        // 256 % 31 != 0 introduces a negligible bias; acceptable for an 8-char,
        // single-use, rate-limited code.
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        let n = max(x.count, y.count)
        for i in 0..<n {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            diff |= l ^ r
        }
        return diff == 0
    }
}

/// Shows a pairing code on the Mac only.
enum PairingCodeDisplay {
    static func show(_ code: String, logger: ((String) -> Void)? = nil) {
        let pretty = String(code.prefix(4)) + "-" + String(code.dropFirst(4))
        let line = "Warp Command Runner pairing code: \(pretty) (valid 10 minutes, single use)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        logger?(line.trimmingCharacters(in: .newlines))
        #if os(macOS)
        let script = "display notification \"Pairing code: \(pretty)\" with title \"Warp Command Runner\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        #endif
    }
}

/// Simple sliding-window limiter for dynamic client registration.
struct RegistrationLimiter: Sendable {
    static let maxClients = 20
    static let windowSeconds: TimeInterval = 600
    static let maxPerWindow = 5
    private var recent: [Date] = []

    mutating func allow(existingClients: Int, now: Date = Date()) -> Bool {
        guard existingClients < Self.maxClients else { return false }
        recent.removeAll { now.timeIntervalSince($0) > Self.windowSeconds }
        guard recent.count < Self.maxPerWindow else { return false }
        recent.append(now)
        return true
    }
}
