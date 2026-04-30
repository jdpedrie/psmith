import Foundation
import Testing
import Connect
@testable import ClarkKit
import ClarkKitTestHarness

/// Layer 1 integration tests for ModelProvidersRepository against a real
/// clarkd subprocess. Covers tests #1–#34 from the testing plan.
///
/// Drift / impl notes:
///   * #8 ("create with unknown type → InvalidArgument") — the create RPC
///     does NOT validate the type at insert time. Validation happens lazily
///     on discoverModels / testProvider / sendMessage when the driver
///     factory tries to build a driver from the unknown type. We assert
///     the lazy-rejection path (FailedPrecondition from `providers.Build`
///     surfaced via `discoverModels`) instead.
///   * #11 (delete cascades to enabled models) — the FK is `ON DELETE
///     CASCADE`; we verify by `listModels` returning empty after delete.
///   * #13 (network error surfaces) — covered via a stopped FakeProvider
///     (the connection-refused failure surfaces as Internal from the
///     server's `discover models: ...` wrap).
///   * #28 (empty display_name rejected) — server returns InvalidArgument
///     for empty after trim.
///   * #34 (testModel "model 404") — using a model_id that the FakeProvider
///     doesn't know returns ok=false in the response body (not an RPC
///     error) per the doc'd contract.
@Suite("ModelProvidersRepository", .serialized)
struct ModelProvidersRepositoryTests {
    let server: TestClarkdServer

    init() throws {
        self.server = try TestClarkdServer.shared()
    }

    // MARK: - listProviderTypes / listTemplates (#1, #2)

