import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for settings writes that could replace real server state
/// with a draft the client never filled from the server. Found auditing
/// the Mac settings panes; the view models are shared, so both clients
/// were exposed.
@Suite("SettingsWriteSafety", .serialized)
@MainActor
struct SettingsWriteSafetyTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private func makeVM(client: PsmithClient, conversation: PsmithConversation) -> ConversationViewModel {
        ConversationViewModel(
            conversation: conversation,
            client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { },
            localTitler: nil
        )
    }

    private func deadClient() -> PsmithClient {
        PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState()
        )
    }

    @Test("plugin overrides that never loaded refuse to write, so they can't be replaced by an empty list")
    func unloadedOverridesRefuseToWrite() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sws-plug")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let existing = PsmithConversationPlugin(pluginName: "lettered_choices", ordinal: 0, config: Data("{}".utf8), disabled: false)
        _ = try await client.conversations.setPlugins(conversationID: conv.id, plugins: [existing])

        // The overrides fetch failed (here: never ran) while the client
        // can still write: the in-memory list is empty, and a write built
        // from it would replace the one override the conversation has.
        let vm = makeVM(client: client, conversation: conv)
        #expect(!vm.pluginOverridesLoaded)
        await vm.toggleConversationDisableInherited(pluginName: "brave_search")
        #expect(vm.settingsError != nil)

        // A prepare that can't reach the server leaves them unloaded too.
        let offline = makeVM(client: deadClient(), conversation: conv)
        await offline.prepareSettingsView()
        #expect(!offline.pluginOverridesLoaded)

        // What the conversation really has is untouched.
        let stored = try await client.conversations.getPlugins(conversationID: conv.id)
        #expect(stored.map(\.pluginName) == ["lettered_choices"])
    }

    @Test("loaded plugin overrides write as before, keeping the ones already there")
    func loadedOverridesWrite() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sws-plug-ok")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let conv = try await client.conversations.create(profileID: seeded.profile.id)
        let existing = PsmithConversationPlugin(pluginName: "lettered_choices", ordinal: 0, config: Data("{}".utf8), disabled: false)
        _ = try await client.conversations.setPlugins(conversationID: conv.id, plugins: [existing])

        let vm = makeVM(client: client, conversation: conv)
        await vm.prepareSettingsView()
        #expect(vm.pluginOverridesLoaded)
        await vm.toggleConversationDisableInherited(pluginName: "brave_search")
        #expect(vm.settingsError == nil)
        let stored = try await client.conversations.getPlugins(conversationID: conv.id)
        #expect(Set(stored.map(\.pluginName)) == ["lettered_choices", "brave_search"])
    }

    @Test("leaving settings while they're still loading writes nothing")
    func saveMidPrepareWritesNothing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sws-prep")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        var settings = PsmithConversationSettings()
        var call = PsmithCallSettings()
        call.temperature = 0.4
        settings.callSettings = call
        let conv = try await client.conversations.create(profileID: seeded.profile.id, settings: settings)

        let vm = makeVM(client: client, conversation: conv)
        // The draft hasn't been seeded from the row yet (it's empty), and
        // the screen goes away mid-prepare.
        vm.preparingSettingsView = true
        await vm.saveCallSettings()
        let (live, _) = try await client.conversations.get(id: conv.id)
        #expect(live.settings?.callSettings?.temperature == 0.4)
    }

    @Test("a provider selected later wins over an earlier selection's slower fetch")
    func providerSelectionKeepsTheLatest() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sws-prov")
        let first = try await Fixtures.seedReadyToChat(client: client)
        defer { first.fake.stop() }
        let fake2 = FakeProvider(replyText: "two")
        try fake2.start()
        defer { fake2.stop() }
        let provider2 = try await client.modelProviders.create(
            type: "openai-compatible",
            label: "Fake Two",
            config: Fixtures.fakeProviderConfig(baseURL: fake2.baseURL)
        )
        _ = try await client.modelProviders.enableModels(providerID: provider2.id, modelIDs: ["fake-model-1"])
        let second = (provider: provider2, ())
        let vm = ProvidersViewModel(client: client)
        for _ in 0..<5 {
            // A starts first and is suspended on its fetch when B is picked.
            let a = Task { await vm.selectProvider(first.provider.id) }
            await Task.yield()
            await vm.selectProvider(second.provider.id)
            await a.value
            #expect(vm.selectedID == second.provider.id)
            #expect(!vm.enabledModels.isEmpty)
            #expect(vm.enabledModels.allSatisfy { $0.providerID == second.provider.id })
            #expect(!vm.isLoadingDetail)
        }
    }
}
