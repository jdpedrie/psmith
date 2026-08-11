import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 coverage for multi-voice conversations: the persona fields on a
/// message, and the continue verb that lets a panel take another turn.
@Suite("Council", .serialized)
struct CouncilTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private func waitFor(
        deadlineSeconds: Double = 15.0,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private func chatting(_ prefix: String) async throws -> (PsmithClient, PsmithConversation, ConversationViewModel) {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: prefix)
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "a reply")
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = ConversationViewModel(
            conversation: conv,
            client: client,
            hub: StreamHub(subscriber: client.streams, defaults: UserDefaults(suiteName: UUID().uuidString)!),
            onTerminal: { },
            localTitler: nil
        )
        return (client, conv, vm)
    }

    // MARK: - persona

    /// An ordinary conversation must be untouched by the persona columns.
    /// This is the case that would break every existing chat if the plumbing
    /// were wrong, so it is asserted directly rather than assumed.
    @Test("an ordinary assistant message carries no persona")
    func ordinaryMessageHasNoPersona() async throws {
        let (_, _, vm) = try await chatting("council-plain")
        await MainActor.run { vm.draft = "hello" }
        await vm.send()
        await waitFor { vm.streamRunID == nil && !vm.sending }

        let assistant = await MainActor.run { vm.messages.last(where: { $0.role == .assistant }) }
        let msg = try #require(assistant)
        #expect(msg.persona == nil)
        #expect(msg.personaIndex == nil)
        #expect(msg.personaSlot == nil)
    }

    /// With no speaker there is nothing to continue, so the affordance stays
    /// hidden in an ordinary conversation.
    @Test("continue is not offered without a speaker")
    func continueHiddenWithoutPersona() async throws {
        let (_, _, vm) = try await chatting("council-nocont")
        await MainActor.run { vm.draft = "hello" }
        await vm.send()
        await waitFor { vm.streamRunID == nil && !vm.sending }

        let offered = await MainActor.run { vm.canContinueDiscussion }
        #expect(offered == false)
    }

    // MARK: - continue

    /// Continuing from a stale leaf is refused, so two clients cannot both add
    /// a speaker to the same turn.
    @Test("continue from a stale leaf is refused")
    func continueRefusesStaleLeaf() async throws {
        let (client, conv, vm) = try await chatting("council-stale")
        await MainActor.run { vm.draft = "q" }
        await vm.send()
        await waitFor { vm.streamRunID == nil && !vm.sending }

        let msgs = await MainActor.run { vm.messages }
        let userMsg = try #require(msgs.first(where: { $0.role == .user }))

        // The user row is real but no longer the leaf; the assistant is.
        await #expect(throws: (any Error).self) {
            _ = try await client.conversations.continueDiscussion(
                conversationID: conv.id,
                leafMessageID: userMsg.id
            )
        }
    }

    /// Continuing from the real leaf adds another assistant and inserts no
    /// user row. That is what makes it "extend the turn" rather than "reply".
    @Test("continue chains another assistant with no new user row")
    func continueChains() async throws {
        let (client, conv, vm) = try await chatting("council-chain")
        await MainActor.run { vm.draft = "q" }
        await vm.send()
        await waitFor { vm.streamRunID == nil && !vm.sending }

        let before = await MainActor.run { vm.messages }
        let leaf = try #require(before.last)
        let usersBefore = before.filter { $0.role == .user }.count

        _ = try await client.conversations.continueDiscussion(
            conversationID: conv.id,
            leafMessageID: leaf.id
        )

        // Poll the server rather than the view model: the continue was issued
        // straight through the repository, so the VM has no stream registered
        // and nothing local to settle.
        var after: [PsmithMessage] = []
        let deadline = Date().addingTimeInterval(20.0)
        while Date() < deadline {
            after = try await client.conversations.listMessages(contextID: conv.activeContextID)
            if after.filter({ $0.role == .assistant }).count >= 2 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(after.filter { $0.role == .user }.count == usersBefore)
        #expect(after.filter { $0.role == .assistant }.count >= 2)
    }
}

// MARK: - Label collapse

/// A repeated speaker's name collapses, the way every chat client collapses a
/// repeated sender. The rail still runs down all of them, so attribution is
/// never lost — only the redundant text.
@Suite("PersonaLabelCollapse")
struct PersonaLabelCollapseTests {
    private func msg(_ persona: String?, role: PsmithMessageRole = .assistant) -> PsmithMessage {
        PsmithMessage(
            id: UUID().uuidString, contextID: "c", parentID: nil,
            role: role, content: "x", persona: persona,
            personaIndex: persona == nil ? nil : 0
        )
    }

    @Test("the first speaker always shows a name")
    func firstShows() {
        #expect(msg("Skeptic").showsPersonaLabel(after: nil))
        #expect(msg("Skeptic").showsPersonaLabel(after: msg(nil, role: .user)))
    }

    @Test("a different speaker shows a name")
    func differentShows() {
        #expect(msg("Optimist").showsPersonaLabel(after: msg("Skeptic")))
    }

    @Test("the same speaker twice collapses")
    func sameCollapses() {
        #expect(msg("Skeptic").showsPersonaLabel(after: msg("Skeptic")) == false)
    }

    @Test("a message with no persona never shows one")
    func noPersonaNeverShows() {
        #expect(msg(nil).showsPersonaLabel(after: msg("Skeptic")) == false)
    }

    /// A user turn between two turns by the same speaker breaks the run: the
    /// name has to reappear, or the reader loses track of who resumed.
    @Test("an intervening user turn reintroduces the name")
    func userTurnBreaksTheRun() {
        #expect(msg("Skeptic").showsPersonaLabel(after: msg(nil, role: .user)))
    }
}
