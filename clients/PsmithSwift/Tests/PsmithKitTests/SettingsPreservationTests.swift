import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for settings writes that silently dropped data the
/// form didn't show: model edits wiping `generates_images` and price
/// tiers, a favorite toggle wiping a profile's welcome message, and a
/// plugin settings screen seeding defaults over a config it never read.
@Suite("SettingsPreservation", .serialized)
@MainActor
struct SettingsPreservationTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private let tier = PsmithPricingTier(
        thresholdTokens: 200_000,
        inputPerMillion: 6,
        outputPerMillion: 22.5,
        cacheReadPerMillion: nil,
        cacheWritePerMillion: nil
    )

    private func edit(
        _ vm: ProvidersViewModel,
        _ seeded: (fake: FakeProvider, provider: PsmithUserModelProvider, model: PsmithUserModel, profile: PsmithProfile),
        pricing: PsmithModelPricing,
        capabilities: PsmithModelCapabilities
    ) async throws -> PsmithUserModel {
        try await vm.updateModelFull(
            providerID: seeded.provider.id,
            modelID: seeded.model.modelID,
            displayName: "Edited",
            contextWindow: 1000,
            maxOutputTokens: 100,
            pricing: pricing,
            modalities: ["text"],
            capabilities: capabilities,
            knowledgeCutoff: nil,
            defaultSettings: nil
        )
    }

    @Test("a full model edit round-trips generates_images and price tiers")
    func modelEditKeepsImagesAndTiers() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-model")
        let seeded = try await Fixtures.seedReadyToChat(client: client)
        defer { seeded.fake.stop() }
        let vm = ProvidersViewModel(client: client)
        let caps = PsmithModelCapabilities(
            streaming: true, thinking: false, toolUse: false,
            vision: false, promptCaching: false, generatesImages: true
        )
        let written = try await edit(
            vm, seeded,
            pricing: PsmithModelPricing(
                inputPerMillion: 3, outputPerMillion: 15,
                cacheReadPerMillion: nil, cacheWritePerMillion: nil,
                tiers: [tier]
            ),
            capabilities: caps
        )
        #expect(written.capabilities?.generatesImages == true)
        #expect(written.pricing?.tiers == [tier])

        // The next edit carries what it was given, as the forms now do
        // from the model they loaded.
        let again = try await edit(
            vm, seeded,
            pricing: PsmithModelPricing(
                inputPerMillion: 4, outputPerMillion: 15,
                cacheReadPerMillion: nil, cacheWritePerMillion: nil,
                tiers: written.pricing?.tiers ?? []
            ),
            capabilities: written.capabilities ?? .empty
        )
        #expect(again.capabilities?.generatesImages == true)
        #expect(again.pricing?.tiers == [tier])
        #expect(again.pricing?.inputPerMillion == 4)
    }

    @Test("pricing cached before tiers existed still decodes")
    func legacyCachedPricingDecodes() throws {
        let legacy = Data(#"{"inputPerMillion":3,"outputPerMillion":15}"#.utf8)
        let pricing = try JSONDecoder().decode(PsmithModelPricing.self, from: legacy)
        #expect(pricing.inputPerMillion == 3)
        #expect(pricing.tiers.isEmpty)

        let roundTrip = try JSONDecoder().decode(
            PsmithModelPricing.self,
            from: JSONEncoder().encode(PsmithModelPricing(
                inputPerMillion: 1, outputPerMillion: nil,
                cacheReadPerMillion: nil, cacheWritePerMillion: nil,
                tiers: [tier]
            ))
        )
        #expect(roundTrip.tiers == [tier])
    }

    @Test("toggling favorite keeps the profile's welcome message")
    func favoriteKeepsWelcome() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-fav")
        var patch = Fixtures.minimalProfilePatch(name: "Welcoming")
        patch.welcomeMessage = "Hello, I'm here."
        let created = try await client.profiles.create(patch)
        let vm = ProfilesViewModel(client: client)
        await vm.load()
        await vm.toggleFavorite(created.id)
        let row = try #require(vm.profiles.first(where: { $0.id == created.id }))
        #expect(row.favorite)
        #expect(row.welcomeMessage == "Hello, I'm here.")
        let (server, _) = try await client.profiles.get(id: created.id)
        #expect(server.welcomeMessage == "Hello, I'm here.")
    }

    @Test("userPluginSettingsLoaded reflects whether the server answered")
    func pluginSettingsLoadedFlag() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-plugins")
        let vm = ProfilesViewModel(client: client)
        #expect(vm.userPluginSettingsLoaded == false)
        await vm.loadUserPluginSettings()
        #expect(vm.userPluginSettingsLoaded)

        let dead = ProfilesViewModel(client: PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState()
        ))
        await dead.loadUserPluginSettings()
        #expect(dead.userPluginSettingsLoaded == false)
        #expect(dead.error != nil)
    }
}
