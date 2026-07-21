import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for the cross-client sync surface added 2026-07-21:
/// cache-first hydration (instant entry from the offline cache, then
/// network revalidation) and the staleness-checked refresh that
/// ConversationChanged account events / focus triggers run.
@Suite("SyncAndCache", .serialized)
@MainActor
struct SyncAndCacheTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private func waitFor(
        deadlineSeconds: Double = 10.0,
        _ predicate: @MainActor () -> Bool
    ) async {
        let limit = Date().addingTimeInterval(deadlineSeconds)
        while Date() < limit {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A profile WITH a system message, so fresh conversations seed a
    /// row and message-shaped assertions have something to bite on
    /// (the plain fixture profile creates empty conversations).
    private func seededProfile(
        client: PsmithClient,
        base: (fake: FakeProvider, provider: PsmithUserModelProvider, model: PsmithUserModel, profile: PsmithProfile)
    ) async throws -> PsmithProfile {
        var patch = PsmithProfilePatch(
            name: "Sync Seeded",
            defaultSettings: PsmithProfileDefaults(
                defaultProviderID: base.provider.id,
                defaultModelID: base.model.modelID
            )
        )
        patch.systemMessage = "You are a sync test."
        return try await client.profiles.create(patch)
    }

    @Test("repository cached reads round-trip after network calls")
    func cachedReadsRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "cache-repo", withCache: true
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seededProfile(client: client, base: seeded)
        let conv = try await client.conversations.create(profileID: profile.id)

        // Network calls populate the cache…
        _ = try await client.conversations.list(pageSize: 50)
        let (_, ctx) = try await client.conversations.get(id: conv.id)
        _ = try await client.conversations.listMessages(contextID: ctx.id)

        // …and the cached reads serve without the network.
        let cachedList = await client.conversations.cachedList()
        #expect(cachedList?.contains(where: { $0.id == conv.id }) == true)
        let cachedPair = await client.conversations.cachedGet(id: conv.id)
        #expect(cachedPair?.0.id == conv.id)
        #expect(cachedPair?.1.id == ctx.id)
        let cachedMsgs = await client.conversations.cachedMessages(contextID: ctx.id)
        #expect((cachedMsgs?.count ?? 0) > 0)
    }

    @Test("view model hydrates instantly from cache before any network load")
    func vmHydratesFromCache() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "cache-vm", withCache: true
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seededProfile(client: client, base: seeded)
        let conv = try await client.conversations.create(profileID: profile.id)

        // First VM loads over the network, which writes the cache.
        let vm1 = ConversationViewModel(
            conversation: conv, client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { }, localTitler: nil
        )
        await vm1.load()
        #expect(!vm1.messages.isEmpty)

        // Second VM (fresh entry) hydrates from cache alone.
        let vm2 = ConversationViewModel(
            conversation: conv, client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { }, localTitler: nil
        )
        await vm2.hydrateFromCache()
        #expect(vm2.messages.count == vm1.messages.count)
        #expect(vm2.activeContext?.id == vm1.activeContext?.id)
        #expect(vm2.hasLoadedFromServer == false)
    }

    @Test("hydrateFromCache never overwrites a completed network load")
    func hydrateDoesNotClobberNetworkLoad() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "cache-race", withCache: true
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seededProfile(client: client, base: seeded)
        let conv = try await client.conversations.create(profileID: profile.id)

        let vm = ConversationViewModel(
            conversation: conv, client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { }, localTitler: nil
        )
        await vm.load()
        let loaded = vm.messages.count
        await vm.hydrateFromCache()
        #expect(vm.messages.count == loaded)
        #expect(vm.hasLoadedFromServer)
    }

    @Test("refreshIfStale picks up an external edit via the mutation stamp")
    func refreshIfStaleDetectsExternalEdit() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "stale-edit", withCache: false
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seededProfile(client: client, base: seeded)
        let conv = try await client.conversations.create(profileID: profile.id)

        let vm = ConversationViewModel(
            conversation: conv, client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { }, localTitler: nil
        )
        await vm.load()
        guard let seedMsg = vm.messages.first else {
            Issue.record("expected a seed message")
            return
        }

        // "Another client" edits a message straight through the
        // repository — the VM has no idea. The server bumps the
        // conversation's coarse mutation stamp on edits precisely so
        // this check can see it (the leaf doesn't move).
        _ = try await client.conversations.editMessage(
            id: seedMsg.id, content: "externally edited content"
        )

        await vm.refreshIfStale()
        #expect(vm.messages.first?.content == "externally edited content")
    }

    @Test("refreshIfStale is quiet when nothing changed")
    func refreshIfStaleQuietWhenFresh() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "stale-noop", withCache: false
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seededProfile(client: client, base: seeded)
        let conv = try await client.conversations.create(profileID: profile.id)

        let vm = ConversationViewModel(
            conversation: conv, client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { }, localTitler: nil
        )
        await vm.load()
        let before = vm.messages.map(\.id)
        await vm.refreshIfStale()
        #expect(vm.messages.map(\.id) == before)
    }

    @Test("conversations model hydrates the list from cache")
    func conversationsModelHydratesFromCache() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "cache-list", withCache: true
        )
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        _ = try await client.conversations.create(profileID: seeded.profile.id)

        let m1 = ConversationsModel(client: client)
        await m1.refresh()
        #expect(!m1.conversations.isEmpty)

        let m2 = ConversationsModel(client: client)
        await m2.hydrateFromCache()
        #expect(m2.conversations.count == m1.conversations.count)
    }

    @Test("hub change observer routes to the registered handler")
    func hubChangeObserverRoutes() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "hub-route", withCache: false
        )
        let hub = StreamHub(subscriber: client.streams)
        var fired = 0
        hub.attachChangeObserver(conversationID: "conv-1") { fired += 1 }
        hub.notifyConversationChanged(conversationID: "conv-1")
        hub.notifyConversationChanged(conversationID: "conv-other")
        await waitFor { fired == 1 }
        #expect(fired == 1)
    }
}
