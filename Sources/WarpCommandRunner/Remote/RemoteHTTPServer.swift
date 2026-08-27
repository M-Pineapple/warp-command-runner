import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Logging
import MCP
import ServiceLifecycle

/// Loopback Streamable HTTP + OAuth 2.1. Binds 127.0.0.1 only.
final class RemoteHTTPServer: @unchecked Sendable {
    private let logger: Logger
    private let oauth: OAuthService
    private let bridge: HTTPBridgeTransport
    private let listenPort: Int
    private let issuer: String

    init(
        logger: Logger,
        oauth: OAuthService,
        bridge: HTTPBridgeTransport,
        listenPort: Int,
        issuer: String
    ) {
        self.logger = logger
        self.oauth = oauth
        self.bridge = bridge
        self.listenPort = listenPort
        self.issuer = issuer
    }

    func bind() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RemoteHTTPHandler(
                        logger: self.logger,
                        oauth: self.oauth,
                        bridge: self.bridge,
                        issuer: self.issuer
                    ))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: listenPort).get()
        logger.info("Remote MCP listening on http://127.0.0.1:\(listenPort)/mcp (loopback only)")
        logger.info("OAuth issuer: \(issuer)")
        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
    }
}

final class RemoteHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private let oauth: OAuthService
    private let bridge: HTTPBridgeTransport
    private let issuer: String
    private var head: HTTPRequestHead?
    private var buffer = ByteBuffer()

    init(logger: Logger, oauth: OAuthService, bridge: HTTPBridgeTransport, issuer: String) {
        self.logger = logger
        self.oauth = oauth
        self.bridge = bridge
        self.issuer = issuer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            buffer.clear()
        case .body(var part):
            buffer.writeBuffer(&part)
        case .end:
            guard let head else { return }
            let body = buffer.readData(length: buffer.readableBytes) ?? Data()
            let promise = context.eventLoop.makePromise(of: HTTPReply.self)
            promise.completeWithTask {
                await self.route(head: head, body: body)
            }
            let ctx = context
            promise.futureResult.whenComplete { result in
                switch result {
                case .success(let reply):
                    self.writeReply(reply, context: ctx)
                case .failure(let error):
                    self.writeReply(HTTPReply(status: .internalServerError, body: Data("\(error)".utf8)), context: ctx)
                }
            }
        }
    }

    private func route(head: HTTPRequestHead, body: Data) async -> HTTPReply {
        let path = URL(string: head.uri)?.path ?? head.uri
        let method = head.method

        switch (method, path) {
        case (.GET, "/health"):
            return json(.ok, ["ok": true, "name": AppIdentity.displayName])
        case (.GET, "/.well-known/oauth-protected-resource"),
             (.GET, "/.well-known/oauth-protected-resource/mcp"):
            return json(.ok, await oauth.protectedResourceMetadata())
        case (.GET, "/.well-known/oauth-authorization-server"),
             (.GET, "/.well-known/oauth-authorization-server/mcp"):
            return json(.ok, await oauth.authorizationServerMetadata())
        case (.POST, "/register"):
            return await handleRegister(body: body)
        case (.GET, "/authorize"):
            return await handleAuthorize(uri: head.uri)
        case (.POST, "/authorize"):
            return await handleConsent(body: body)
        case (.POST, "/token"):
            return await handleToken(body: body)
        case (.POST, "/revoke"):
            return await handleRevoke(head: head, body: body)
        case (.POST, "/mcp"):
            return await handleMCP(head: head, body: body)
        default:
            return HTTPReply(status: .notFound, body: Data("not found".utf8), contentType: "text/plain")
        }
    }

    private func handleRegister(body: Data) async -> HTTPReply {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let name = obj["client_name"] as? String ?? "mcp-client"
        let uris = obj["redirect_uris"] as? [String] ?? []
        do {
            let client = try await oauth.register(clientName: name, redirectURIs: uris)
            return json(.created, [
                "client_id": client.clientId,
                "client_name": client.clientName,
                "redirect_uris": client.redirectURIs,
                "grant_types": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_method": "none",
            ])
        } catch {
            return oauthError(.badRequest, "invalid_client_metadata", error.localizedDescription)
        }
    }

    private func handleAuthorize(uri: String) async -> HTTPReply {
        let items = URLComponents(string: "http://loopback\(uri)")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let clientId = q("client_id"),
              let redirect = q("redirect_uri"),
              let challenge = q("code_challenge") else {
            return HTTPReply(status: .badRequest, body: Data("missing OAuth parameters".utf8), contentType: "text/plain")
        }
        let method = q("code_challenge_method") ?? "S256"
        guard method.uppercased() == "S256" else {
            return HTTPReply(status: .badRequest, body: Data("only S256 PKCE is supported".utf8), contentType: "text/plain")
        }
        let state = q("state") ?? ""
        let resource = q("resource")
        let html = consentHTML(
            clientId: clientId,
            redirectURI: redirect,
            challenge: challenge,
            state: state,
            resource: resource ?? ""
        )
        return HTTPReply(status: .ok, body: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }

    private func handleConsent(body: Data) async -> HTTPReply {
        let form = Self.parseForm(body)
        guard form["decision"] == "allow",
              let clientId = form["client_id"],
              let redirect = form["redirect_uri"],
              let challenge = form["code_challenge"] else {
            return HTTPReply(status: .forbidden, body: Data("denied".utf8), contentType: "text/plain")
        }
        do {
            let code = try await oauth.mintAuthorizationCode(
                clientId: clientId,
                redirectURI: redirect,
                codeChallenge: challenge,
                resource: form["resource"]
            )
            guard var comps = URLComponents(string: redirect) else {
                return oauthError(.badRequest, "invalid_request", "bad redirect")
            }
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "code", value: code))
            if let state = form["state"], !state.isEmpty {
                items.append(URLQueryItem(name: "state", value: state))
            }
            comps.queryItems = items
            var headers = HTTPHeaders()
            headers.add(name: "Location", value: comps.string ?? redirect)
            return HTTPReply(status: .seeOther, headers: headers, body: Data())
        } catch {
            return oauthError(.badRequest, error.localizedDescription, "authorization failed")
        }
    }

    private func handleToken(body: Data) async -> HTTPReply {
        let form = Self.parseForm(body)
        let grant = form["grant_type"] ?? ""
        do {
            if grant == "authorization_code" {
                let token = try await oauth.exchangeCode(
                    code: form["code"] ?? "",
                    clientId: form["client_id"] ?? "",
                    redirectURI: form["redirect_uri"] ?? "",
                    codeVerifier: form["code_verifier"] ?? ""
                )
                return tokenJSON(token)
            }
            if grant == "refresh_token" {
                let token = try await oauth.refresh(
                    refreshToken: form["refresh_token"] ?? "",
                    clientId: form["client_id"] ?? ""
                )
                return tokenJSON(token)
            }
            return oauthError(.badRequest, "unsupported_grant_type", grant)
        } catch {
            return oauthError(.badRequest, error.localizedDescription, "token exchange failed")
        }
    }

    private func handleRevoke(head: HTTPRequestHead, body: Data) async -> HTTPReply {
        let form = Self.parseForm(body)
        let token = form["token"] ?? bearer(head) ?? ""
        guard !token.isEmpty else {
            return oauthError(.badRequest, "invalid_request", "missing token")
        }
        try? await oauth.revoke(token: token)
        return HTTPReply(status: .ok, body: Data())
    }

    private func handleMCP(head: HTTPRequestHead, body: Data) async -> HTTPReply {
        guard let raw = bearer(head), await oauth.validateAccessToken(raw) != nil else {
            var headers = HTTPHeaders()
            headers.add(
                name: "WWW-Authenticate",
                value: "Bearer realm=\"\(AppIdentity.displayName)\", resource_metadata=\"\(issuer)/.well-known/oauth-protected-resource\""
            )
            return HTTPReply(status: .unauthorized, headers: headers, body: Data())
        }
        do {
            if let response = try await bridge.handle(body: body) {
                return HTTPReply(status: .ok, body: response, contentType: "application/json")
            }
            return HTTPReply(status: .accepted, body: Data())
        } catch {
            logger.error("MCP HTTP error: \(error)")
            return HTTPReply(status: .badRequest, body: Data("{\"error\":\"invalid_request\"}".utf8), contentType: "application/json")
        }
    }

    private func tokenJSON(_ token: OAuthService.AccessToken) -> HTTPReply {
        json(.ok, [
            "access_token": token.token,
            "refresh_token": token.refreshToken,
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": token.scopes.joined(separator: " "),
        ])
    }

    private func bearer(_ head: HTTPRequestHead) -> String? {
        guard let value = head.headers["authorization"].first else { return nil }
        let prefix = "Bearer "
        guard value.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private func json(_ status: HTTPResponseStatus, _ object: [String: Any]) -> HTTPReply {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPReply(status: status, body: data, contentType: "application/json")
    }

    private func oauthError(_ status: HTTPResponseStatus, _ code: String, _ description: String) -> HTTPReply {
        json(status, ["error": code, "error_description": description])
    }

    private func writeReply(_ reply: HTTPReply, context: ChannelHandlerContext) {
        var headers = reply.headers
        headers.add(name: "Content-Type", value: reply.contentType)
        headers.add(name: "Content-Length", value: "\(reply.body.count)")
        headers.add(name: "Cache-Control", value: "no-store")
        let head = HTTPResponseHead(version: .http1_1, status: reply.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !reply.body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: reply.body.count)
            buf.writeBytes(reply.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func consentHTML(clientId: String, redirectURI: String, challenge: String, state: String, resource: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Allow Warp Command Runner</title>
        <style>body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem;line-height:1.5}
        button{font-size:1rem;padding:.5rem 1rem;margin-right:.5rem}</style></head><body>
        <h1>Allow this app to use your terminal?</h1>
        <p><strong>\(esc(AppIdentity.displayName))</strong> on this Mac will run commands that a cloud chat (Grok, ChatGPT, Claude, or similar) sends.</p>
        <p>Only continue if you started this from your own Grok, ChatGPT, or Claude connector settings.</p>
        <form method="post" action="/authorize">
        <input type="hidden" name="client_id" value="\(esc(clientId))">
        <input type="hidden" name="redirect_uri" value="\(esc(redirectURI))">
        <input type="hidden" name="code_challenge" value="\(esc(challenge))">
        <input type="hidden" name="state" value="\(esc(state))">
        <input type="hidden" name="resource" value="\(esc(resource))">
        <button type="submit" name="decision" value="allow">Allow</button>
        <button type="submit" name="decision" value="deny">Deny</button>
        </form></body></html>
        """
    }

    private static func parseForm(_ body: Data) -> [String: String] {
        guard let raw = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out[parts[0].removingPercentEncoding ?? parts[0]] = parts[1]
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? parts[1]
        }
        return out
    }
}

struct HTTPReply: Sendable {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Data
    var contentType: String

    init(status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders(), body: Data, contentType: String = "application/json") {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

struct HTTPListenService: Service {
    let server: RemoteHTTPServer

    func run() async throws {
        try await server.bind()
    }
}
