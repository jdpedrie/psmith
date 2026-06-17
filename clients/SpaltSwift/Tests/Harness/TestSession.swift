import Foundation
import Connect
@_exported import SpaltKit

/// Per-test convenience: build a fresh SpaltClient pointed at a TestSpaltdServer,
/// register a uuid-suffixed user via the bootstrap admin, log them in, and hand
/// back the authenticated client + the user record.
///
/// Why register-via-admin and not a public Register RPC: spaltd doesn't
/// expose registration as an unauthenticated RPC. The only paths to a user
/// row are (a) `auth.Bootstrap` at server start (SPALT_BOOTSTRAP_ADMIN_*)
/// or (b) `AuthService.CreateUser`, which is admin-gated. The harness seeds
/// an admin via env vars and uses CreateUser for per-test users.
public enum TestSession {
    /// Builds an authenticated `SpaltClient` for a brand-new user. The user
    /// is created via the bootstrap admin's CreateUser RPC, then logged in
    /// to populate the token store.
    public static func freshUser(
        server: TestSpaltdServer,
        usernamePrefix: String = "test"
    ) async throws -> (client: SpaltClient, user: SpaltUser) {
        let admin = try await adminHandle(server: server)

        let username = "\(usernamePrefix)-\(UUID().uuidString.prefix(8))".lowercased()
        let password = "test-password-\(UUID().uuidString.prefix(8))"

        var req = Spalt_V1_CreateUserRequest()
        req.username = username
        req.password = password
        req.isAdmin = false
        let resp = await admin.rawAuthClient.createUser(request: req, headers: [:])
        if resp.message == nil, let err = resp.error {
            throw SpaltError.from(err)
        }

        let client = await makeClient(server: server)
        let user = try await client.auth.login(username: username, password: password)
        return (client, user)
    }

    /// Returns an admin-authenticated handle, cached per server. Used by
    /// freshUser() and any test that legitimately needs admin-only RPCs.
    public static func adminHandle(server: TestSpaltdServer) async throws -> AdminHandle {
        if let cached = AdminCache.shared.get(serverID: ObjectIdentifier(server)) {
            return cached
        }
        // Step 1: log in as admin via an unauthenticated raw client to get
        // a session token.
        let unauthRaw = await makeRawAuthClient(
            server: server, withSessionFromTokenStore: nil
        )
        var loginReq = Spalt_V1_LoginRequest()
        loginReq.username = server.adminUsername
        loginReq.password = server.adminPassword
        let resp = await unauthRaw.login(request: loginReq, headers: [:])
        guard let msg = resp.message else {
            throw SpaltError.from(resp.error ?? ConnectError(code: .unknown, message: "admin login failed"))
        }

        // Step 2: build authenticated raw client + SpaltClient sharing a
        // single in-memory token store.
        let tokenStore = InMemoryTokenStore(initial: msg.sessionToken)
        let authedRaw = await makeRawAuthClient(
            server: server, withSessionFromTokenStore: tokenStore
        )
        let authState = await MainActor.run { AuthState() }
        let clarkClient = SpaltClient(
            host: server.baseURL,
            tokenStore: tokenStore,
            authState: authState
        )
        let handle = AdminHandle(clarkClient: clarkClient, rawAuthClient: authedRaw)
        AdminCache.shared.set(serverID: ObjectIdentifier(server), handle: handle)
        return handle
    }

    /// Construct an unauthenticated SpaltClient pointed at the test server.
    /// Each call gets its own InMemoryTokenStore + AuthState so calls don't
    /// bleed state between tests.
    public static func makeClient(server: TestSpaltdServer) async -> SpaltClient {
        let tokenStore = InMemoryTokenStore()
        let authState = await MainActor.run { AuthState() }
        return SpaltClient(
            host: server.baseURL,
            tokenStore: tokenStore,
            authState: authState
        )
    }

    /// Construct a SpaltClient with a caller-supplied token store. Tests that
    /// need to inspect/seed the keychain-equivalent (e.g. `restoreSession`)
    /// pass an `InMemoryTokenStore` and reuse the reference after handing it
    /// to the client.
    public static func makeClient(
        server: TestSpaltdServer,
        tokenStore: TokenStore
    ) async -> SpaltClient {
        let authState = await MainActor.run { AuthState() }
        return SpaltClient(
            host: server.baseURL,
            tokenStore: tokenStore,
            authState: authState
        )
    }

    // MARK: - Internal helpers

    private static func makeRawAuthClient(
        server: TestSpaltdServer,
        withSessionFromTokenStore tokenStore: TokenStore?
    ) async -> Spalt_V1_AuthServiceClient {
        var interceptors: [InterceptorFactory] = []
        if let tokenStore {
            let authState = await MainActor.run { AuthState() }
            let interceptor = AuthInterceptor(tokenStore: tokenStore, authState: authState)
            interceptors.append(InterceptorFactory { _ in interceptor })
        }
        let config = ProtocolClientConfig(
            host: server.baseURL.absoluteString,
            networkProtocol: .connect,
            codec: ProtoCodec(),
            interceptors: interceptors
        )
        let proto = ProtocolClient(httpClient: URLSessionHTTPClient(), config: config)
        return Spalt_V1_AuthServiceClient(client: proto)
    }
}

/// An admin-authenticated session: both a `SpaltClient` (for repository-shaped
/// operations) and a raw generated `Spalt_V1_AuthServiceClient` (for admin
/// RPCs like `CreateUser` that aren't on the public AuthRepository surface).
public final class AdminHandle: Sendable {
    public let clarkClient: SpaltClient
    public let rawAuthClient: Spalt_V1_AuthServiceClient

    init(clarkClient: SpaltClient, rawAuthClient: Spalt_V1_AuthServiceClient) {
        self.clarkClient = clarkClient
        self.rawAuthClient = rawAuthClient
    }
}

final class AdminCache: @unchecked Sendable {
    static let shared = AdminCache()
    private let lock = NSLock()
    private var byServer: [ObjectIdentifier: AdminHandle] = [:]

    func get(serverID: ObjectIdentifier) -> AdminHandle? {
        lock.lock(); defer { lock.unlock() }
        return byServer[serverID]
    }

    func set(serverID: ObjectIdentifier, handle: AdminHandle) {
        lock.lock(); defer { lock.unlock() }
        byServer[serverID] = handle
    }
}
