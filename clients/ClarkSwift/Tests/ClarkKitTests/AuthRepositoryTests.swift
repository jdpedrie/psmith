import Foundation
import Testing
import Connect
@testable import ClarkKit
import ClarkKitTestHarness

/// Layer 1 integration tests for AuthRepository against a real clarkd
/// subprocess. Covers tests #1–#10 from the testing plan.
///
/// Notes on plan drift:
///   * #2 ("login bad password") — plan says `InvalidArgument`, live server
///     returns `Unauthenticated`. We assert the live contract.
///   * #3 ("login unknown username") — same path: plan says
///     `InvalidArgument`, server returns `Unauthenticated` (the handler
///     deliberately collapses both cases to avoid leaking which one failed).
///   * #10 ("expired/invalid cookie clears keychain") — `restoreSession()`
///     today does NOT clear the token store on auth failure; it just
///     swallows the error and returns nil. We assert the actual behavior
///     and document the discrepancy. If/when the impl is updated to clear
///     the store, this test should flip.
@Suite("AuthRepository", .serialized)
struct AuthRepositoryTests {
    let server: TestClarkdServer

    init() throws {
        self.server = try TestClarkdServer.shared()
    }

    @Test("login happy path returns user, sets session")
    func loginHappyPath() async throws {
        // Create a fresh user via the bootstrap admin's CreateUser RPC,
        // then exercise the AuthRepository.login() path end-to-end.
        let username = "auth-happy-\(UUID().uuidString.prefix(6))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        try await createUser(username: username, password: password)

        let client = await TestSession.makeClient(server: server)
        let user = try await client.auth.login(username: username, password: password)

        #expect(user.username == username)
        #expect(user.isAdmin == false)

        // Indirect verification that the session token was persisted: a
        // subsequent authed RPC succeeds. The store itself is private to
        // the repository.
        let echoed = try await client.auth.whoAmI()
        #expect(echoed.id == user.id)
    }

    @Test("login with bad password fails Unauthenticated")
    func loginBadPassword() async throws {
        let username = "auth-bad-\(UUID().uuidString.prefix(6))".lowercased()
        try await createUser(username: username, password: "correct-pass")

        let client = await TestSession.makeClient(server: server)
        await #expect(throws: ClarkError.self) {
            _ = try await client.auth.login(username: username, password: "wrong-pass")
        }

