import Foundation

/// Local OAuth 2.1 authorization server for Streamable HTTP MCP.
/// Tokens live in `~/.warp-command-runner/oauth-store.json` (mode 0600).
actor OAuthService {
    struct Client: Codable, Sendable {
        var clientId: String
        var clientName: String
        var redirectURIs: [String]
    }

    struct AuthCode: Codable, Sendable {
        var code: String
        var clientId: String
        var redirectURI: String
        var codeChallenge: String
        var resource: String?
        var expiresAt: Date
        var scopes: [String]
    }

    struct AccessToken: Codable, Sendable {
        var token: String
        var clientId: String
        var refreshToken: String
        var expiresAt: Date
        var scopes: [String]
    }

    struct Store: Codable, Sendable {
        var clients: [Client] = []
        var codes: [AuthCode] = []
        var tokens: [AccessToken] = []
    }

    private var store: Store
    private let storeURL: URL
    let issuer: String

    init(issuer: String, storeURL: URL = AppPaths.configDirectory.appendingPathComponent("oauth-store.json")) {
        self.issuer = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.storeURL = storeURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? decoder.decode(Store.self, from: data) {
            self.store = decoded
        } else {
            self.store = Store()
        }
    }

    var resourceURL: String { issuer + "/mcp" }

    func protectedResourceMetadata() -> [String: Any] {
        [
            "resource": resourceURL,
            "authorization_servers": [issuer],
            "bearer_methods_supported": ["header"],
            "scopes_supported": ["mcp"],
        ]
    }

    func authorizationServerMetadata() -> [String: Any] {
        [
            "issuer": issuer,
            "authorization_endpoint": issuer + "/authorize",
            "token_endpoint": issuer + "/token",
            "registration_endpoint": issuer + "/register",
            "revocation_endpoint": issuer + "/revoke",
            "code_challenge_methods_supported": ["S256"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "response_types_supported": ["code"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["mcp"],
        ]
    }

    func register(clientName: String, redirectURIs: [String]) throws -> Client {
        let httpsURIs = redirectURIs.filter { uri in
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "https" || (scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
        }
        guard !httpsURIs.isEmpty else {
            throw OAuthError.invalidRedirect
        }
        let client = Client(
            clientId: OAuthCrypto.randomURLSafe(bytes: 16),
            clientName: String(clientName.prefix(80)),
            redirectURIs: httpsURIs
        )
        store.clients.append(client)
        try persist()
        return client
    }

    func client(id: String) -> Client? {
        store.clients.first { $0.clientId == id }
    }

    func mintAuthorizationCode(
        clientId: String,
        redirectURI: String,
        codeChallenge: String,
        resource: String?
    ) throws -> String {
        guard let client = client(id: clientId) else { throw OAuthError.unknownClient }
        guard client.redirectURIs.contains(redirectURI) else { throw OAuthError.invalidRedirect }
        guard !codeChallenge.isEmpty else { throw OAuthError.pkceRequired }
        pruneExpired()
        let code = OAuthCrypto.randomURLSafe(bytes: 32)
        store.codes.append(AuthCode(
            code: code,
            clientId: clientId,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            resource: resource,
            expiresAt: Date().addingTimeInterval(300),
            scopes: ["mcp"]
        ))
        try persist()
        return code
    }

    func exchangeCode(
        code: String,
        clientId: String,
        redirectURI: String,
        codeVerifier: String
    ) throws -> AccessToken {
        pruneExpired()
        guard let idx = store.codes.firstIndex(where: { $0.code == code }) else {
            throw OAuthError.invalidGrant
        }
        let record = store.codes[idx]
        store.codes.remove(at: idx)
        guard record.clientId == clientId, record.redirectURI == redirectURI else {
            throw OAuthError.invalidGrant
        }
        guard record.expiresAt > Date() else { throw OAuthError.invalidGrant }
        let expected = OAuthCrypto.s256Challenge(verifier: codeVerifier)
        guard expected == record.codeChallenge else { throw OAuthError.invalidGrant }
        let token = AccessToken(
            token: OAuthCrypto.randomURLSafe(bytes: 32),
            clientId: clientId,
            refreshToken: OAuthCrypto.randomURLSafe(bytes: 32),
            expiresAt: Date().addingTimeInterval(3600),
            scopes: record.scopes
        )
        store.tokens.append(token)
        try persist()
        return token
    }

    func refresh(refreshToken: String, clientId: String) throws -> AccessToken {
        pruneExpired()
        guard let idx = store.tokens.firstIndex(where: { $0.refreshToken == refreshToken && $0.clientId == clientId }) else {
            throw OAuthError.invalidGrant
        }
        store.tokens.remove(at: idx)
        let token = AccessToken(
            token: OAuthCrypto.randomURLSafe(bytes: 32),
            clientId: clientId,
            refreshToken: OAuthCrypto.randomURLSafe(bytes: 32),
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["mcp"]
        )
        store.tokens.append(token)
        try persist()
        return token
    }

    func validateAccessToken(_ raw: String) -> AccessToken? {
        pruneExpired()
        return store.tokens.first { $0.token == raw && $0.expiresAt > Date() }
    }

    func revoke(token: String) throws {
        store.tokens.removeAll { $0.token == token || $0.refreshToken == token }
        try persist()
    }

    private func pruneExpired() {
        let now = Date()
        store.codes.removeAll { $0.expiresAt < now }
        store.tokens.removeAll { $0.expiresAt < now }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}

enum OAuthError: Error, LocalizedError {
    case invalidRedirect
    case unknownClient
    case pkceRequired
    case invalidGrant

    var errorDescription: String? {
        switch self {
        case .invalidRedirect: return "invalid_redirect_uri"
        case .unknownClient: return "unauthorized_client"
        case .pkceRequired: return "invalid_request"
        case .invalidGrant: return "invalid_grant"
        }
    }
}
