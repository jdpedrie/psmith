import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for conversation-screen state the iOS audit found
/// wrong: what the model chip and Compact page start from, when the
/// settings screen may write, and what a reconnect or failed load
/// leaves behind.
@Suite("ConversationScreenState", .serialized)
@MainActor
struct ConversationScreenStateTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private func makeVM(
        client: PsmithClient,
        conversation: PsmithConversation
    ) -> ConversationViewModel {
        ConversationViewModel(
            conversation: conversation,
            client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { },
            localTitler: nil
        )
    }

    @Test("a fresh conversation shows the profile's default model, not 'pick a model'")
    func freshConversationSeedsProfileDefaultModel() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-seed")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        await vm.load()
        await vm.loadAvailableModels()
        #expect(vm.selectedProviderID == seeded.provider.id)
        #expect(vm.selectedModelID == seeded.model.modelID)
        // Display only: nothing was written to the conversation.
        let (live, _) = try await client.conversations.get(id: conv.id)
        #expect(live.settings?.defaultModelID == nil)
    }

    @Test("an explicit model choice wins over the profile default")
    func explicitChoiceIsNotOverwritten() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-explicit")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        vm.selectedProviderID = "chosen-provider"
        vm.selectedModelID = "chosen-model"
        await vm.loadAvailableModels()
        #expect(vm.selectedModelID == "chosen-model")
    }

    @Test("Compact opens on the conversation's model when the profile names none")
    func compactDefaultsToConversationModel() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-compact")
        let seeded = try await Fixtures.seedReadyToChat(client: client)  // no compression model
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        await vm.load()
        await vm.loadAvailableModels()
        await vm.prepareCompactView()
        #expect(vm.compactProviderID == seeded.provider.id)
        #expect(vm.compactModelID == seeded.model.modelID)
    }

    @Test("Compact uses the profile's compression model when it names one")
    func compactPrefersProfileCompressionModel() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-compact-p")
        let seeded = try await Fixtures.seedReadyToChat(client: client, withCompression: true)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        vm.selectedProviderID = "other-provider"
        vm.selectedModelID = "other-model"
        await vm.prepareCompactView()
        #expect(vm.compactModelID == seeded.model.modelID)
        #expect(vm.compactPromptDraft == "Summarize the conversation.")
    }

    @Test("picking the model the chip shows as the profile default still pins it")
    func pickingInferredDefaultPersists() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-pin")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        await vm.load()
        await vm.loadAvailableModels()
        #expect(vm.selectedModelID == seeded.model.modelID)
        await vm.selectModel(providerID: seeded.provider.id, modelID: seeded.model.modelID)
        let (live, _) = try await client.conversations.get(id: conv.id)
        #expect(live.settings?.defaultModelID == seeded.model.modelID)
    }

    @Test("leaving the settings screen untouched doesn't bump the conversation")
    func untouchedSettingsDoNotWrite() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-noop")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        await vm.prepareSettingsView()
        #expect(vm.settingsError == nil)
        let (before, _) = try await client.conversations.get(id: conv.id)
        await vm.saveCallSettings()
        let (after, _) = try await client.conversations.get(id: conv.id)
        #expect(after.updatedAt == before.updatedAt)

        vm.conversationCallSettingsDraft = PsmithCallSettings(temperature: 0.4)
        await vm.saveCallSettings()
        let (edited, _) = try await client.conversations.get(id: conv.id)
        #expect(edited.settings?.callSettings?.temperature == 0.4)
    }

    @Test("a settings screen that couldn't load reports it, and leaving it saves nothing")
    func prepareFailureBlocksSave() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-down")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        // Same conversation, but this VM's server is gone: prepare fails.
        let dead = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState()
        )
        let vm = makeVM(client: dead, conversation: conv)
        await vm.prepareSettingsView()
        #expect(vm.settingsError != nil)
        vm.conversationCallSettingsDraft = PsmithCallSettings(temperature: 0.3)
        vm.settingsError = nil
        await vm.saveCallSettings()
        // The save never tried: a failed attempt would have set the error.
        #expect(vm.settingsError == nil)
        #expect(vm.loadError == nil)
        let (live, _) = try await client.conversations.get(id: conv.id)
        #expect(live.settings?.callSettings?.temperature == nil)
    }

    @Test("refreshIfStale reloads after a failed load even when the row hasn't moved")
    func staleCheckRecoversFailedLoad() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-stale")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        await vm.load()
        vm.loadError = "server unreachable"
        await vm.refreshIfStale()
        #expect(vm.loadError == nil)
    }

    @Test("reloadAfterReconnect fills what entry couldn't load offline")
    func reloadAfterReconnectFillsEntryState() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "css-reconnect")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let vm = makeVM(client: client, conversation: conv)
        #expect(vm.availableModels.isEmpty)
        #expect(vm.contexts.isEmpty)
        await vm.reloadAfterReconnect()
        #expect(vm.hasLoadedFromServer)
        #expect(vm.availableModels.map(\.modelID) == [seeded.model.modelID])
        #expect(vm.contexts.count == 1)
    }

    // MARK: - Transcript signals

    private func reply(_ id: String, provider: String?, model: String?, metered: Bool = true) -> PsmithMessage {
        PsmithMessage(
            id: id, contextID: "c", role: .assistant, content: id,
            providerID: provider, modelID: model,
            usage: metered ? PsmithMessageUsage(inputTokens: 10, outputTokens: 5) : nil
        )
    }

    private func offlineVM() -> ConversationViewModel {
        let client = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
        return .draft(client: client, hub: StreamHub(subscriber: client.streams), onTerminal: { })
    }

    @Test("model changes mark the reply after a switch, not the first reply or repeats")
    func modelChangeSet() {
        let vm = offlineVM()
        vm.messages = [
            reply("welcome", provider: nil, model: nil, metered: false),
            PsmithMessage(id: "u1", contextID: "c", role: .user, content: "q"),
            reply("a1", provider: "p", model: "m1"),
            reply("a2", provider: "p", model: "m1"),
            reply("a3", provider: "p", model: "m2"),
            reply("a4", provider: "q", model: "m2"),
            reply("a5", provider: "q", model: "m2"),
        ]
        #expect(vm.modelChangeMessageIDs == ["a3", "a4"])
    }

    @Test("the first metered reply skips the welcome and other unmetered rows")
    func firstMeteredReply() {
        let vm = offlineVM()
        vm.messages = [
            reply("welcome", provider: nil, model: nil, metered: false),
            reply("a1", provider: "p", model: "m1"),
            reply("a2", provider: "p", model: "m1"),
        ]
        #expect(vm.firstMeteredReplyID == "a1")
    }
}
