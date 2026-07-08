import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 behavior tests for ConversationViewModel — the most complex
/// view-model on the client. Pairs with `FakeProvider` so the streaming
/// surface (send / compact / context activation) executes against a
/// canned upstream without real LLM cost.
///
/// These tests deliberately avoid `Task.sleep` for stream timing — the
/// stream subscription is awaited via a polling helper that cooperatively
/// yields the main actor. Anything that mutates a `@MainActor` field (the
/// case for the entire VM surface) settles as soon as the test makes the
/// VM's task graph progress.
@Suite("ConversationViewModel", .serialized)
@MainActor
struct ConversationViewModelTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    // MARK: - Helpers

    /// Builds a fresh user, FakeProvider, profile, conversation, and a
    /// fully-initialised ConversationViewModel — the common setup for the
    /// vast majority of tests in this suite.
    private func makeReadyVM(
        usernamePrefix: String,
        replyText: String = "hello",
        withCompression: Bool = false,
        compressionMode: PsmithCompressionMode? = nil,
        conversationSettings: PsmithConversationSettings? = nil
    ) async throws -> Ready {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: usernamePrefix)
        let seeded = try await Fixtures.seedReadyToChat(
            client: client,
            replyText: replyText,
            withCompression: withCompression,
            compressionMode: compressionMode
        )
        let conv = try await client.conversations.create(
            profileID: seeded.profile.id,
            settings: conversationSettings
        )
        let vm = ConversationViewModel(
            conversation: conv,
            client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { },
            localTitler: nil
        )
        return Ready(client: client, fake: seeded.fake, provider: seeded.provider, model: seeded.model, profile: seeded.profile, conversation: conv, vm: vm)
    }

    /// Cooperatively yield until `predicate` flips to true or `deadline`
    /// elapses. Avoids `Task.sleep` so the test runs as fast as the
    /// supervisor + main-actor task graph can settle.
    private func waitFor(
        deadlineSeconds: Double = 10.0,
        _ predicate: @MainActor () -> Bool
    ) async {
        let limit = Date().addingTimeInterval(deadlineSeconds)
        while Date() < limit {
            if predicate() { return }
            await Task.yield()
            // A small pause keeps us from spinning the main actor at 100% —
            // the supervisor / DB writes happen on background actors.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Send `text` and wait for the assistant turn to materialize — the
    /// stream task lands `streamRunID = nil` once `terminal` fires and
    /// load() pulls the materialized assistant row in.
    private func sendAndAwait(
        _ vm: ConversationViewModel,
        text: String,
        deadlineSeconds: Double = 15.0
    ) async {
        vm.draft = text
        await vm.send()
        await waitFor(deadlineSeconds: deadlineSeconds) { vm.streamRunID == nil && !vm.sending }
    }

    private struct Ready {
        let client: PsmithClient
        let fake: FakeProvider
        let provider: PsmithUserModelProvider
        let model: PsmithUserModel
        let profile: PsmithProfile
        let conversation: PsmithConversation
        let vm: ConversationViewModel
    }

    // MARK: - load / contextNumber / loadAvailableModels

    @Test("load populates context + messages on first call (just system seed)")
    func loadPopulatesState() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-load")
        await r.vm.load()
        #expect(r.vm.activeContext != nil)
        #expect(r.vm.activeContext?.id == r.conversation.activeContextID)
        // Fresh conversation: there's at least the system seed (or empty).
        // Just assert load() completed without an error.
        #expect(r.vm.loadError == nil)
        #expect(r.vm.loading == false)
    }

    @Test("load is idempotent across re-calls")
    func loadIdempotent() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-load2")
        await r.vm.load()
        let firstCtxID = r.vm.activeContext?.id
        let firstCount = r.vm.messages.count
        await r.vm.load()
        #expect(r.vm.activeContext?.id == firstCtxID)
        #expect(r.vm.messages.count == firstCount)
        #expect(r.vm.loadError == nil)
    }

    @Test("contextNumber returns 1 for the first context")
    func contextNumberFirstIsOne() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-cnum")
        await r.vm.load()
        await r.vm.loadContexts()
        guard let ctxID = r.vm.activeContext?.id else {
            Issue.record("no active context")
            return
        }
        #expect(r.vm.contextNumber(for: ctxID) == 1)
    }

    @Test("loadAvailableModels populates the model picker")
    func loadAvailableModelsPopulates() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-pick")
        await r.vm.loadAvailableModels()
        #expect(r.vm.availableModels.contains(where: { $0.modelID == r.model.modelID }))
        #expect(r.vm.providerLabels[r.provider.id] == "Fake")
        #expect(r.vm.providerTypes[r.provider.id] == "openai-compatible")
    }

    // MARK: - refreshTokenCount

    @Test("refreshTokenCount with no assistant message yet leaves count nil")
    func refreshTokenCountNoTarget() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-tok-empty")
        await r.vm.load()
        await r.vm.refreshTokenCount()
        // Without a prior assistant message there's no target — token
        // count stays nil.
        #expect(r.vm.tokenCount == nil)
        #expect(r.vm.contextWindow == nil)
    }

    @Test("refreshTokenCount with Unimplemented driver leaves count nil")
    func refreshTokenCountUnimplemented() async throws {
        // OpenAI-compatible doesn't implement TokenCounter (per server
        // comment in CountContextTokens). Even after a successful send,
        // the call returns Unimplemented — VM swallows and leaves the
        // count nil.
        let r = try await makeReadyVM(usernamePrefix: "vm-tok-uni")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "hi")
        // Re-load so the assistant message is in `messages` and
        // tokenCountTarget resolves.
        await r.vm.load()
        await r.vm.refreshTokenCount()
        #expect(r.vm.tokenCount == nil)
        #expect(r.vm.contextWindow == nil)
    }

    // MARK: - send

    @Test("send appends user message, materializes assistant message")
    func sendHappy() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-send-ok", replyText: "hello")
        await r.vm.load()
        let countBefore = r.vm.messages.count
        await sendAndAwait(r.vm, text: "Greetings.")

        // After terminal: load() pulled in the user msg + assistant turn.
        let userMsgs = r.vm.messages.filter { $0.role == .user }
        let asstMsgs = r.vm.messages.filter { $0.role == .assistant }
        #expect(userMsgs.contains(where: { $0.content == "Greetings." }))
        #expect(asstMsgs.contains(where: { $0.content.contains("hello") }))
        #expect(r.vm.messages.count > countBefore)
        #expect(r.vm.draft == "")
        #expect(r.vm.pendingUserText == nil)
        #expect(r.vm.streamRunID == nil)
    }

    @Test("send is a no-op for empty / whitespace-only input")
    func sendEmptyNoop() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-send-empty")
        await r.vm.load()
        let before = r.vm.messages.count
        r.vm.draft = "   "
        await r.vm.send()
        #expect(r.vm.messages.count == before)
        #expect(r.vm.sending == false)
        #expect(r.vm.streamRunID == nil)
    }

    @Test("send with provider/model override picks the override")
    func sendWithOverride() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-send-ov", replyText: "ok-override")
        await r.vm.load()
        // Set explicit override (same provider/model as the default — the
        // important assertion is that the override path takes effect; the
        // resulting assistant message records the provider/model used).
        r.vm.selectedProviderID = r.provider.id
        r.vm.selectedModelID = r.model.modelID
        await sendAndAwait(r.vm, text: "ping")
        guard let asst = r.vm.messages.last(where: { $0.role == .assistant }) else {
            Issue.record("no assistant message")
            return
        }
        #expect(asst.providerID == r.provider.id)
        #expect(asst.modelID == r.model.modelID)
        #expect(asst.content.contains("ok-override"))
    }

    @Test("send with errored stream surfaces an error message")
    func sendErroredStream() async throws {
        // Stop the FakeProvider just before sending so the upstream
        // socket refuses connections — the supervisor materializes an
        // errored assistant message.
        let r = try await makeReadyVM(usernamePrefix: "vm-send-err")
        await r.vm.load()
        r.fake.stop()

        r.vm.draft = "this should fail"
        await r.vm.send()
        await waitFor(deadlineSeconds: 15.0) { r.vm.streamRunID == nil && !r.vm.sending }

        // Either the pre-stream RPC failed (loadError set) OR the
        // supervisor materialized an errored assistant message. Both
        // are valid terminal states for "the model couldn't serve the
        // turn". Accept either.
        let hasErroredAssistant = r.vm.messages.contains { $0.role == .assistant && $0.errorText != nil }
        #expect(hasErroredAssistant || r.vm.loadError != nil)
    }

    @Test("cancelStream tears down the in-flight subscription")
    func cancelStream() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-cancel")
        await r.vm.load()

        // Kick off send (the FakeProvider replies fast, but cancelStream
        // is a no-op when streamRunID is nil — so we exercise it both
        // pre- and post-terminal as observable contract).
        r.vm.draft = "go"
        await r.vm.send()
        // Exercise cancelStream — it dispatches an async cancel; the
        // VM still owns the stream task until terminal fires. The
        // observable contract is "no crash, eventual cleanup".
        r.vm.cancelStream()
        await waitFor(deadlineSeconds: 15.0) { r.vm.streamRunID == nil }
        #expect(r.vm.streamRunID == nil)
        #expect(r.vm.sending == false)
    }

    // MARK: - prepareCompactView / prepareSettingsView / saveCallSettings

    @Test("prepareCompactView populates compact-view state from the resolved profile")
    func prepareCompactViewPopulates() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-comp-prep", withCompression: true)
        await r.vm.prepareCompactView()
        #expect(r.vm.compactPromptDraft == "Summarize the conversation.")
        #expect(r.vm.compactProviderID == r.provider.id)
        #expect(r.vm.compactModelID == r.model.modelID)
        #expect(r.vm.preparingCompactView == false)
    }

    @Test("prepareSettingsView populates settings draft + resolved profile")
    func prepareSettingsViewPopulates() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-sett-prep")
        await r.vm.loadAvailableModels()
        await r.vm.prepareSettingsView()
        // The conversation has no overrides yet — draft starts empty;
        // the resolved profile is loaded.
        #expect(r.vm.settingsResolvedProfile != nil)
        #expect(r.vm.settingsResolvedProfile?.id == r.profile.id)
        #expect(r.vm.preparingSettingsView == false)
    }

    @Test("saveCallSettings persists conversation-level overrides")
    func saveCallSettings() async throws {
        // The full call_settings draft round-trips after the
        // settingsToJSON fix (was silently dropped before — server only
        // persisted three scalar fields and dropped the call_settings
        // sub-block on write while the read path expected it).
        let r = try await makeReadyVM(usernamePrefix: "vm-sett-save")
        await r.vm.load()

        r.vm.conversationCallSettingsDraft = PsmithCallSettings(temperature: 0.42)
        await r.vm.saveCallSettings()
        #expect(r.vm.loadError == nil)

        let (refreshed, _) = try await r.client.conversations.get(id: r.conversation.id)
        #expect(refreshed.settings?.callSettings?.temperature == 0.42)
    }

    // MARK: - compact

    @Test("compact in replace mode writes a compression_summary in the source context")
    func compactReplace() async throws {
        // Drift: the testing plan's table says "compact replace produces a
        // new context with summary," but the current server contract (see
        // internal/stream/consume.go: materializeCompression) is two-stage
        // — Compact only writes a `compression_summary` message into the
        // OLD context. The user creates a new context by calling
        // PromoteCompactionToNewContext on the summary. Tests against the
        // real contract.
        let r = try await makeReadyVM(
            usernamePrefix: "vm-comp-replace",
            replyText: "the-summary",
            withCompression: true,
            compressionMode: .replace
        )
        await r.vm.load()
        await sendAndAwait(r.vm, text: "first turn")
        await r.vm.load()

        let originalCtxID = r.vm.activeContext?.id
        await r.vm.compact()
        // Wait for the materialized compression_summary to show up in
        // messages — the supervisor's terminal handler races behind
        // isCompacting=false, so we poll the actual side-effect.
        await waitFor(deadlineSeconds: 30.0) {
            !r.vm.isCompacting && r.vm.streamRunID == nil
                && r.vm.messages.contains { $0.role == .compressionSummary }
        }

        // Active context stays the same (no auto-promote).
        #expect(r.vm.activeContext?.id == originalCtxID)
        // The compression_summary row landed in the original context.
        #expect(r.vm.messages.contains { $0.role == .compressionSummary })
    }

    @Test("compact in append mode also writes summary in source context (two-stage)")
    func compactAppend() async throws {
        // Same drift as compactReplace: the current materializeCompression
        // is two-stage. The mode is consumed downstream by
        // PromoteCompactionToNewContext, not by the compact run itself —
        // the immediate post-compact state is the same for both modes.
        let r = try await makeReadyVM(
            usernamePrefix: "vm-comp-append",
            replyText: "the-summary",
            withCompression: true,
            compressionMode: .append
        )
        await r.vm.load()
        await sendAndAwait(r.vm, text: "first turn")
        await r.vm.load()
        let originalCtxID = r.vm.activeContext?.id

        await r.vm.compact()
        await waitFor(deadlineSeconds: 30.0) {
            !r.vm.isCompacting && r.vm.streamRunID == nil
                && r.vm.messages.contains { $0.role == .compressionSummary }
        }
        await r.vm.loadContexts()

        // Active context preserved; original ID still present in contexts.
        #expect(r.vm.activeContext?.id == originalCtxID)
        #expect(r.vm.contexts.contains(where: { $0.id == originalCtxID }))
        #expect(r.vm.messages.contains { $0.role == .compressionSummary })
    }

    @Test("promoteCompaction creates a new context rooted at the summary message")
    func promoteCompaction() async throws {
        let r = try await makeReadyVM(
            usernamePrefix: "vm-comp-promote",
            replyText: "the-summary",
            withCompression: true,
            compressionMode: .replace
        )
        await r.vm.load()
        await sendAndAwait(r.vm, text: "first turn")
        await r.vm.load()
        await r.vm.compact()
        await waitFor(deadlineSeconds: 30.0) { r.vm.streamRunID == nil && !r.vm.isCompacting }

        // Find the compression_summary message in the original context.
        // After replace-mode compact the original ctx has the summary
        // row; loadContexts gives us all contexts. Find the summary in
        // any context.
        await r.vm.loadContexts()
        let allContexts = r.vm.contexts
        var summaryID: String?
        for ctx in allContexts {
            let msgs = try await r.client.conversations.listMessages(contextID: ctx.id)
            if let s = msgs.first(where: { $0.role == .compressionSummary }) {
                summaryID = s.id
                break
            }
        }
        guard let sID = summaryID else {
            Issue.record("no compression_summary message found")
            return
        }
        let beforeCount = r.vm.contexts.count
        await r.vm.promoteCompaction(messageID: sID)
        await r.vm.loadContexts()
        // A NEW context appeared in addition to whatever existed before.
        #expect(r.vm.contexts.count > beforeCount)
    }

    // MARK: - loadContexts / activateContext

    @Test("loadContexts populates the contexts list")
    func loadContextsPopulates() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-ctxlist")
        await r.vm.loadContexts()
        #expect(r.vm.contexts.count >= 1)
        #expect(r.vm.contexts.contains(where: { $0.id == r.conversation.activeContextID }))
    }

    @Test("activateContext switches the active context id")
    func activateContextSwitches() async throws {
        // To get two contexts we need: compact → promote-summary → context
        // count is now 2. activateContext flips the activation back.
        let r = try await makeReadyVM(
            usernamePrefix: "vm-ctxact",
            replyText: "summary",
            withCompression: true,
            compressionMode: .replace
        )
        await r.vm.load()
        await sendAndAwait(r.vm, text: "stuff to compact")
        await r.vm.load()
        let originalCtxID = r.vm.activeContext?.id
        await r.vm.compact()
        await waitFor(deadlineSeconds: 30.0) { r.vm.streamRunID == nil && !r.vm.isCompacting }
        await r.vm.load()

        // Find the summary and promote it to create a 2nd context.
        guard let summary = r.vm.messages.first(where: { $0.role == .compressionSummary }) else {
            Issue.record("no compression_summary materialized")
            return
        }
        await r.vm.promoteCompaction(messageID: summary.id)
        await r.vm.loadContexts()

        // Now switch back to the original.
        guard originalCtxID != nil, r.vm.contexts.count >= 2 else {
            Issue.record("expected at least two contexts after promote")
            return
        }
        let activeNow = r.vm.activeContext?.id
        guard let target = r.vm.contexts.first(where: { $0.id != activeNow }) else {
            Issue.record("no other context to activate")
            return
        }
        await r.vm.activateContext(target.id)
        #expect(r.vm.activeContext?.id == target.id)
    }

    // MARK: - editMessage / deleteMessage

    @Test("editMessage updates content locally and on the server")
    func editMessage() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-edit")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "original")
        await r.vm.load()

        guard let userMsg = r.vm.messages.first(where: { $0.role == .user && $0.content == "original" }) else {
            Issue.record("user message missing")
            return
        }
        await r.vm.editMessage(id: userMsg.id, content: "edited")

        // Local copy was updated.
        let updated = r.vm.messages.first(where: { $0.id == userMsg.id })
        #expect(updated?.content == "edited")

        // Server agrees.
        let fresh = try await r.client.conversations.listMessages(contextID: r.vm.activeContext!.id)
        #expect(fresh.first(where: { $0.id == userMsg.id })?.content == "edited")
    }

    @Test("deleteMessage non-cascading removes the message")
    func deleteMessageNoCascade() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-del-stitch")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "doomed")
        await r.vm.load()
        guard let asst = r.vm.messages.last(where: { $0.role == .assistant }) else {
            Issue.record("no assistant to delete")
            return
        }
        await r.vm.deleteMessage(id: asst.id, cascade: false)
        #expect(!r.vm.messages.contains(where: { $0.id == asst.id }))
        #expect(r.vm.loadError == nil)
    }

    @Test("deleteMessage cascading removes descendants")
    func deleteMessageCascade() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-del-cascade")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "first")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "second")
        await r.vm.load()

        // Find the first user message; cascading-delete it should also
        // remove the assistant reply + the second user/assistant pair.
        guard let firstUser = r.vm.messages.first(where: { $0.role == .user && $0.content == "first" }) else {
            Issue.record("first user message missing")
            return
        }
        let beforeCount = r.vm.messages.count
        await r.vm.deleteMessage(id: firstUser.id, cascade: true)
        // At minimum the deleted message itself is gone; descendants too.
        #expect(!r.vm.messages.contains(where: { $0.id == firstUser.id }))
        #expect(r.vm.messages.count < beforeCount)
    }

    // MARK: - maybeGenerateLocalTitle

    @Test("maybeGenerateLocalTitle is a no-op when titler is nil (default)")
    func localTitleNilTitlerNoop() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-title-nil")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "hi")
        // localTitler nil — no titler runs; the conversation title stays
        // whatever the server set (likely nil/empty for this fresh chat).
        await r.vm.maybeGenerateLocalTitle(profilesByID: [:])
        // Sanity: no crash, no error surface.
        #expect(r.vm.loadError == nil)
    }

    @Test("maybeGenerateLocalTitle no-ops for non-apple_foundation kind")
    func localTitleNonAppleNoop() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-title-other")
        await r.vm.load()
        // Inject a profile snapshot whose kind is not apple_foundation.
        let p = PsmithProfile(
            id: r.profile.id,
            name: r.profile.name,
            titleProviderKind: "some_other_kind"
        )
        await r.vm.maybeGenerateLocalTitle(profilesByID: [r.profile.id: p])
        #expect(r.vm.loadError == nil)
    }

    // MARK: - selectModel / sendForking / regenerate / branch switching

    @Test("selectModel persists provider+model on the conversation row")
    func selectModelPersists() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-selmodel")
        await r.vm.load()
        await r.vm.loadAvailableModels()
        // Pick the (only) enabled model on the seeded provider.
        guard let m = r.vm.availableModels.first else {
            Issue.record("no available models in fixture")
            return
        }
        await r.vm.selectModel(providerID: m.providerID, modelID: m.modelID)
        // Local state reflects the pick.
        #expect(r.vm.selectedProviderID == m.providerID)
        #expect(r.vm.selectedModelID == m.modelID)
        // Re-fetching the conversation from the server confirms the
        // settings blob was written through.
        let (conv, _) = try await r.client.conversations.get(id: r.conversation.id)
        #expect(conv.settings?.defaultProviderID == m.providerID)
        #expect(conv.settings?.defaultModelID == m.modelID)
    }

    @Test("load prefers conversation.settings over last-assistant for selection")
    func loadPrefersPersistedSelection() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-loadpref")
        await r.vm.load()
        await r.vm.loadAvailableModels()
        guard let m = r.vm.availableModels.first else {
            Issue.record("no available models in fixture")
            return
        }
        await r.vm.selectModel(providerID: m.providerID, modelID: m.modelID)
        // Fresh VM on the same conversation. Should pick up the
        // persisted selection on load — without it we'd fall back to
        // last-assistant (nil at this point).
        let vm2 = ConversationViewModel(
            conversation: r.conversation,
            client: r.client,
            hub: StreamHub(subscriber: r.client.streams),
            onTerminal: { },
            localTitler: nil
        )
        await vm2.load()
        #expect(vm2.selectedProviderID == m.providerID)
        #expect(vm2.selectedModelID == m.modelID)
    }

    @Test("sendForking under an existing parent creates a sibling user message")
    func sendForkingCreatesSibling() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-fork")
        await r.vm.load()
        // Send TWO turns first so the second user has a non-nil parent
        // (the first assistant). Forking off a root-level message would
        // pass parentMessageID=nil to sendMessage which falls through
        // to the leaf-resolution chain — not a fork.
        await sendAndAwait(r.vm, text: "first")
        await sendAndAwait(r.vm, text: "second")
        guard let secondUser = r.vm.messages.last(where: { $0.role == .user && $0.content == "second" }),
              let parentID = secondUser.parentID else {
            Issue.record("expected a user message with a non-nil parent")
            return
        }
        // Fork: send under the same parent as the second user. After
        // load, both should exist as siblings.
        await r.vm.sendForking(content: "second-alt", parentMessageID: parentID)
        await waitFor { r.vm.streamRunID == nil && !r.vm.sending }

        await r.vm.loadTree()
        let userSiblings = r.vm.treeMessages.filter { $0.role == .user && $0.parentID == parentID }
        #expect(userSiblings.count == 2, "expected two sibling user turns; got \(userSiblings.count)")
        #expect(userSiblings.map(\.content).sorted() == ["second", "second-alt"])
    }

    @Test("regenerateAssistant creates a sibling assistant under the same user")
    func regenerateAssistantCreatesAssistantSibling() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-regen")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "ask once")
        guard let userTurn = r.vm.messages.last(where: { $0.role == .user }) else {
            Issue.record("no user turn"); return
        }
        // Regenerate: re-stream off the same user. No duplicate user row;
        // a new assistant becomes a sibling of the original assistant.
        await r.vm.regenerateAssistant(parentMessageID: userTurn.id)
        await waitFor { r.vm.streamRunID == nil && !r.vm.sending }

        await r.vm.loadTree()
        let users = r.vm.treeMessages.filter { $0.role == .user }
        let assistants = r.vm.treeMessages.filter { $0.role == .assistant && $0.parentID == userTurn.id }
        #expect(users.count == 1, "regenerate must NOT duplicate user; got \(users.count)")
        #expect(assistants.count == 2, "expected two sibling assistant turns; got \(assistants.count)")
    }

    @Test("reloadFromMessage on assistant uses regenerate semantics")
    func reloadFromAssistantRegenerates() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-rfa")
        await r.vm.load()
        await sendAndAwait(r.vm, text: "hi")
        guard let assistant = r.vm.messages.last(where: { $0.role == .assistant }) else {
            Issue.record("no assistant"); return
        }
        await r.vm.reloadFromMessage(id: assistant.id)
        await waitFor { r.vm.streamRunID == nil && !r.vm.sending }

        await r.vm.loadTree()
        let users = r.vm.treeMessages.filter { $0.role == .user }
        #expect(users.count == 1, "reload-from-assistant must not duplicate user")
    }

    @Test("reloadFromMessage on user creates a sibling user")
    func reloadFromUserForks() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-rfu")
        await r.vm.load()
        // Two turns so the second user has a non-nil parent.
        await sendAndAwait(r.vm, text: "first")
        await sendAndAwait(r.vm, text: "second")
        guard let userTurn = r.vm.messages.last(where: { $0.role == .user && $0.content == "second" }),
              let parentID = userTurn.parentID else {
            Issue.record("no user with non-nil parent"); return
        }
        await r.vm.reloadFromMessage(id: userTurn.id)
        await waitFor { r.vm.streamRunID == nil && !r.vm.sending }

        await r.vm.loadTree()
        let userSiblings = r.vm.treeMessages.filter {
            $0.role == .user && $0.parentID == parentID
        }
        #expect(userSiblings.count == 2)
    }

    @Test("branchInfo + switchToBranch flip the active chain")
    func branchSwitchFlipsChain() async throws {
        let r = try await makeReadyVM(usernamePrefix: "vm-branch")
        await r.vm.load()
        // Two turns so subsequent forks have a non-nil parent.
        await sendAndAwait(r.vm, text: "first")
        await sendAndAwait(r.vm, text: "second")
        guard let secondUser = r.vm.messages.last(where: { $0.role == .user && $0.content == "second" }),
              let parentID = secondUser.parentID else {
            Issue.record("no user with non-nil parent"); return
        }
        await r.vm.sendForking(content: "second-alt", parentMessageID: parentID)
        await waitFor { r.vm.streamRunID == nil && !r.vm.sending }

        // After the fork, branchInfo should report 2 siblings for the
        // active branch's terminal user message. load() populates the
        // tree caches asynchronously — await loadTree() explicitly so
        // branchInfo is deterministic (same as reloadFromUserForks).
        await r.vm.load()
        await r.vm.loadTree()
        guard let activeUser = r.vm.messages.last(where: { $0.role == .user }) else {
            Issue.record("no active user after load"); return
        }
        guard let info = r.vm.branchInfo(for: activeUser.id) else {
            Issue.record("branchInfo nil despite two siblings"); return
        }
        #expect(info.siblingIDs.count == 2)
        let other = info.siblingIDs.first(where: { $0 != activeUser.id })!
        await r.vm.switchToBranch(siblingID: other)
        // After switching, the chain's terminal user turn should be the
        // other sibling (or its descendant).
        let newActive = r.vm.messages.last(where: { $0.role == .user })
        #expect(newActive?.id == other || newActive?.parentID == other,
                "expected chain to land on or under the chosen sibling")
    }

    // MARK: - Live tool-call expansion state

    @Test("expandedLiveToolCallIDs starts empty and accepts membership mutations")
    func liveToolCallExpansionState() async throws {
        let r = try await makeReadyVM(usernamePrefix: "live-tc-expand")
        #expect(r.vm.expandedLiveToolCallIDs.isEmpty)

        r.vm.expandedLiveToolCallIDs.insert("call-a")
        #expect(r.vm.expandedLiveToolCallIDs.contains("call-a"))

        r.vm.expandedLiveToolCallIDs.insert("call-b")
        #expect(r.vm.expandedLiveToolCallIDs.count == 2)

        r.vm.expandedLiveToolCallIDs.remove("call-a")
        #expect(!r.vm.expandedLiveToolCallIDs.contains("call-a"))
        #expect(r.vm.expandedLiveToolCallIDs.contains("call-b"))
    }
}
