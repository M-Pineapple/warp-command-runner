import Foundation
import MCP
import Logging

/// Pairs Streamable HTTP POST bodies with MCP JSON-RPC responses on a
/// long-lived 0.10 `Transport`. Requests are serialised so the SDK session
/// stays coherent. Repeat `initialize` calls reuse the first result (cloud
/// hosts retry initialize; the 0.10 server would otherwise error).
actor HTTPBridgeTransport: Transport {
    let logger: Logger
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var cachedInitialize: Data?

    init(logger: Logger) {
        self.logger = logger
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
        for (_, waiter) in pending {
            waiter.resume(throwing: CancellationError())
        }
        pending.removeAll()
    }

    func send(_ data: Data) async throws {
        guard let id = jsonRPCId(data) else {
            logger.debug("MCP server sent a notification (\(data.count) bytes)")
            return
        }
        pending.removeValue(forKey: id)?.resume(returning: data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    /// Handle one HTTP JSON-RPC body. Notifications return nil (HTTP 202).
    func handle(body: Data) async throws -> Data? {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HTTPBridgeError.invalidJSON
        }
        let method = obj["method"] as? String
        let id = jsonRPCId(body)

        if method == "initialize", let cached = cachedInitialize, let id {
            return rewrittenId(cached, to: id)
        }

        if id == nil {
            continuation.yield(body)
            return nil
        }

        let requestId = id!
        let response: Data = try await withCheckedThrowingContinuation { cont in
            pending[requestId] = cont
            continuation.yield(body)
        }

        if method == "initialize" {
            cachedInitialize = response
        }
        return response
    }

    private func jsonRPCId(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] else { return nil }
        if let s = id as? String { return s }
        if let n = id as? NSNumber { return n.stringValue }
        return nil
    }

    private func rewrittenId(_ data: Data, to newId: String) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        if let n = Int(newId) {
            obj["id"] = n
        } else {
            obj["id"] = newId
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }
}

enum HTTPBridgeError: Error {
    case invalidJSON
}
