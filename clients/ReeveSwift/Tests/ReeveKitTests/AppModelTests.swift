import Foundation
import Testing
import Connect
@testable import ReeveKit
import ReeveKitTestHarness

/// Layer 1 behavior tests for AppModel. The testing-plan tables describe
/// `bootstrap` as "loads providers + profiles in parallel" and "surfaces
/// error from either" — the production code (see AppModel.bootstrap) only
/// calls `client.auth.restoreSession()`. The providers/profiles VMs are
/// constructed eagerly in `init` but populated lazily by their own `load()`
/// methods. Tests below assert the REAL behavior with inline drift notes.
@Suite("AppModel", .serialized)
@MainActor
struct AppModelTests {
    let server: TestReevedServer

    init() throws {
        self.server = try TestReevedServer.shared()
    }

    // MARK: - bootstrap (3 cases)

    /// Plan #1: "bootstrap loads providers + profiles in parallel".
    /// DRIFT: AppModel.bootstrap() only restores the session. The providers /
    /// profiles VMs are constructed eagerly but their `load()` methods are
    /// invoked separately by the host app. We assert the actual contract:
    /// after bootstrap on a stored token, the AppModel's authState reflects
    /// the user, and providers/profiles VMs are wired and ready to load.
    @Test("bootstrap restores stored session and wires sub-VMs")
    func bootstrapRestoresSession() async throws {
        // Register a user, capture the session token, then build a fresh
        // AppModel pointed at the same server with a token store pre-loaded
        // with that token — AppModel.bootstrap() should restore the session.
        let admin = try await TestSession.adminHandle(server: server)
        let username = "appmodel-bootstrap-\(UUID().uuidString.prefix(6))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        var req = Reeve_V1_CreateUserRequest()
        req.username = username
        req.password = password
        let createResp = await admin.rawAuthClient.createUser(request: req, headers: [:])
        if createResp.message == nil, let err = createResp.error {
            throw ReeveError.from(err)
        }

        // Log in via a sacrificial client just to mint a session token.
        let loginClient = await TestSession.makeClient(server: server)
        _ = try await loginClient.auth.login(username: username, password: password)
        // Pull token out of the same store that login wrote into. We don't
        // expose a direct reader for tokenStore on ReeveClient, so seed a
        // fresh AppModel with a brand-new InMemoryTokenStore preloaded with
        // a freshly-minted token from a parallel login.
        let token = try await mintSessionToken(server: server, username: username, password: password)

        let store = InMemoryTokenStore(initial: token)
        let app = AppModel(host: server.baseURL, tokenStore: store, authState: AuthState())

        // Sub-VMs constructed eagerly — both lists start empty until their
        // own load() call.
        #expect(app.providers.providers.isEmpty)
        #expect(app.profiles.profiles.isEmpty)

        await app.bootstrap()
        // Bootstrap restored the session: authState now has the user.
        #expect(app.authState.currentUser?.username == username)
        #expect(app.authState.isAuthenticated)
    }

    /// Plan #2: "bootstrap surfaces error from either".
    /// DRIFT: AppModel.bootstrap() swallows errors from restoreSession (it
    /// returns nil rather than throwing). We assert the real contract: a
    /// token that no longer maps to a session leaves authState unauthenticated
    /// without crashing.
    @Test("bootstrap with bogus token leaves authState unauthenticated")
    func bootstrapWithBogusTokenIsUnauthenticated() async throws {
        let store = InMemoryTokenStore(initial: "deadbeef-not-a-real-token")
        let app = AppModel(host: server.baseURL, tokenStore: store, authState: AuthState())
        await app.bootstrap()
        #expect(app.authState.currentUser == nil)
        #expect(!app.authState.isAuthenticated)
    }

    /// Plan #3: "bootstrap idempotent on repeat call".
    /// Calling bootstrap a second time should produce the same authState.
    @Test("bootstrap is idempotent across repeat calls")
    func bootstrapIdempotent() async throws {
        let admin = try await TestSession.adminHandle(server: server)
        let username = "appmodel-idem-\(UUID().uuidString.prefix(6))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        var req = Reeve_V1_CreateUserRequest()
        req.username = username
        req.password = password
        let createResp = await admin.rawAuthClient.createUser(request: req, headers: [:])
        if createResp.message == nil, let err = createResp.error {
            throw ReeveError.from(err)
        }

        let token = try await mintSessionToken(server: server, username: username, password: password)
        let store = InMemoryTokenStore(initial: token)
        let app = AppModel(host: server.baseURL, tokenStore: store, authState: AuthState())

        await app.bootstrap()
        let firstUserID = app.authState.currentUser?.id
        #expect(firstUserID != nil)

        await app.bootstrap()
        #expect(app.authState.currentUser?.id == firstUserID)
        #expect(app.authState.isAuthenticated)
    }

    // MARK: - Helpers

    private func mintSessionToken(server: TestReevedServer, username: String, password: String) async throws -> String {
        // Log in directly via a raw, unauthenticated AuthService client to
        // get a session token we can hand to the AppModel under test.
        let client = await TestSession.makeClient(server: server)
        _ = try await client.auth.login(username: username, password: password)
        // The login() call wrote the session token into client's token store.
        // We don't expose a reader, so do a *second* login and capture via
        // raw RPC instead. Using a fresh client per call avoids any cross-
        // contamination. Cheap.
        return try await rawLoginToken(server: server, username: username, password: password)
    }

    private func rawLoginToken(server: TestReevedServer, username: String, password: String) async throws -> String {
        // Mirror TestSession.adminHandle's "login via raw client" pattern.
        let config = ProtocolClientConfig(
            host: server.baseURL.absoluteString,
            networkProtocol: .connect,
            codec: ProtoCodec()
        )
        let proto = ProtocolClient(httpClient: URLSessionHTTPClient(), config: config)
        let raw = Reeve_V1_AuthServiceClient(client: proto)
        var req = Reeve_V1_LoginRequest()
        req.username = username
        req.password = password
        let resp = await raw.login(request: req, headers: [:])
        guard let msg = resp.message else {
            throw ReeveError.from(resp.error ?? ConnectError(code: .unknown, message: "login failed"))
        }
        return msg.sessionToken
    }
}
