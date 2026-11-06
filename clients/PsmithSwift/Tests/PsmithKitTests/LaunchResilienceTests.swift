import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for launching and running while the active server is
/// unavailable, and for catching up when it returns.
///
/// The failure these pin: with the server down at launch, a signed-in
/// user with cached data landed in the onboarding wizard (the providers
/// list came from cache, the "any enabled model?" probe failed, and the
/// gate read that as "no models"), and nothing reloaded once the server
/// came back.
@Suite("LaunchResilience", .serialized)
@MainActor
struct LaunchResilienceTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    /// A client for `host` that shares `client`'s cache: the same device
    /// relaunched when the server is gone.
    private func client(at host: URL, sharingCacheOf client: PsmithClient) -> PsmithClient {
        PsmithClient(
            host: host,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState(),
            cache: client.cache
        )
    }

    private let closedPort = URL(string: "http://127.0.0.1:1")!

    private func waitFor(
        deadlineSeconds: Double = 10.0,
        _ predicate: @MainActor () -> Bool
    ) async {
        let limit = Date().addingTimeInterval(deadlineSeconds)
        while Date() < limit {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Onboarding gate

    @Test("needsOnboarding is true when the server reports no providers")
    func onboardingWithNoProviders() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-none")
        let vm = ProvidersViewModel(client: client)
        #expect(vm.needsOnboarding == false, "nothing is known before a load")
        await vm.load()
        #expect(vm.hasLoadedOnce)
        #expect(vm.needsOnboarding)
    }

    @Test("needsOnboarding is true for a provider with no enabled model, false once one exists")
    func onboardingTracksEnabledModels() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-models")
        let (_, fake) = try await Fixtures.seedFakeProvider(client: client, label: "Modeless")
        defer { fake.stop() }
        let vm = ProvidersViewModel(client: client)
        await vm.load()
        #expect(vm.needsOnboarding)

        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        await vm.load()
        #expect(vm.needsOnboarding == false)
    }

    @Test("an unreachable server at launch serves cached providers and never claims onboarding")
    func unreachableServerKeepsUserOutOfOnboarding() async throws {
        let (live, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-down", withCache: true)
        let seeded = try await Fixtures.seedReadyToChat(client: live)
        defer { seeded.fake.stop() }
        await ProvidersViewModel(client: live).load()  // populates the cache

        let dead = client(at: closedPort, sharingCacheOf: live)
        let vm = ProvidersViewModel(client: dead)
        let start = Date()
        await vm.load()
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(vm.hasLoadedOnce)
        #expect(vm.providers.map(\.id) == [seeded.provider.id], "cached list stands in")
        #expect(vm.error != nil)
        #expect(vm.needsOnboarding == false)
    }

    @Test("a server that never answers can't hold the onboarding verdict hostage")
    func hangingServerLoadIsBounded() async throws {
        let (live, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-hang", withCache: true)
        let seeded = try await Fixtures.seedReadyToChat(client: live)
        defer { seeded.fake.stop() }
        await ProvidersViewModel(client: live).load()

        let silent = SilentServer()
        try silent.start()
        defer { silent.stop() }
        let vm = ProvidersViewModel(client: client(at: silent.baseURL, sharingCacheOf: live))
        let start = Date()
        await vm.load()
        let elapsed = Date().timeIntervalSince(start)
        // The list's own 6s bound; the probe is skipped for a cached list.
        #expect(elapsed < 12, "load took \(elapsed)s")
        #expect(vm.hasLoadedOnce)
        #expect(!vm.providers.isEmpty)
        #expect(vm.needsOnboarding == false)
    }

    @Test("deleting the last provider returns the account to onboarding")
    func deletingLastProviderNeedsOnboarding() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-delete")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let vm = ProvidersViewModel(client: client)
        await vm.load()
        #expect(vm.needsOnboarding == false)
        await vm.selectProvider(seeded.provider.id)
        await vm.deleteSelected()
        #expect(vm.providers.isEmpty)
        #expect(vm.needsOnboarding)
    }

    // MARK: - Repository

    @Test("listFromServer never answers from cache; list falls back to it")
    func listFromServerIsAuthoritative() async throws {
        let (live, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-list", withCache: true)
        let seeded = try await Fixtures.seedReadyToChat(client: live)
        defer { seeded.fake.stop() }
        let fresh = try await live.modelProviders.listFromServer()
        #expect(fresh.map(\.id) == [seeded.provider.id])
        #expect(await live.modelProviders.cachedList()?.map(\.id) == [seeded.provider.id])

        let dead = client(at: closedPort, sharingCacheOf: live)
        await #expect(throws: (any Error).self) {
            _ = try await dead.modelProviders.listFromServer()
        }
        #expect(try await dead.modelProviders.list().map(\.id) == [seeded.provider.id])
    }

    @Test("get(timeout:) gives up on a server that never answers")
    func boundedGet() async throws {
        let silent = SilentServer()
        try silent.start()
        defer { silent.stop() }
        let client = PsmithClient(host: silent.baseURL, tokenStore: InMemoryTokenStore(), authState: AuthState())
        let start = Date()
        do {
            _ = try await client.modelProviders.get(id: UUID().uuidString, timeout: 0.5)
            Issue.record("expected a timeout")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .deadlineExceeded)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("selectProvider drops the previous provider's models when switching")
    func selectProviderClearsOnSwitch() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lr-select")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(seeded.provider.id)
        #expect(!vm.enabledModels.isEmpty)
        // A provider whose fetch fails: the old rows must not survive
        // under the new selection, where a tap would act on the wrong
        // provider.
        await vm.selectProvider(UUID().uuidString)
        #expect(vm.enabledModels.isEmpty)
    }

    // MARK: - Session restore

    @Test("restoreSession uses the cached identity when the server can't answer in time")
    func restoreFromCacheWhenServerHangs() async throws {
        let silent = SilentServer()
        try silent.start()
        defer { silent.stop() }
        let cache = try PsmithCache(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("psmith-lr-\(UUID().uuidString).sqlite"))
        let user = PsmithUser(id: UUID().uuidString, username: "cached", displayName: nil, isAdmin: false)
        try await cache.set(user, kind: CacheKind.currentUser, id: "me", capBytes: CachePreferences.capBytes)

        let auth = AuthState()
        let store = InMemoryTokenStore(initial: "token")
        let client = PsmithClient(host: silent.baseURL, tokenStore: store, authState: auth, cache: cache)
        let start = Date()
        let restored = await client.auth.restoreSession()
        let elapsed = Date().timeIntervalSince(start)
        #expect(restored?.id == user.id)
        #expect(auth.phase == .signedIn)
        #expect(elapsed < AuthRepository.uncachedTimeout, "waited \(elapsed)s")
        #expect(try store.load() == "token", "a timeout is not a rejection")
    }

    @Test("restoreSession still signs out a rejected token when a cached identity exists")
    func rejectedTokenBeatsCachedIdentity() async throws {
        let cache = try PsmithCache(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("psmith-lr-\(UUID().uuidString).sqlite"))
        let user = PsmithUser(id: UUID().uuidString, username: "cached", displayName: nil, isAdmin: false)
        try await cache.set(user, kind: CacheKind.currentUser, id: "me", capBytes: CachePreferences.capBytes)

        let auth = AuthState()
        let store = InMemoryTokenStore(initial: "not-a-real-token")
        let client = PsmithClient(host: server.baseURL, tokenStore: store, authState: auth, cache: cache)
        let restored = await client.auth.restoreSession()
        #expect(restored == nil)
        #expect(auth.phase != .signedIn)
        #expect(try store.load() == nil)
    }

    // MARK: - Reconnect

    @Test("onReconnected fires on offline-to-online only; onOnline on every flip online")
    func reconnectCallbackFiresOnRecovery() async throws {
        let health = FakeProvider()
        try health.start()
        defer { health.stop() }
        let monitor = ConnectivityMonitor(host: health.rootURL, pollInterval: 0.05, probeTimeout: 1)
        var onlineCount = 0
        var reconnectCount = 0
        monitor.onOnline { onlineCount += 1 }
        monitor.onReconnected { reconnectCount += 1 }
        monitor.start()
        defer { monitor.stop() }

        await waitFor { monitor.state == .online }
        #expect(onlineCount == 1)
        #expect(reconnectCount == 0, "the first probe of a session is not a reconnect")

        health.setHealthy(false)
        await waitFor { monitor.state == .offline }
        #expect(monitor.state == .offline)
        health.setHealthy(true)
        await waitFor { reconnectCount == 1 }
        #expect(reconnectCount == 1)
        #expect(onlineCount == 2)
    }

    @Test("reconcileAfterReconnect reloads providers and refreshes the list and open conversations")
    func reconcileReloads() async throws {
        let (token, client) = try await signedInUser(prefix: "lr-reconcile")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)

        let app = AppModel(host: server.baseURL, tokenStore: InMemoryTokenStore(initial: token))
        var listRefreshes = 0
        app.onConversationListChanged = { listRefreshes += 1 }
        var staleChecks = 0
        app.streamHub.markViewing(conversationID: conv.id)
        app.streamHub.attachChangeObserver(conversationID: conv.id) { @MainActor in staleChecks += 1 }

        await app.reconcileAfterReconnect()
        #expect(app.providers.hasLoadedOnce)
        #expect(app.providers.providers.map(\.id) == [seeded.provider.id])
        #expect(listRefreshes == 1)
        await waitFor { staleChecks == 1 }
        #expect(staleChecks == 1)
    }

    /// A new user, plus a raw session token for them and a client
    /// signed in with it.
    private func signedInUser(prefix: String) async throws -> (token: String, client: PsmithClient) {
        let admin = try await TestSession.adminHandle(server: server)
        let username = "\(prefix)-\(UUID().uuidString.prefix(8))".lowercased()
        let password = "p-\(UUID().uuidString.prefix(8))"
        var req = Psmith_V1_CreateUserRequest()
        req.username = username
        req.password = password
        let resp = await admin.rawAuthClient.createUser(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw PsmithError.from(err) }
        let store = InMemoryTokenStore()
        let client = PsmithClient(host: server.baseURL, tokenStore: store, authState: AuthState())
        _ = try await client.auth.login(username: username, password: password)
        return (try store.load() ?? "", client)
    }
}