        // Verify it surfaced the right code.
        do {
            _ = try await client.auth.login(username: username, password: "wrong-pass")
            Issue.record("expected login to throw")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .unauthenticated)
        }
    }

    @Test("whoAmI after login returns the same user")
    func whoAmIAfterLogin() async throws {
        let (client, user) = try await TestSession.freshUser(server: server, usernamePrefix: "auth-who")
        let echoed = try await client.auth.whoAmI()
        #expect(echoed.id == user.id)
        #expect(echoed.username == user.username)
    }

    @Test("whoAmI without session returns Unauthenticated")
    func whoAmIWithoutSession() async throws {
        let client = await TestSession.makeClient(server: server)
        do {
            _ = try await client.auth.whoAmI()
            Issue.record("expected whoAmI to throw")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .unauthenticated)
        }
    }

    @Test("logout clears session and subsequent whoAmI is Unauthenticated")
    func logoutClearsSession() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "auth-logout")
        try await client.auth.logout()

        // whoAmI now fails — server-side session was destroyed AND repo
        // cleared its token store.
        do {
            _ = try await client.auth.whoAmI()
            Issue.record("expected whoAmI to throw post-logout")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .unauthenticated)
        }
    }

    @Test("login with unknown username fails Unauthenticated")
    func loginUnknownUsername() async throws {
        // Plan says InvalidArgument; server returns Unauthenticated to avoid
        // distinguishing "no such user" from "wrong password" — see service.go.
        let client = await TestSession.makeClient(server: server)
        let bogus = "no-such-user-\(UUID().uuidString.prefix(8))".lowercased()
        do {
            _ = try await client.auth.login(username: bogus, password: "anything")
            Issue.record("expected login to throw")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .unauthenticated)
        }
    }

    @Test("login records clientLabel without error")
    func loginRecordsClientLabel() async throws {
        // The `client_label` column on `sessions` isn't exposed via any RPC,
        // so we can only verify the call succeeds when the label is set —
        // i.e. it round-trips through the proto and the server's CreateSession
        // happily accepts it. (Read-back would require admin SQL access we
        // don't provide on the wire.)
        let username = "auth-label-\(UUID().uuidString.prefix(6))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        try await createUser(username: username, password: password)

        let client = await TestSession.makeClient(server: server)
        let user = try await client.auth.login(
            username: username, password: password, clientLabel: "ClarkMac/integration-test"
        )
        #expect(user.username == username)

        // Sanity: subsequent whoAmI succeeds, proving the labelled session
        // is valid.
        let echoed = try await client.auth.whoAmI()
        #expect(echoed.id == user.id)
    }

    @Test("restoreSession with valid keychain entry returns the user")
    func restoreSessionValidEntry() async throws {
        // Step 1: log in via a "first" client, capturing the token that
        // landed in its store.
        let firstStore = InMemoryTokenStore()
        let firstClient = await TestSession.makeClient(server: server, tokenStore: firstStore)
        let username = "auth-restore-\(UUID().uuidString.prefix(6))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        try await createUser(username: username, password: password)
        let first = try await firstClient.auth.login(username: username, password: password)
        let token = try firstStore.load()
        #expect(token != nil && !(token ?? "").isEmpty)

        // Step 2: simulate "app relaunch" — fresh client, same store.
        // restoreSession() reads the token, calls whoAmI, returns the user.
        let secondStore = InMemoryTokenStore(initial: token)
        let secondClient = await TestSession.makeClient(server: server, tokenStore: secondStore)
        let restored = await secondClient.auth.restoreSession()
        #expect(restored?.id == first.id)
        #expect(restored?.username == username)
    }

    @Test("restoreSession with no keychain entry returns nil")
    func restoreSessionNoEntry() async throws {
        let store = InMemoryTokenStore() // no token
        let client = await TestSession.makeClient(server: server, tokenStore: store)
        let restored = await client.auth.restoreSession()
        #expect(restored == nil)
    }

    @Test("restoreSession with invalid token clears the token store")
    func restoreSessionInvalidToken() async throws {
        // restoreSession() must clear the keychain on auth-class failures
        // (Unauthenticated / PermissionDenied) so subsequent launches don't
        // repeat the dead-token round-trip and force the user through Login
        // exactly once. Transient transport failures keep the token so
        // network blips don't sign the user out.
        let store = InMemoryTokenStore(initial: "definitely-not-a-real-token")
        let client = await TestSession.makeClient(server: server, tokenStore: store)
        let restored = await client.auth.restoreSession()
        #expect(restored == nil)

        let after = try store.load()
        #expect(after == nil)
    }

    // MARK: - Helpers

    private func createUser(username: String, password: String) async throws {
        let admin = try await TestSession.adminHandle(server: server)
        var req = Clark_V1_CreateUserRequest()
        req.username = username
        req.password = password
        req.isAdmin = false
        let resp = await admin.rawAuthClient.createUser(request: req, headers: [:])
        if resp.message == nil, let err = resp.error {
            throw ClarkError.from(err)
        }
    }

    // MARK: - probe()

    @Test("probe against the running clarkd succeeds")
    func probeSuccess() async throws {
        let result = await probeClarkServer(url: server.baseURL)
        switch result {
        case .ok(let serverName, _):
            #expect(serverName == "clarkd")
        case .wrongServer(let detail):
            Issue.record("expected ok; got wrongServer: \(detail)")
        case .unreachable(let detail):
            Issue.record("expected ok; got unreachable: \(detail)")
        }
    }

    @Test("probe against an unreachable URL doesn't return .ok")
    func probeUnreachable() async throws {
        // Reserved port that nothing listens on.
        guard let url = URL(string: "http://127.0.0.1:1") else {
            Issue.record("URL build"); return
        }
        let result = await probeClarkServer(url: url)
        if case .ok = result {
            Issue.record("expected non-ok, got ok")
        }
        // Either .unreachable or .wrongServer is acceptable —
        // different network stacks classify "connection refused"
        // differently. The contract is "doesn't return .ok."
    }
}
