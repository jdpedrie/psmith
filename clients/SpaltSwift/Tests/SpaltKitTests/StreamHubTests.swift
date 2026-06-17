import Foundation
import Testing
import Connect
@testable import SpaltKit
import SpaltKitTestHarness

/// Unit + integration coverage for `StreamHub`'s viewing / unseen
/// surface — the "new message" dot on the conversation list relies
/// on this state being correct under every combination of "was the
/// user looking?" + run purpose + status.
///
/// State-only tests construct the hub against a real (but unused)
/// `StreamSubscriber` so we don't hit the network. The terminal-driven
/// tests run a live `FakeProvider` send/compact through a VM so the
/// hub sees a real chunk + terminal cycle.
@Suite("StreamHub", .serialized)
@MainActor
struct StreamHubTests {
    let server: TestSpaltdServer

    init() throws {
        self.server = try TestSpaltdServer.shared()
    }

    /// Per-test isolated UserDefaults so persistence assertions don't
    /// observe state written by an earlier test in the same process.
    private func freshDefaults() -> UserDefaults {
        let name = "spalt.test.streamhub.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Build a StreamHub against a fresh login. Tests that don't need
    /// the network still use this because StreamSubscriber requires a
    /// live client; subscribe() is only triggered by `register` /
    /// `adopt`, so an unused hub instance is harmless.
    private func makeHub(defaults: UserDefaults) async throws -> (StreamHub, SpaltClient) {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "hub")
        return (StreamHub(subscriber: client.streams, defaults: defaults), client)
    }

    // MARK: - markViewing / markStoppedViewing / markSeen

    @Test
    func markViewing_addsToViewing_andClearsUnseen() async throws {
        let defaults = freshDefaults()
        defaults.set(["c-1"], forKey: "spalt.streamHub.unseenConversationIDs.v1")
        let (hub, _) = try await makeHub(defaults: defaults)
        // init() should hydrate from defaults.
        #expect(hub.unseenConversationIDs == ["c-1"])

        hub.markViewing(conversationID: "c-1")
        #expect(hub.viewingConversationIDs.contains("c-1"))
        #expect(!hub.unseenConversationIDs.contains("c-1"))
        let persisted = defaults.array(forKey: "spalt.streamHub.unseenConversationIDs.v1") as? [String] ?? []
        #expect(persisted.isEmpty)
    }

    @Test
    func markStoppedViewing_removesViewing_leavesUnseenAlone() async throws {
        let defaults = freshDefaults()
        let (hub, _) = try await makeHub(defaults: defaults)
        hub.markViewing(conversationID: "c-1")
        hub.markStoppedViewing(conversationID: "c-1")
        #expect(!hub.viewingConversationIDs.contains("c-1"))
        // Unseen was never set (markViewing cleared it before there was
        // anything to clear), so this is a property assertion: the
        // method is idempotent against the unseen set.
        #expect(!hub.unseenConversationIDs.contains("c-1"))
    }

    @Test
    func markSeen_clearsUnseen_withoutTouchingViewing() async throws {
        let defaults = freshDefaults()
        defaults.set(["c-1", "c-2"], forKey: "spalt.streamHub.unseenConversationIDs.v1")
        let (hub, _) = try await makeHub(defaults: defaults)
        #expect(hub.unseenConversationIDs == ["c-1", "c-2"])

        hub.markSeen(conversationID: "c-1")
        #expect(hub.unseenConversationIDs == ["c-2"])
        #expect(!hub.viewingConversationIDs.contains("c-1"))
        let persisted = Set(defaults.array(forKey: "spalt.streamHub.unseenConversationIDs.v1") as? [String] ?? [])
        #expect(persisted == ["c-2"])
    }

    @Test
    func reset_clearsAllUnseenAndViewing() async throws {
        let defaults = freshDefaults()
        defaults.set(["c-1"], forKey: "spalt.streamHub.unseenConversationIDs.v1")
        let (hub, _) = try await makeHub(defaults: defaults)
        hub.markViewing(conversationID: "c-other")

        hub.reset()
        #expect(hub.unseenConversationIDs.isEmpty)
        #expect(hub.viewingConversationIDs.isEmpty)
        let persisted = defaults.array(forKey: "spalt.streamHub.unseenConversationIDs.v1") as? [String] ?? []
        #expect(persisted.isEmpty)
    }

    // MARK: - Terminal-driven unseen marking (live stream)

    @Test
    func terminal_markUnseen_whenNotViewing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "huba")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "hi back")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let defaults = freshDefaults()
        let hub = StreamHub(subscriber: client.streams, defaults: defaults)
        let vm = ConversationViewModel(
            conversation: conv,
            client: client,
            hub: hub,
            onTerminal: { },
            localTitler: nil
        )
        // Do NOT mark viewing — simulating "user is on the chats list,
        // not inside this conversation."

        vm.draft = "hello"
        await vm.send()
        await waitFor(deadlineSeconds: 15.0) { vm.streamRunID == nil && !vm.sending }

        #expect(hub.unseenConversationIDs.contains(conv.id))
        let persisted = Set(defaults.array(forKey: "spalt.streamHub.unseenConversationIDs.v1") as? [String] ?? [])
        #expect(persisted.contains(conv.id))
    }

    @Test
    func terminal_doesNotMarkUnseen_whenViewing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "hubb")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "hi back")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let hub = StreamHub(subscriber: client.streams, defaults: freshDefaults())
        let vm = ConversationViewModel(
            conversation: conv,
            client: client,
            hub: hub,
            onTerminal: { },
            localTitler: nil
        )
        hub.markViewing(conversationID: conv.id)

        vm.draft = "hello"
        await vm.send()
        await waitFor(deadlineSeconds: 15.0) { vm.streamRunID == nil && !vm.sending }

        #expect(!hub.unseenConversationIDs.contains(conv.id))
    }

    @Test
    func terminal_doesNotMarkUnseen_forCompactionPurpose() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "hubc")
        let seeded = try await Fixtures.seedReadyToChat(
            client: client, replyText: "hi back", withCompression: true
        )
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let hub = StreamHub(subscriber: client.streams, defaults: freshDefaults())
        let vm = ConversationViewModel(
            conversation: conv,
            client: client,
            hub: hub,
            onTerminal: { },
            localTitler: nil
        )
        // Send a turn first so there's history to compact, mark viewing
        // throughout so the assistant turn doesn't taint the unseen
        // assertion. Then clear viewing + any unseen state and run a
        // pure compaction.
        hub.markViewing(conversationID: conv.id)
        vm.draft = "hello"
        await vm.send()
        await waitFor(deadlineSeconds: 15.0) { vm.streamRunID == nil && !vm.sending }
        hub.markStoppedViewing(conversationID: conv.id)
        hub.markSeen(conversationID: conv.id)

        await vm.compact()
        await waitFor(deadlineSeconds: 30.0) {
            !vm.isCompacting && vm.streamRunID == nil
        }

        #expect(!hub.unseenConversationIDs.contains(conv.id))
    }

    // MARK: - Helpers

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
}
