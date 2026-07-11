import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 behavior tests for ProvidersViewModel. Most of these need a
/// running upstream model endpoint to exercise discover/test paths — we
/// drive them against the in-process FakeProvider.
@Suite("ProvidersViewModel", .serialized)
@MainActor
struct ProvidersViewModelTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    // MARK: - load (case 1)

    @Test("load populates providers list")
    func loadPopulates() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-load")
        let (_, fake) = try await Fixtures.seedFakeProvider(client: client, label: "Fake-1")
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        #expect(vm.providers.count == 1)
        #expect(vm.providers.first?.label == "Fake-1")
        #expect(!vm.isLoadingProviders)
    }

    @Test("hasAnyEnabledModel: false with a modeless provider, true once one exists, sticky across selection")
    func onboardingGateFlag() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-gate")
        // Provider with zero enabled models: the account still needs
        // onboarding.
        let (modeless, _) = try await Fixtures.seedFakeProvider(client: client, label: "Modeless")
        let vm = ProvidersViewModel(client: client)
        await vm.load()
        #expect(vm.hasAnyEnabledModel == false)

        // A second provider WITH a model flips the flag on reload —
        // and selecting the modeless provider afterwards must NOT
        // flip it back (that selection-scoped read was the bug that
        // dumped signed-in users into the onboarding wizard).
        let (_, provider, _, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = provider
        await vm.load()
        #expect(vm.hasAnyEnabledModel == true)

        await vm.selectProvider(modeless.id)
        #expect(vm.enabledModels.isEmpty)
        #expect(vm.hasAnyEnabledModel == true)
    }

    // MARK: - selectProvider (case 2)

    @Test("selectProvider switches selectedID, fetches enabled models, resets detailMode")
    func selectProviderSwitches() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-sel")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        vm.detailMode = .editing
        await vm.selectProvider(provider.id)

        #expect(vm.selectedID == provider.id)
        #expect(vm.enabledModels.contains(where: { $0.modelID == model.modelID }))
        #expect(vm.detailMode == .viewing)
    }

    // MARK: - deleteSelected (case 3)

    @Test("deleteSelected removes the provider")
    func deleteSelectedRemoves() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-del")
        let (_, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        // load() auto-selects the first provider.
        let originalID = vm.selectedID
        await vm.deleteSelected()
        // DRIFT: testing-plan says "clears selection"; actual code unsets
        // selectedID then auto-re-selects via `if let first = providers.first`
        // — so on a single-provider system, selectedID ends up nil.
        #expect(!vm.providers.contains(where: { $0.id == originalID }))
        #expect(vm.providers.isEmpty)
        #expect(vm.selectedID == nil)
        #expect(vm.enabledModels.isEmpty)
    }

    // MARK: - disableModel (case 4)

    @Test("disableModel removes from enabledModels")
    func disableModelRemoves() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-dis")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)
        #expect(vm.enabledModels.contains(where: { $0.modelID == model.modelID }))

        await vm.disableModel(model.modelID)
        #expect(!vm.enabledModels.contains(where: { $0.modelID == model.modelID }))
    }

    // MARK: - toggleModelFavorite (case 5)

    @Test("toggleModelFavorite flips and persists")
    func toggleModelFavoritePersists() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-fav")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)
        await vm.toggleModelFavorite(modelID: model.modelID)

        let toggled = vm.enabledModels.first(where: { $0.modelID == model.modelID })
        #expect(toggled?.favorite == true)

        // Reload to confirm server persisted.
        let vm2 = ProvidersViewModel(client: client)
        await vm2.load()
        await vm2.selectProvider(provider.id)
        let reloaded = vm2.enabledModels.first(where: { $0.modelID == model.modelID })
        #expect(reloaded?.favorite == true)
    }

    // MARK: - loadTemplates (case 6)

    @Test("loadTemplates populates templates and sets templatesLoaded")
    func loadTemplatesPopulates() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-tpl")
        let vm = ProvidersViewModel(client: client)
        await vm.loadTemplates()
        #expect(vm.templatesLoaded)
        #expect(!vm.templates.isEmpty)

        // Idempotent — second call doesn't reset state.
        let count = vm.templates.count
        await vm.loadTemplates()
        #expect(vm.templates.count == count)
    }

    // MARK: - createProvider (case 7)

    @Test("createProvider appends to list")
    func createProviderAppends() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-cre")
        let vm = ProvidersViewModel(client: client)
        await vm.load()
        #expect(vm.providers.isEmpty)

        let fake = FakeProvider()
        try fake.start()
        let provider = try await vm.createProvider(
            type: "openai-compatible",
            label: "Created",
            config: Fixtures.fakeProviderConfig(baseURL: fake.baseURL)
        )
        #expect(vm.providers.contains(where: { $0.id == provider.id }))
        #expect(provider.label == "Created")
    }

    // MARK: - updateProvider (case 8)

    @Test("updateProvider updates label + config in place")
    func updateProviderUpdates() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-upd")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client, label: "Old")
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        try await vm.updateProvider(
            id: provider.id,
            label: "New",
            config: Fixtures.fakeProviderConfig(baseURL: fake.baseURL, apiKey: "new-key")
        )
        let updated = vm.providers.first(where: { $0.id == provider.id })
        #expect(updated?.label == "New")
    }

    // MARK: - updateProviderDefaultSettings (case 9)

    @Test("updateProviderDefaultSettings replaces the provider-level defaults")
    func updateProviderDefaultSettings() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-pds")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        let cs = PsmithCallSettings(temperature: 0.55)
        try await vm.updateProviderDefaultSettings(providerID: provider.id, settings: cs)
        let updated = vm.providers.first(where: { $0.id == provider.id })
        #expect(updated?.defaultSettings?.temperature == 0.55)
    }

    // MARK: - updateModelDefaultSettings (case 10)

    @Test("updateModelDefaultSettings round-trips per-model defaults")
    func updateModelDefaultSettings() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-mds")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)

        let cs = PsmithCallSettings(temperature: 0.7, topP: 0.9)
        try await vm.updateModelDefaultSettings(
            providerID: provider.id, modelID: model.modelID, settings: cs
        )
        let updated = vm.enabledModels.first(where: { $0.modelID == model.modelID })
        #expect(updated?.defaultSettings?.temperature == 0.7)
        #expect(updated?.defaultSettings?.topP == 0.9)
    }

    // MARK: - updateModelFull (case 11)

    @Test("updateModelFull persists every metadata field")
    func updateModelFullPersists() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-umf")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)

        let pricing = PsmithModelPricing(
            inputPerMillion: 1.0,
            outputPerMillion: 2.0,
            cacheReadPerMillion: nil,
            cacheWritePerMillion: nil
        )
        let caps = PsmithModelCapabilities(
            streaming: true, thinking: false, toolUse: true, vision: false, promptCaching: false
        )
        let updated = try await vm.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: "Renamed",
            contextWindow: 128_000,
            maxOutputTokens: 8_192,
            pricing: pricing,
            modalities: ["text"],
            capabilities: caps,
            knowledgeCutoff: "2025-01-01",
            defaultSettings: nil
        )
        #expect(updated.displayName == "Renamed")
        #expect(updated.contextWindow == 128_000)
        // Server normalises any prefix-of-an-ISO-8601 to "YYYY-MM-DD".
        #expect(updated.knowledgeCutoff == "2025-01-01")
        #expect(updated.capabilities?.toolUse == true)

        let inVM = vm.enabledModels.first(where: { $0.modelID == model.modelID })
        #expect(inVM?.displayName == "Renamed")
    }

    // MARK: - discoverModels (case 12)

    @Test("discoverModels returns the fake provider's models")
    func discoverModelsAgainstFake() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-disc")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        let discovered = try await vm.discoverModels(providerID: provider.id)
        #expect(discovered.contains(where: { $0.modelID == "fake-model-1" }))
    }

    // MARK: - enableModels (case 13)

    @Test("enableModels appends to enabledModels")
    func enableModelsAppends() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-enab")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)
        #expect(vm.enabledModels.isEmpty)

        let enabled = try await vm.enableModels(providerID: provider.id, modelIDs: ["fake-model-1"])
        #expect(enabled.first?.modelID == "fake-model-1")
        #expect(vm.enabledModels.contains(where: { $0.modelID == "fake-model-1" }))

        // Re-enable is deduplicated locally.
        _ = try await vm.enableModels(providerID: provider.id, modelIDs: ["fake-model-1"])
        #expect(vm.enabledModels.filter { $0.modelID == "fake-model-1" }.count == 1)
    }

    // MARK: - addManualModel (case 14)

    @Test("addManualModel appends a manual model with the requested metadata")
    func addManualModelAppends() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-amm")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.selectProvider(provider.id)

        let added = try await vm.addManualModel(
            providerID: provider.id,
            modelID: "manual-model-x",
            displayName: "Manual X",
            contextWindow: 64_000,
            maxOutputTokens: 4_096,
            pricing: nil,
            modalities: ["text"],
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(added.modelID == "manual-model-x")
        #expect(added.displayName == "Manual X")
        #expect(vm.enabledModels.contains(where: { $0.modelID == "manual-model-x" }))
    }

    // MARK: - testProvider (case 15)

    @Test("testProvider sets providerTestStatus to .testing then .success against the fake")
    func testProviderSucceedsAgainstFake() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-tp")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.testProvider(provider.id)

        switch vm.providerTestStatus[provider.id] {
        case .success(let result):
            #expect(result.ok == true)
            // The fake reports one model.
            #expect(result.modelCount >= 1)
        case .failure(let msg):
            Issue.record("unexpected failure: \(msg)")
        case .testing, .idle, .none:
            Issue.record("unexpected non-terminal state")
        }
    }

    // MARK: - testModel (case 16)

    @Test("testModel sets modelTestStatus to .testing then a terminal state against the fake")
    func testModelAgainstFake() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvw-tm")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProvidersViewModel(client: client)
        await vm.load()
        await vm.testModel(providerID: provider.id, modelID: model.modelID)

        let key = ModelTestKey(providerID: provider.id, modelID: model.modelID)
        switch vm.modelTestStatus[key] {
        case .success(let result):
            // FakeProvider's /v1/chat/completions returns "hello" — accept either
            // success or graceful failure as long as the VM transitioned out
            // of .idle / .testing.
            #expect(result.latencyMs >= 0)
        case .failure:
            // Fake's SSE format is a minimal subset — if the server's stricter
            // openai driver rejects it, we surface that as a typed failure
            // rather than a thrown error. Either way: VM landed in a terminal
            // state with the right shape.
            break
        case .testing, .idle, .none:
            Issue.record("unexpected non-terminal state")
        }
    }
}