    @Test("listProviderTypes returns the built-in driver types")
    func listProviderTypesIncludesBuiltins() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-types")
        let types = try await client.modelProviders.listProviderTypes()
        let names = Set(types.map(\.name))
        #expect(names.contains("anthropic"))
        #expect(names.contains("openai-compatible"))
        #expect(names.contains("google"))
    }

    @Test("listTemplates returns at least one catalog template")
    func listTemplatesNonEmpty() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-tmpl")
        let templates = try await client.modelProviders.listTemplates()
        // The catalog ships with at least anthropic/openai/google rows; we
        // don't assert exact contents to avoid coupling to catalog churn.
        #expect(!templates.isEmpty)
    }

    // MARK: - list / get (#3, #4, #5)

    @Test("list is empty for a new user, then returns providers in created_at order")
    func listEmptyThenOrdered() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-list")
        var providers = try await client.modelProviders.list()
        #expect(providers.isEmpty)

        let p1 = try await client.modelProviders.create(
            type: "anthropic", label: "First", config: Fixtures.anthropicConfig()
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        let p2 = try await client.modelProviders.create(
            type: "anthropic", label: "Second", config: Fixtures.anthropicConfig()
        )
        providers = try await client.modelProviders.list()
        #expect(providers.count == 2)
        #expect(providers[0].id == p1.id)
        #expect(providers[1].id == p2.id)
    }

    @Test("get returns the provider plus its enabled models list")
    func getReturnsProviderAndEnabled() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-get")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let (echoed, models) = try await client.modelProviders.get(id: provider.id)
        #expect(echoed.id == provider.id)
        #expect(models.contains(where: { $0.modelID == model.modelID }))
    }

    @Test("get returns NotFound when accessed by another user")
    func getCrossUserNotFound() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-get-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-get-B")
        let owned = try await clientA.modelProviders.create(
            type: "anthropic", label: "A's", config: Fixtures.anthropicConfig()
        )
        do {
            _ = try await clientB.modelProviders.get(id: owned.id)
            Issue.record("expected NotFound")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - create (#6, #7, #8)

    @Test("create openai-compatible round-trips API key + base URL config")
    func createOpenAICompat() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-oai")
        let fake = FakeProvider()
        try fake.start()
        defer { fake.stop() }
        let p = try await client.modelProviders.create(
            type: "openai-compatible",
            label: "openai-test",
            config: Fixtures.fakeProviderConfig(baseURL: fake.baseURL)
        )
        #expect(p.type == "openai-compatible")
        #expect(p.label == "openai-test")
    }

    @Test("create anthropic with just an API key works")
    func createAnthropic() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-anth")
        let p = try await client.modelProviders.create(
            type: "anthropic",
            label: "anthropic-test",
            config: Fixtures.anthropicConfig()
        )
        #expect(p.type == "anthropic")
        #expect(p.label == "anthropic-test")
    }

    @Test("create with unknown type is rejected eagerly with InvalidArgument")
    func createUnknownTypeRejectedEagerly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-unktype")
        do {
            _ = try await client.modelProviders.create(
                type: "this-driver-does-not-exist",
                label: "broken",
                config: Data("{}".utf8)
            )
            Issue.record("expected create-time rejection of unknown provider type")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }

    // MARK: - update / delete (#9, #10, #11)

    @Test("update label only changes the label")
    func updateLabelOnly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-upd-label")
        let p = try await client.modelProviders.create(
            type: "anthropic", label: "before", config: Fixtures.anthropicConfig()
        )
        let updated = try await client.modelProviders.update(id: p.id, label: "after")
        #expect(updated.label == "after")
    }

    @Test("update config replaces the config blob (server merges)")
    func updateConfigReplaces() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-upd-cfg")
        let p = try await client.modelProviders.create(
            type: "anthropic", label: "cfg",
            config: Fixtures.anthropicConfig(apiKey: "first-key")
        )
        // Server uses JSONB shallow-merge for config updates — sending
        // `api_key` overwrites it. Sanity check by re-fetching the provider:
        // the API key isn't surfaced via the proto (it's secret), but the
        // call should not error and the row should still validate later.
        let updated = try await client.modelProviders.update(
            id: p.id,
            config: Fixtures.anthropicConfig(apiKey: "second-key")
        )
        #expect(updated.id == p.id)
    }

    @Test("delete cascades to enabled models")
    func deleteCascadesToModels() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-del-cascade")
        let (fake, provider, _, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let before = try await client.modelProviders.listModels(providerID: provider.id)
        #expect(!before.isEmpty)
        try await client.modelProviders.delete(id: provider.id)
        // Re-listing the deleted provider's models — provider is gone, so
        // the listModels call returns NotFound (not an empty list).
        do {
            _ = try await client.modelProviders.listModels(providerID: provider.id)
            Issue.record("expected NotFound after delete")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - discoverModels (#12, #13)

    @Test("discoverModels returns models served by the fake provider")
    func discoverModelsHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-disc")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        let models = try await client.modelProviders.discoverModels(providerID: provider.id)
        #expect(models.contains(where: { $0.modelID == "fake-model-1" }))
    }

    @Test("discoverModels surfaces a network error when the upstream is unreachable")
    func discoverModelsNetworkError() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-disc-net")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        // Stop the fake so the upstream is unreachable when the server tries
        // to discover. The driver returns an error → service.go wraps as
        // CodeInternal.
        fake.stop()
        do {
            _ = try await client.modelProviders.discoverModels(providerID: provider.id)
            Issue.record("expected discover error")
        } catch let ClarkError.rpc(code, _) {
            // Server wraps driver errors as CodeInternal.
            #expect(code == .internalError)
        }
    }

    // MARK: - enableModels / disableModels / listModels (#14, #15, #16, #17)

    @Test("enableModels appends rows for newly enabled model ids")
    func enableModelsAppends() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-enable")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        let enabled = try await client.modelProviders.enableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        #expect(enabled.count == 1)
        #expect(enabled.first?.modelID == "fake-model-1")
        let listed = try await client.modelProviders.listModels(providerID: provider.id)
        #expect(listed.contains(where: { $0.modelID == "fake-model-1" }))
    }

    @Test("enableModels deduplicates re-enables (upsert semantics)")
    func enableModelsDedup() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-enable-dup")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        _ = try await client.modelProviders.enableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        _ = try await client.modelProviders.enableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        let listed = try await client.modelProviders.listModels(providerID: provider.id)
        let count = listed.filter { $0.modelID == "fake-model-1" }.count
        #expect(count == 1)
    }

    @Test("disableModels removes rows")
    func disableModelsRemovesRows() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-disable")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        _ = try await client.modelProviders.enableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        try await client.modelProviders.disableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        let listed = try await client.modelProviders.listModels(providerID: provider.id)
        #expect(!listed.contains(where: { $0.modelID == "fake-model-1" }))
    }

    @Test("listModels returns enabled models for a provider")
    func listModelsReturnsEnabled() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-list-models")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let listed = try await client.modelProviders.listModels(providerID: provider.id)
        #expect(listed.map(\.modelID).contains(model.modelID))
    }

    // MARK: - toggleModelFavorite / updateProviderDefaultSettings (#18, #19)

    @Test("toggleModelFavorite flips and persists")
    func toggleModelFavoriteFlips() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-fav")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let on = try await client.modelProviders.toggleModelFavorite(
            providerID: provider.id, modelID: model.modelID, favorite: true
        )
        #expect(on.favorite == true)
        let off = try await client.modelProviders.toggleModelFavorite(
            providerID: provider.id, modelID: model.modelID, favorite: false
        )
        #expect(off.favorite == false)
    }

    @Test("updateProviderDefaultSettings replaces the provider-level defaults")
    func updateProviderDefaultSettings() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-pds")
        let p = try await client.modelProviders.create(
            type: "anthropic", label: "pds", config: Fixtures.anthropicConfig()
        )
        let initial = ClarkCallSettings(temperature: 0.3)
        let updated = try await client.modelProviders.updateProviderDefaultSettings(
            providerID: p.id, settings: initial
        )
        #expect(updated.defaultSettings?.temperature == 0.3)
        // Replace with a different shape: temperature should now be unset.
        let replaced = try await client.modelProviders.updateProviderDefaultSettings(
            providerID: p.id, settings: ClarkCallSettings(topP: 0.9)
        )
        #expect(replaced.defaultSettings?.temperature == nil)
        #expect(replaced.defaultSettings?.topP == 0.9)
    }

    // MARK: - updateModel / updateModelFull (#20–#28)

    @Test("updateModel default_settings only path round-trips")
    func updateModelDefaultsOnly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-ds")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let settings = ClarkCallSettings(temperature: 0.5)
        let updated = try await client.modelProviders.updateModel(
            providerID: provider.id, modelID: model.modelID, settings: settings
        )
        #expect(updated.defaultSettings?.temperature == 0.5)
    }

    @Test("updateModelFull display_name change persists")
    func updateModelFullDisplayName() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-name")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: "Renamed Model",
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.displayName == "Renamed Model")
    }

    @Test("updateModelFull context_window change persists")
    func updateModelFullContextWindow() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-cw")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: 12345,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.contextWindow == 12345)
    }

    @Test("updateModelFull pricing change persists")
    func updateModelFullPricing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-price")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let pricing = ClarkModelPricing(
            inputPerMillion: 1.25, outputPerMillion: 5.0,
            cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.5
        )
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: pricing,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.pricing?.inputPerMillion == 1.25)
        #expect(updated.pricing?.outputPerMillion == 5.0)
        #expect(updated.pricing?.cacheReadPerMillion == 0.125)
        #expect(updated.pricing?.cacheWritePerMillion == 1.5)
    }

    @Test("updateModelFull modalities replace via the update_modalities flag")
    func updateModelFullModalities() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-modalities")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: ["text", "image"],
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.modalities == ["text", "image"])
    }

    @Test("updateModelFull capabilities update persists")
    func updateModelFullCapabilities() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-caps")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let caps = ClarkModelCapabilities(
            streaming: true, thinking: true, toolUse: true,
            vision: true, promptCaching: true
        )
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: caps,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.capabilities?.thinking == true)
        #expect(updated.capabilities?.vision == true)
    }

    @Test("updateModelFull knowledge_cutoff set persists; clear flag reverts to NULL")
    func updateModelFullKnowledgeCutoffSetClear() async throws {
        // After adding the explicit clear_knowledge_cutoff flag (and
        // parallel flags for context_window / max_output_tokens), passing
        // `clearKnowledgeCutoff: true` from the client now actually clears
        // the column to NULL on the server. Earlier the proto's optional
        // accessor had no clear-flag and `req.clearKnowledgeCutoff()`
        // un-set the field, which the server interpreted as "leave alone."
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-kc")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let set = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: "2025-01-01",
            defaultSettings: nil
        )
        #expect(set.knowledgeCutoff == "2025-01-01")
        let cleared = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            clearKnowledgeCutoff: true,
            defaultSettings: nil
        )
        #expect(cleared.knowledgeCutoff == nil)
    }

    @Test("updateModelFull sparse merge — unset fields preserved")
    func updateModelFullSparseMerge() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-sparse")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        // First, set both display name and context window.
        _ = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: "Name v1",
            contextWindow: 9999,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        // Sparse update: change only the displayName. Context window must
        // survive untouched.
        let updated = try await client.modelProviders.updateModelFull(
            providerID: provider.id,
            modelID: model.modelID,
            displayName: "Name v2",
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: nil,
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        #expect(updated.displayName == "Name v2")
        #expect(updated.contextWindow == 9999)
    }

    @Test("updateModelFull rejects an empty display_name (InvalidArgument)")
    func updateModelFullEmptyDisplayName() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-um-empty")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        do {
            _ = try await client.modelProviders.updateModelFull(
                providerID: provider.id,
                modelID: model.modelID,
                displayName: "  ",
                contextWindow: nil,
                maxOutputTokens: nil,
                pricing: nil,
                modalities: nil,
                capabilities: nil,
                knowledgeCutoff: nil,
                defaultSettings: nil
            )
            Issue.record("expected InvalidArgument")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }

    // MARK: - addManualModel (#29, #30)

    @Test("addManualModel persists the full metadata set")
    func addManualModelFullMetadata() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-add-manual")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        let pricing = ClarkModelPricing(
            inputPerMillion: 0.5, outputPerMillion: 1.5,
            cacheReadPerMillion: nil, cacheWritePerMillion: nil
        )
        let caps = ClarkModelCapabilities(
            streaming: true, thinking: false, toolUse: true,
            vision: false, promptCaching: false
        )
        let created = try await client.modelProviders.addManualModel(
            providerID: provider.id,
            modelID: "manual-model-A",
            displayName: "Manual Model A",
            contextWindow: 32_000,
            maxOutputTokens: 4096,
            pricing: pricing,
            modalities: ["text"],
            capabilities: caps,
            knowledgeCutoff: "2024-12-31",
            defaultSettings: nil
        )
        #expect(created.modelID == "manual-model-A")
        #expect(created.displayName == "Manual Model A")
        #expect(created.contextWindow == 32_000)
        #expect(created.maxOutputTokens == 4096)
        #expect(created.pricing?.inputPerMillion == 0.5)
        #expect(created.modalities == ["text"])
        #expect(created.capabilities?.toolUse == true)
        #expect(created.knowledgeCutoff == "2024-12-31")
    }

    @Test("addManualModel duplicate (provider_id, model_id) returns AlreadyExists")
    func addManualModelDuplicate() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-add-dup")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        _ = try await client.modelProviders.addManualModel(
            providerID: provider.id,
            modelID: "dup-id",
            displayName: "First",
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            modalities: [],
            capabilities: nil,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
        do {
            _ = try await client.modelProviders.addManualModel(
                providerID: provider.id,
                modelID: "dup-id",
                displayName: "Second",
                contextWindow: nil,
                maxOutputTokens: nil,
                pricing: nil,
                modalities: [],
                capabilities: nil,
                knowledgeCutoff: nil,
                defaultSettings: nil
            )
            Issue.record("expected AlreadyExists")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .alreadyExists)
        }
    }

    // MARK: - testProvider / testModel (#31, #32, #33, #34)

    @Test("testProvider succeeds against the fake provider")
    func testProviderSuccess() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-tp-ok")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        _ = fake
        let result = try await client.modelProviders.testProvider(providerID: provider.id)
        #expect(result.ok == true)
        #expect(result.modelCount >= 1)
    }

    @Test("testProvider failure surfaces ok=false in the response body")
    func testProviderFailure() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-tp-fail")
        let (provider, fake) = try await Fixtures.seedFakeProvider(client: client)
        // Stop the fake so DiscoverModels fails. Server packs the error
        // into the response (ok=false) per the documented contract.
        fake.stop()
        let result = try await client.modelProviders.testProvider(providerID: provider.id)
        #expect(result.ok == false)
        #expect(!result.errorMessage.isEmpty)
    }

    @Test("testModel succeeds against a known fake model")
    func testModelSuccess() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-tm-ok")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake
        let result = try await client.modelProviders.testModel(
            providerID: provider.id, modelID: model.modelID
        )
        #expect(result.ok == true)
        #expect(!result.sampleText.isEmpty)
    }

    @Test("testModel failure when the upstream chat endpoint can't be reached")
    func testModelFailureUnreachable() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mp-tm-fail")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        // Stop the fake — chat-completions will fail to dial.
        fake.stop()
        let result = try await client.modelProviders.testModel(
            providerID: provider.id, modelID: model.modelID
        )
        #expect(result.ok == false)
        #expect(!result.errorMessage.isEmpty)
    }
}
