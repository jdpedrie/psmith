import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for new conversations that don't exist on the server
/// until their first message: "+" opens a draft, the profile pane picks
/// what it starts from, and the first send creates it.
@Suite("DraftConversation", .serialized)
@MainActor
struct DraftConversationTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private func draft(_ client: PsmithClient) -> ConversationViewModel {
        .draft(client: client, hub: StreamHub(subscriber: client.streams), onTerminal: { })
    }

    private func conversationCount(_ client: PsmithClient) async throws -> Int {
        try await client.conversations.list(pageSize: 100).0.count
    }

    /// A profile that seeds all three rows, on the fixture's model.
    private func seedingProfile(
        _ client: PsmithClient,
        _ seeded: (fake: FakeProvider, provider: PsmithUserModelProvider, model: PsmithUserModel, profile: PsmithProfile)
    ) async throws -> PsmithProfile {
        var patch = PsmithProfilePatch(
            name: "Seeding",
            defaultSettings: PsmithProfileDefaults(
                defaultProviderID: seeded.provider.id,
                defaultModelID: seeded.model.modelID
            )
        )
        patch.systemMessage = "Be brief."
        patch.defaultUserMessage = "Context: tides."
        patch.welcomeMessage = "Ahoy."
        return try await client.profiles.create(patch)
    }

    @Test("choosing a profile previews its seed rows and default model without creating anything")
    func chooseProfilePreviews() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-preview")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seedingProfile(client, seeded)
        let vm = draft(client)
        #expect(vm.isDraft)
        #expect(vm.draftProfile == nil)

        await vm.chooseDraftProfile(profile)
        #expect(vm.draftProfile?.id == profile.id)
        #expect(vm.messages.map(\.role) == [.system, .context, .assistant])
        #expect(vm.messages.map(\.content) == ["Be brief.", "Context: tides.", "Ahoy."])
        #expect(vm.messages.last?.isWelcome == true)
        #expect(vm.selectedModelID == seeded.model.modelID)
        #expect(try await conversationCount(client) == 0)
    }

    @Test("switching profiles replaces the preview and the model")
    func switchingProfileReplaces() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-switch")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let seeding = try await seedingProfile(client, seeded)
        var bare = Fixtures.minimalProfilePatch(name: "Bare")
        bare.systemMessage = "Other."
        let other = try await client.profiles.create(bare)

        let vm = draft(client)
        await vm.chooseDraftProfile(seeding)
        await vm.chooseDraftProfile(other)
        #expect(vm.draftProfile?.id == other.id)
        #expect(vm.messages.map(\.content) == ["Other."])
        #expect(vm.selectedModelID == nil, "the old profile's model doesn't carry over")
    }

    @Test("the first send creates the conversation and sends into it")
    func firstSendCreates() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-send")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seedingProfile(client, seeded)
        let vm = draft(client)
        var created: [PsmithConversation] = []
        vm.onConversationCreated = { created.append($0) }
        await vm.chooseDraftProfile(profile)

        vm.draft = "Why are there two tides a day?"
        await vm.send()
        #expect(!vm.isDraft)
        #expect(created.map(\.id) == [vm.conversation.id])
        #expect(vm.conversation.profileID == profile.id)
        #expect(vm.loadError == nil)
        // Real seed rows (server ids) followed by the sent message.
        #expect(vm.messages.map(\.role) == [.system, .context, .assistant, .user])
        #expect(!vm.messages.contains { $0.id.hasPrefix("draft-seed-") })
        #expect(vm.messages.last?.content == "Why are there two tides a day?")
        // The welcome already played in the preview. (The chain read
        // doesn't carry is_welcome today, so this only bites once it
        // does.)
        for welcome in vm.messages where welcome.isWelcome {
            #expect(vm.welcomePlayed.contains(welcome.id))
        }
        // An inferred default isn't pinned on the new row.
        let (live, _) = try await client.conversations.get(id: vm.conversation.id)
        #expect(live.settings?.defaultModelID == nil)
        #expect(try await conversationCount(client) == 1)
    }

    @Test("a model picked in the draft is written when the conversation is created")
    func explicitPickIsCreatedWith() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-pick")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let bare = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "No default"))
        let vm = draft(client)
        await vm.chooseDraftProfile(bare)
        #expect(vm.selectedModelID == nil)
        await vm.selectModel(providerID: seeded.provider.id, modelID: seeded.model.modelID)
        #expect(try await conversationCount(client) == 0, "picking a model writes nothing yet")

        vm.draft = "hi"
        await vm.send()
        let (live, _) = try await client.conversations.get(id: vm.conversation.id)
        #expect(live.settings?.defaultModelID == seeded.model.modelID)
        #expect(live.settings?.defaultProviderID == seeded.provider.id)
    }

    @Test("without a profile or a model the first send creates nothing and keeps the text")
    func incompleteDraftDoesNotCreate() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-incomplete")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let vm = draft(client)
        vm.draft = "hello"
        await vm.send()
        #expect(vm.isDraft)
        #expect(vm.draft == "hello")

        let bare = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "No default"))
        await vm.chooseDraftProfile(bare)
        await vm.send()
        #expect(vm.isDraft)
        #expect(vm.draft == "hello")
        #expect(vm.loadError != nil)
        #expect(try await conversationCount(client) == 0)
    }

    @Test("a failed create leaves the draft, its text and its profile intact")
    func failedCreateKeepsDraft() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "draft-fail")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let profile = try await seedingProfile(client, seeded)
        let vm = draft(client)
        await vm.chooseDraftProfile(profile)
        // Delete the profile out from under the draft: the create fails.
        try await client.profiles.delete(id: profile.id)

        vm.draft = "still here"
        await vm.send()
        #expect(vm.isDraft)
        #expect(vm.draft == "still here")
        #expect(vm.draftProfile?.id == profile.id)
        #expect(vm.loadError != nil)
        #expect(vm.creatingConversation == false)
    }

    @Test("an id-less draft's text isn't kept for the next new conversation")
    func draftStoreIgnoresDrafts() {
        DraftStore.save(conversationID: "", text: "leftover")
        #expect(DraftStore.load(conversationID: "") == nil)
    }
}
