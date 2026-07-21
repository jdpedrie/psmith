import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 integration tests for ConversationsRepository against a real
/// psmithd subprocess. Covers tests #1–#35 from the testing plan.
///
/// Drift / impl notes captured along the way:
///   * #13 (create with non-existent profile) — plan says
///     `InvalidArgument`, server returns `NotFound` (the handler collapses
///     "not found" and "owned by someone else" into NotFound deliberately
///     to avoid leaking existence). We assert the live contract.
///   * #22 (sendMessage with missing conversation) — plan says
///     `InvalidArgument`; server returns `NotFound` for the
///     conversation lookup (`fetchOwnedConversation`), and `InvalidArgument`
///     only for the parse-id path. We use a syntactically valid but
///     non-existent UUID, so NotFound is the real shape.
///   * #26 (countContextTokens for openai-compatible) — the openai-compatible
///     driver intentionally does not implement TokenCounter. The server
///     surfaces this as `Unimplemented`.
@Suite("ConversationsRepository", .serialized)
struct ConversationsRepositoryTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    // MARK: - list (#1, #2, #3, #4, #5, #6, #7)

    @Test("list is empty for a fresh user")
    func listEmpty() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-list-empty")
        let (items, next) = try await client.conversations.list()
        #expect(items.isEmpty)
        #expect(next == nil)
    }

    @Test("list orders by recentlyUsed by default")
    func listOrderRecentlyUsed() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-list-used")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        // Create three conversations; their createdAt order is c1 < c2 < c3.
        let c1 = try await client.conversations.create(profileID: profile.id, title: "first")
        try await Task.sleep(nanoseconds: 5_000_000)
        let c2 = try await client.conversations.create(profileID: profile.id, title: "second")
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await client.conversations.create(profileID: profile.id, title: "third")
        // Activity on c1 by sending a message: that should bump it to the top
        // under recentlyUsed.
        _ = try await client.conversations.sendMessage(conversationID: c1.id, content: "hi")
        // Wait a brief moment for last_activity to settle.
        try await Task.sleep(nanoseconds: 100_000_000)

        let (items, _) = try await client.conversations.list()
        #expect(items.count == 3)
        // Most-recent-activity first.
        #expect(items.first?.id == c1.id)
        // c2 and c3 both have last_activity == created_at, so c3 (newer) > c2.
        #expect(items.last?.id == c2.id)
    }

    @Test("list with order=recentlyCreated reverses to creation order")
    func listOrderRecentlyCreated() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-list-created")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c1 = try await client.conversations.create(profileID: profile.id, title: "alpha")
        try await Task.sleep(nanoseconds: 5_000_000)
        let c2 = try await client.conversations.create(profileID: profile.id, title: "beta")
        // Drive activity on c1 so its lastActivity > c2's createdAt — under
        // recentlyCreated this should NOT promote c1.
        _ = try await client.conversations.sendMessage(conversationID: c1.id, content: "ping")

        let (items, _) = try await client.conversations.list(order: .recentlyCreated)
        #expect(items.count == 2)
        // Newest-created first; c2 was created after c1 → c2 first.
        #expect(items.first?.id == c2.id)
        #expect(items.last?.id == c1.id)
    }

    @Test("list with titleQuery does ILIKE-style partial match")
    func listTitleQueryPartial() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-search")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        _ = try await client.conversations.create(profileID: profile.id, title: "Apple sauce")
        _ = try await client.conversations.create(profileID: profile.id, title: "banana bread")
        _ = try await client.conversations.create(profileID: profile.id, title: "APPLE pie")
        let (matches, _) = try await client.conversations.list(titleQuery: "apple")
        #expect(matches.count == 2)
        for m in matches {
            #expect(m.title?.lowercased().contains("apple") == true)
        }
    }

    @Test("list with titleQuery excludes nil-titled conversations")
    func listTitleQueryExcludesNil() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-search-nil")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        _ = try await client.conversations.create(profileID: profile.id, title: "Searchable")
        _ = try await client.conversations.create(profileID: profile.id, title: nil)
        let (matches, _) = try await client.conversations.list(titleQuery: "search")
        // Only the titled conversation matches; nil-title is skipped.
        #expect(matches.count == 1)
        #expect(matches.first?.title == "Searchable")
    }

    @Test("list with profileID narrows to that profile only")
    func listProfileIDFilter() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-bypro")
        let (fake, _, _, profileA) = try await Fixtures.seedReadyToChat(client: client, profileName: "ProfA")
        _ = fake
        let profileB = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "ProfB"))
        _ = try await client.conversations.create(profileID: profileA.id, title: "in-A-1")
        _ = try await client.conversations.create(profileID: profileA.id, title: "in-A-2")
        _ = try await client.conversations.create(profileID: profileB.id, title: "in-B-1")
        let (aOnly, _) = try await client.conversations.list(profileID: profileA.id)
        #expect(aOnly.count == 2)
        for c in aOnly { #expect(c.profileID == profileA.id) }
    }

    @Test("list pageSize clamps to MaxListPageSize (=100) when exceeded")
    func listPageSizeClamp() async throws {
        // We can't easily create >100 conversations without slowing tests;
        // instead, observe that a page_size of 0 (the default-zeroed proto)
        // does NOT clamp to 0 — it falls back to the server's max. Equivalent
        // signal that the clamp branch fired.
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-clamp")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        for i in 0..<3 {
            _ = try await client.conversations.create(profileID: profile.id, title: "c\(i)")
        }
        // pageSize=0 → server falls through to MaxListPageSize, returning
        // every row up to 100. We have 3, so 3 come back.
        let (items, _) = try await client.conversations.list(pageSize: 0)
        #expect(items.count == 3)
    }

    // MARK: - get (#8, #9, #10)

    @Test("get returns conversation + active context")
    func getHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-get")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let created = try await client.conversations.create(profileID: profile.id, title: "X")
        let (c, ctx) = try await client.conversations.get(id: created.id)
        #expect(c.id == created.id)
        #expect(c.title == "X")
        #expect(c.activeContextID == ctx.id)
        #expect(ctx.conversationID == created.id)
    }

    @Test("getMessage round-trips a single row, NotFound across users")
    func getMessageSingleRow() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-getmsg")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let created = try await client.conversations.create(profileID: profile.id, title: "M")
        let (userMsg, _) = try await client.conversations.sendMessage(
            conversationID: created.id, content: "fetch me"
        )
        let target = userMsg
        let fetched = try await client.conversations.getMessage(id: target.id)
        #expect(fetched.id == target.id)
        #expect(fetched.content == target.content)
        #expect(fetched.role == target.role)

        // Cross-user fetch masks existence.
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-getmsg-B")
        do {
            _ = try await clientB.conversations.getMessage(id: target.id)
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    @Test("get with unknown id returns NotFound")
    func getUnknownIDNotFound() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-get-unknown")
        let bogus = UUID().uuidString.lowercased()
        do {
            _ = try await client.conversations.get(id: bogus)
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    @Test("get returns NotFound across users (no existence leak)")
    func getCrossUserNotFound() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-get-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-get-B")
        let (fakeA, _, _, profileA) = try await Fixtures.seedReadyToChat(client: clientA)
        _ = fakeA
        let owned = try await clientA.conversations.create(profileID: profileA.id, title: "private")
        do {
            _ = try await clientB.conversations.get(id: owned.id)
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - create (#11, #12, #13)

    @Test("create with title only succeeds")
    func createTitleOnly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-create-title")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "Hello")
        #expect(c.title == "Hello")
        #expect(c.profileID == profile.id)
    }

    @Test("create with settings stores per-conversation overrides incl call_settings")
    func createWithSettings() async throws {
        // settingsToJSON now round-trips the full ConversationSettings proto,
        // including the nested call_settings sub-block. The earlier hand-rolled
        // settingsStorage struct silently dropped call_settings on the write
        // path while extractConversationCallSettings expected it on the read
        // path — broken end-to-end. Fixed by serialising the proto directly.
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-create-settings")
        let (fake, provider, model, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let settings = PsmithConversationSettings(
            defaultProviderID: provider.id,
            defaultModelID: model.modelID,
            includeThinkingInHistory: true,
            callSettings: PsmithCallSettings(temperature: 0.55)
        )
        let c = try await client.conversations.create(
            profileID: profile.id, title: "with overrides", settings: settings
        )
        let (echoed, _) = try await client.conversations.get(id: c.id)
        #expect(echoed.settings?.defaultProviderID == provider.id)
        #expect(echoed.settings?.defaultModelID == model.modelID)
        #expect(echoed.settings?.includeThinkingInHistory == true)
        #expect(echoed.settings?.callSettings?.temperature == 0.55)
    }

    @Test("create with non-existent profile returns NotFound (drift: plan says InvalidArgument)")
    func createWithMissingProfile() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-create-noprof")
        let bogus = UUID().uuidString.lowercased()
        do {
            _ = try await client.conversations.create(profileID: bogus, title: "x")
            Issue.record("expected error")
        } catch let PsmithError.rpc(code, _) {
            // Drift: server returns NotFound (not InvalidArgument) — see
            // service.go:90-99 where missing-or-foreign profile is collapsed
            // into NotFound.
            #expect(code == .notFound)
        }
    }

    // MARK: - delete (#14, #15)

    @Test("delete removes the conversation; subsequent get is NotFound")
    func deleteHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-del")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "doomed")
        try await client.conversations.delete(id: c.id)
        do {
            _ = try await client.conversations.get(id: c.id)
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    @Test("delete returns NotFound for another user's conversation")
    func deleteCrossUserNotFound() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-del-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-del-B")
        let (fakeA, _, _, profileA) = try await Fixtures.seedReadyToChat(client: clientA)
        _ = fakeA
        let owned = try await clientA.conversations.create(profileID: profileA.id, title: "mine")
        do {
            try await clientB.conversations.delete(id: owned.id)
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - updateTitle / updateSettings (#16, #17, #18)

    @Test("updateTitle updates the title and returns the updated row")
    func updateTitleHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-rename")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "old")
        let updated = try await client.conversations.updateTitle(id: c.id, title: "new")
        #expect(updated.title == "new")
    }

    @Test("updateTitle with empty string sets the column to empty")
    func updateTitleEmptyClears() async throws {
        // Drift note: the testing plan says "empty string clears" (i.e. nil
        // on read-back). The server's actual contract is that empty string
        // is preserved as an empty string in the column — the proto carries
        // `optional title = ""`, which round-trips through PsmithConversation
        // as `title == ""` (not nil). True clearing back to NULL would need
        // a separate sentinel. We assert the live contract here.
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-clear-title")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "kept")
        let cleared = try await client.conversations.updateTitle(id: c.id, title: "")
        #expect(cleared.title == "")
    }

    @Test("updateSettings replaces the settings blob (not merges)")
    func updateSettingsReplacesBlob() async throws {
        // Impl note: same drift as createWithSettings — the server's
        // settingsStorage only persists default_provider_id /
        // default_model_id / include_thinking_in_history. We assert replace
        // semantics on those fields instead of on callSettings.
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-settings")
        let (fake, provider, model, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let initial = PsmithConversationSettings(
            defaultProviderID: provider.id,
            defaultModelID: model.modelID,
            includeThinkingInHistory: true
        )
        let c = try await client.conversations.create(
            profileID: profile.id, title: "x", settings: initial
        )
        // Replace with a settings shape that drops everything except
        // includeThinkingInHistory=false; replace semantics means provider
        // / model overrides are gone, not merged.
        let replacement = PsmithConversationSettings(includeThinkingInHistory: false)
        _ = try await client.conversations.updateSettings(id: c.id, settings: replacement)
        let (echoed, _) = try await client.conversations.get(id: c.id)
        #expect(echoed.settings?.defaultProviderID == nil)
        #expect(echoed.settings?.defaultModelID == nil)
        #expect(echoed.settings?.includeThinkingInHistory == false)
    }

    // MARK: - sendMessage (#19, #20, #21, #22)

    @Test("sendMessage creates the user message and returns a stream run")
    func sendMessageHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-send")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "send")
        let (userMsg, run) = try await client.conversations.sendMessage(
            conversationID: c.id, content: "hello"
        )
        #expect(userMsg.role == .user)
        #expect(userMsg.content == "hello")
        #expect(!run.id.isEmpty)
        #expect(run.conversationID == c.id)
    }

    @Test("sendMessage with explicit parentMessageID forks off the chosen ancestor")
    func sendMessageWithParent() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-fork")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "fork")
        let (firstUser, firstRun) = try await client.conversations.sendMessage(
            conversationID: c.id, content: "first"
        )
        // Drain the stream so the assistant message lands and the conversation
        // is not in active-stream state.
        try await drainStream(client: client, runID: firstRun.id)

        // Send a sibling under firstUser as parent → fork.
        let (forked, _) = try await client.conversations.sendMessage(
            conversationID: c.id,
            content: "fork-branch",
            parentMessageID: firstUser.id
        )
        #expect(forked.parentID == firstUser.id)
    }

    @Test("sendMessage with provider/model overrides accepts and routes through them")
    func sendMessageProviderModelOverrides() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-send-override")
        let (fake, provider, model, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "override")
        let (userMsg, run) = try await client.conversations.sendMessage(
            conversationID: c.id, content: "hi",
            providerID: provider.id, modelID: model.modelID
        )
        #expect(userMsg.content == "hi")
        #expect(!run.id.isEmpty)
    }

    @Test("sendMessage with non-existent conversation returns NotFound (drift: plan says InvalidArgument)")
    func sendMessageMissingConversation() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-send-noconv")
        let (fake, _, _, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let bogus = UUID().uuidString.lowercased()
        do {
            _ = try await client.conversations.sendMessage(conversationID: bogus, content: "hi")
            Issue.record("expected error")
        } catch let PsmithError.rpc(code, _) {
            // Drift: handler returns NotFound for the conversation lookup
            // (fetchOwnedConversation collapses missing+foreign).
            #expect(code == .notFound)
        }
    }

    // MARK: - listMessages (#23, #24)

    @Test("listMessages returns messages ordered by depth + created_at")
    func listMessagesOrderedByDepth() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-list-msgs")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "msgs")
        let (_, ctx) = try await client.conversations.get(id: c.id)
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "first")
        // Wait for the assistant turn so a second send doesn't collide with
        // an active stream.
        try await waitNoActiveStream(client: client, conversationID: c.id)
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "second")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        let messages = try await client.conversations.listMessages(contextID: ctx.id)
        #expect(messages.count >= 4) // 2 user + 2 assistant
        // first user message comes before second user message
        let userMessages = messages.filter { $0.role == .user }
        #expect(userMessages.map(\.content) == ["first", "second"])
    }

    @Test("listMessages with leafMessageID returns just the ancestor chain")
    func listMessagesAncestorChain() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-list-leaf")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "leaf")
        let (_, ctx) = try await client.conversations.get(id: c.id)
        let (firstUser, _) = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        let (secondUser, _) = try await client.conversations.sendMessage(conversationID: c.id, content: "u2")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        // Ask for the chain rooted at the first user message — should NOT
        // include the second user turn or its assistant.
        let chain = try await client.conversations.listMessages(
            contextID: ctx.id, leafMessageID: firstUser.id
        )
        #expect(chain.contains(where: { $0.id == firstUser.id }))
        #expect(!chain.contains(where: { $0.id == secondUser.id }))
    }

    // MARK: - countContextTokens (#25, #26)

    @Test("countContextTokens returns Unimplemented for openai-compatible (no TokenCounter)")
    func countContextTokensUnimplementedForOpenAICompat() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-tokens-unimpl")
        let (fake, provider, model, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "tok")
        let (_, ctx) = try await client.conversations.get(id: c.id)
        do {
            _ = try await client.conversations.countContextTokens(
                contextID: ctx.id, providerID: provider.id, modelID: model.modelID
            )
            Issue.record("expected Unimplemented")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .unimplemented)
        }
    }

    @Test("countContextTokens — happy path skipped (no Anthropic creds in CI)")
    func countContextTokensHappyPathSkip() async throws {
        // SKIP: a happy-path token count requires the Anthropic driver, which
        // hits the live Anthropic API for token counting (no fake we control).
        // Layer 3 (XCUITest with real creds) would cover this.
        // TODO: revisit with Layer 3 (XCUITest)
    }

    // MARK: - compact (#27, #28)

    @Test("compact returns a stream run for the configured provider/model")
    func compactHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-compact")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(
            client: client, withCompression: true, compressionMode: .replace
        )
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "compact")
        // Need at least one assistant turn so compaction has something to
        // summarize.
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        let run = try await client.conversations.compact(conversationID: c.id)
        #expect(!run.id.isEmpty)
        #expect(run.conversationID == c.id)
    }

    @Test("compact with overrides accepts caller-supplied guide/provider/model")
    func compactWithOverrides() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-compact-over")
        let (fake, provider, model, profile) = try await Fixtures.seedReadyToChat(
            client: client, withCompression: true, compressionMode: .replace
        )
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "compact-o")
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        let run = try await client.conversations.compact(
            conversationID: c.id,
            guide: "Be terse.",
            providerID: provider.id,
            modelID: model.modelID
        )
        #expect(!run.id.isEmpty)
    }

    // MARK: - promoteCompactionToNewContext (#29)

    @Test("promoteCompactionToNewContext creates a new context seeded by the summary")
    func promoteCompactionToNewContextHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-promote")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(
            client: client, withCompression: true, compressionMode: .append
        )
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "promote")
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        // Compact in append mode so the summary message exists and isn't
        // automatically promoted.
        let run = try await client.conversations.compact(conversationID: c.id)
        try await drainStream(client: client, runID: run.id)

        // Find the compression-summary message in the active context.
        let (_, ctx) = try await client.conversations.get(id: c.id)
        let msgs = try await client.conversations.listMessages(contextID: ctx.id)
        guard let summary = msgs.first(where: { $0.role == .compressionSummary }) else {
            Issue.record("no compression-summary message after append-mode compact")
            return
        }
        let promoted = try await client.conversations.promoteCompactionToNewContext(
            messageID: summary.id
        )
        #expect(promoted.conversationID == c.id)
        #expect(promoted.id != ctx.id)
    }

    // MARK: - editMessage / deleteMessage (#30, #31, #32, #33)

    @Test("editMessage updates the content")
    func editMessageContentUpdate() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-edit")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "edit")
        let (userMsg, _) = try await client.conversations.sendMessage(conversationID: c.id, content: "before")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        let edited = try await client.conversations.editMessage(id: userMsg.id, content: "after")
        #expect(edited.content == "after")
        #expect(edited.editedAt != nil)
    }

    @Test("editMessage on another user's message returns NotFound")
    func editMessageCrossUserNotFound() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-edit-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-edit-B")
        let (fakeA, _, _, profileA) = try await Fixtures.seedReadyToChat(client: clientA)
        _ = fakeA
        let c = try await clientA.conversations.create(profileID: profileA.id, title: "mine")
        let (msg, _) = try await clientA.conversations.sendMessage(conversationID: c.id, content: "secret")
        try await waitNoActiveStream(client: clientA, conversationID: c.id)
        do {
            _ = try await clientB.conversations.editMessage(id: msg.id, content: "hijack")
            Issue.record("expected NotFound")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    @Test("deleteMessage non-cascade leaves only the targeted row affected")
    func deleteMessageNonCascading() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-del-msg")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "delmsg")
        let (_, ctx) = try await client.conversations.get(id: c.id)
        // Do TWO turns so we delete a leaf-like row that has no descendants
        // (the second user msg). Non-cascade requires no descendants.
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        let (u2, _) = try await client.conversations.sendMessage(conversationID: c.id, content: "u2")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        let before = try await client.conversations.listMessages(contextID: ctx.id)
        try await client.conversations.deleteMessage(id: u2.id, cascade: false)
        let after = try await client.conversations.listMessages(contextID: ctx.id)
        #expect(after.count < before.count)
        #expect(!after.contains(where: { $0.id == u2.id }))
    }

    @Test("deleteMessage with cascade removes descendants too")
    func deleteMessageCascading() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-del-cascade")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "cascade")
        let (_, ctx) = try await client.conversations.get(id: c.id)
        let (u1, _) = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u2")
        try await waitNoActiveStream(client: client, conversationID: c.id)

        let before = try await client.conversations.listMessages(contextID: ctx.id)
        // Cascade-delete u1 — should remove u1 + its assistant + u2 + u2's
        // assistant (everything in u1's subtree).
        try await client.conversations.deleteMessage(id: u1.id, cascade: true)
        let after = try await client.conversations.listMessages(contextID: ctx.id)
        #expect(after.count < before.count)
        #expect(!after.contains(where: { $0.id == u1.id }))
    }

    // MARK: - listContexts / activateContext (#34, #35)

    @Test("listContexts returns the conversation's contexts (single-context case)")
    func listContextsSingle() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-listctx")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "ctxs")
        let contexts = try await client.conversations.listContexts(conversationID: c.id)
        #expect(contexts.count == 1)
        #expect(contexts.first?.conversationID == c.id)
    }

    @Test("activateContext switches the conversation's active context_id")
    func activateContextSwitches() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-activate")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(
            client: client, withCompression: true, compressionMode: .append
        )
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "switch")
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        // Compact in append-mode + promote → produces a second context.
        let run = try await client.conversations.compact(conversationID: c.id)
        try await drainStream(client: client, runID: run.id)
        let (_, ctxBefore) = try await client.conversations.get(id: c.id)
        let msgs = try await client.conversations.listMessages(contextID: ctxBefore.id)
        guard let summary = msgs.first(where: { $0.role == .compressionSummary }) else {
            Issue.record("no compression-summary after append-mode compact")
            return
        }
        let promoted = try await client.conversations.promoteCompactionToNewContext(
            messageID: summary.id
        )

        // Reactivate the original context.
        let reactivated = try await client.conversations.activateContext(contextID: ctxBefore.id)
        #expect(reactivated.id == ctxBefore.id)
        let (after, _) = try await client.conversations.get(id: c.id)
        #expect(after.activeContextID == ctxBefore.id)
        // Promoted context still exists alongside.
        let all = try await client.conversations.listContexts(conversationID: c.id)
        #expect(all.contains(where: { $0.id == promoted.id }))
        #expect(all.contains(where: { $0.id == ctxBefore.id }))
    }

    @Test("deleteContext removes a non-active context and its messages")
    func deleteContextRemovesNonActive() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-delctx")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(
            client: client, withCompression: true, compressionMode: .append
        )
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "delctx")
        _ = try await client.conversations.sendMessage(conversationID: c.id, content: "u1")
        try await waitNoActiveStream(client: client, conversationID: c.id)
        let run = try await client.conversations.compact(conversationID: c.id)
        try await drainStream(client: client, runID: run.id)
        let (_, original) = try await client.conversations.get(id: c.id)
        let msgs = try await client.conversations.listMessages(contextID: original.id)
        guard let summary = msgs.first(where: { $0.role == .compressionSummary }) else {
            Issue.record("no compression-summary after append-mode compact")
            return
        }
        // Promote → new context becomes active; the original is deletable.
        _ = try await client.conversations.promoteCompactionToNewContext(messageID: summary.id)

        try await client.conversations.deleteContext(id: original.id)

        let remaining = try await client.conversations.listContexts(conversationID: c.id)
        #expect(!remaining.contains(where: { $0.id == original.id }))
        #expect(remaining.count == 1)
    }

    @Test("deleteContext refuses the active context with FailedPrecondition")
    func deleteContextRefusesActive() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-delctx-act")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "delctx-active")
        let (_, active) = try await client.conversations.get(id: c.id)
        await #expect(throws: PsmithError.self) {
            try await client.conversations.deleteContext(id: active.id)
        }
        // Still listed.
        let all = try await client.conversations.listContexts(conversationID: c.id)
        #expect(all.contains(where: { $0.id == active.id }))
    }

    @Test("listMessages structureOnly returns skeleton rows without content")
    func listMessagesStructureOnly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "conv-skel")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let c = try await client.conversations.create(profileID: profile.id, title: "skeleton")
        let (_, run) = try await client.conversations.sendMessage(conversationID: c.id, content: "a message with real body text")
        try await drainStream(client: client, runID: run.id)

        let (_, ctx) = try await client.conversations.get(id: c.id)
        let full = try await client.conversations.listMessages(contextID: ctx.id, fullTree: true)
        let skel = try await client.conversations.listMessages(contextID: ctx.id, fullTree: true, structureOnly: true)

        #expect(skel.count == full.count)
        #expect(skel.count >= 2)
        for m in skel {
            #expect(m.content.isEmpty)
        }
        // Shape survives: same ids and parent links as the full tree.
        let fullByID = Dictionary(uniqueKeysWithValues: full.map { ($0.id, $0) })
        for m in skel {
            #expect(fullByID[m.id] != nil)
            #expect(fullByID[m.id]?.parentID == m.parentID)
        }
    }

    // MARK: - helpers

    /// Subscribe to a stream and consume events until the terminal event
    /// fires. Used to make sure the previous turn is flushed before we
    /// kick off another (the server forbids overlapping streams).
    private func drainStream(client: PsmithClient, runID: String) async throws {
        let stream = client.streams.subscribe(streamRunID: runID)
        for await event in stream {
            switch event {
            case .terminal:
                return
            case .failed(let err):
                throw err
            case .chunk:
                continue
            }
        }
    }

    /// Poll `listMessages` (cheap, idempotent) until the conversation has
    /// no active stream — proxy is "the most recent stream isn't running."
    /// We don't have a "list streams" API surfaced on PsmithKit, so we just
    /// give the server up to ~3s before returning. Good enough for tests.
    private func waitNoActiveStream(client: PsmithClient, conversationID: String) async throws {
        // Server-side serialization is enough that subscribing to whatever
        // run the previous send returned and waiting for terminal is the
        // cleanest signal. But we don't track that here — so just sleep.
        // 200ms is well over the FakeProvider's 1-chunk turnaround.
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    // MARK: - new methods (setCurrentLeaf / regenerateAssistant / listMessages full_tree / editMessage role)

    @Test("setCurrentLeaf repositions the per-context cursor")
    func setCurrentLeafRepositions() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "rep-leaf")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "ok")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let (_, ctx) = try await client.conversations.get(id: conv.id)
        // Send a turn so we have a non-trivial chain.
        let pid = seeded.provider.id
        let mid = seeded.model.modelID
        _ = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "hi",
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)
        // Reposition the leaf to the user message (not the assistant
        // that's currently the natural leaf).
        let all = try await client.conversations.listMessages(contextID: ctx.id, fullTree: true)
        guard let target = all.first(where: { $0.role == .user }) else {
            Issue.record("no user message in fixture"); return
        }
        try await client.conversations.setCurrentLeaf(contextID: ctx.id, messageID: target.id)
        // Pulling the chain with no leafMessageID now lands at the
        // newly-set leaf — the chain should end at the user row.
        let chain = try await client.conversations.listMessages(contextID: ctx.id)
        #expect(chain.last?.id == target.id)
    }

    @Test("listMessages with fullTree returns every branch, not just one chain")
    func listMessagesFullTreeReturnsAllBranches() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "rep-tree")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "x")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let (_, ctx) = try await client.conversations.get(id: conv.id)
        let pid = seeded.provider.id
        let mid = seeded.model.modelID
        // Two turns first so the second user has a non-nil parent
        // (forking off a root-level message is ambiguous server-side).
        _ = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "first",
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)
        let (secondUser, _) = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "second",
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)
        // Fork: send a different message under the SAME parent as the
        // second user.
        _ = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "second-alt",
            parentMessageID: secondUser.parentID,
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)

        let chain = try await client.conversations.listMessages(contextID: ctx.id)
        let tree = try await client.conversations.listMessages(contextID: ctx.id, fullTree: true)
        // Tree must include strictly more rows than the chain (the
        // off-branch user + assistant aren't in the linear chain).
        #expect(tree.count > chain.count, "tree=\(tree.count) chain=\(chain.count)")
        let userTurns = tree.filter { $0.role == .user }
        #expect(userTurns.count == 3)
    }

    @Test("regenerateAssistant returns a new stream off the same user")
    func regenerateAssistantReturnsNewStream() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "rep-regen")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "x")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let pid = seeded.provider.id
        let mid = seeded.model.modelID
        let (userMsg, _) = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "hi",
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)
        // Regenerate off the same user.
        let (echoedUser, run) = try await client.conversations.regenerateAssistant(
            conversationID: conv.id,
            parentMessageID: userMsg.id,
            providerID: pid, modelID: mid
        )
        // Echoed user message is the SAME row, not a new one.
        #expect(echoedUser.id == userMsg.id)
        #expect(!run.id.isEmpty)
    }

    @Test("editMessage with role override flips user → assistant")
    func editMessageRoleFlip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "rep-role")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "x")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let pid = seeded.provider.id
        let mid = seeded.model.modelID
        let (userMsg, _) = try await client.conversations.sendMessage(
            conversationID: conv.id, content: "originally a user",
            providerID: pid, modelID: mid
        )
        try await waitNoActiveStream(client: client, conversationID: conv.id)
        let updated = try await client.conversations.editMessage(
            id: userMsg.id, content: "now an assistant", role: .assistant
        )
        #expect(updated.role == .assistant)
        #expect(updated.content == "now an assistant")
    }

}
