import Foundation
import Testing
import Connect
@testable import ClarkKit
import ClarkKitTestHarness

/// Layer 1 behavior tests for ProfilesViewModel.
@Suite("ProfilesViewModel", .serialized)
@MainActor
struct ProfilesViewModelTests {
    let server: TestClarkdServer

    init() throws {
        self.server = try TestClarkdServer.shared()
    }

    // MARK: - load (case 1)

    /// Plan #1: "load — populates profiles + providers + models".
    /// DRIFT: ProfilesViewModel.load() only fetches profiles. The available
    /// models / provider labels are populated by a separate `loadAvailableModels()`
    /// call. We assert load() actually populates profiles, and that
    /// loadAvailableModels populates providers/models.
    @Test("load populates profiles and selects the first one")
    func loadPopulatesProfiles() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-load")
        _ = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "B"))
        _ = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "A"))

        let vm = ProfilesViewModel(client: client)
        await vm.load()

        #expect(vm.profiles.count == 2)
        #expect(vm.error == nil)
        #expect(!vm.isLoading)
        // load() auto-selects the first profile when nothing was selected.
        #expect(vm.selectedID != nil)
    }

    // MARK: - select / selected (case 2)

    @Test("select / selected round-trip switches selection and resets detailMode")
    func selectAndSelected() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-sel")
        let a = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Alpha"))
        let b = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Beta"))

        let vm = ProfilesViewModel(client: client)
        await vm.load()
        vm.detailMode = .editing

        vm.select(b.id)
        #expect(vm.selectedID == b.id)
        #expect(vm.selected()?.id == b.id)
        #expect(vm.detailMode == .viewing)

        vm.select(a.id)
        #expect(vm.selected()?.name == "Alpha")
    }

    // MARK: - loadAvailableModels (case 3)

    @Test("loadAvailableModels populates picker store")
    func loadAvailableModelsPopulatesPicker() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-models")
        let (fake, _, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake // hold listener alive for the test

        let vm = ProfilesViewModel(client: client)
        await vm.loadAvailableModels()
        #expect(vm.availableModels.contains(where: { $0.modelID == model.modelID }))
        #expect(vm.providerLabels.count >= 1)
        #expect(vm.providerTypes.values.contains("openai-compatible"))
    }

    // MARK: - toggleModelFavorite (case 4)

    @Test("toggleModelFavorite flips and persists across reload")
    func toggleModelFavoriteFlipsAndPersists() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-favm")
        let (fake, provider, model, _) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        let vm = ProfilesViewModel(client: client)
        await vm.loadAvailableModels()
        await vm.toggleModelFavorite(providerID: provider.id, modelID: model.modelID)

        let toggled = vm.availableModels.first(where: { $0.modelID == model.modelID })
        #expect(toggled?.favorite == true)

        let vm2 = ProfilesViewModel(client: client)
        await vm2.loadAvailableModels()
        let reloaded = vm2.availableModels.first(where: { $0.modelID == model.modelID })
        #expect(reloaded?.favorite == true)
    }

    // MARK: - create (cases 5, 6)

    @Test("create with full patch round-trips and inserts (sorted) into profiles")
    func createFullPatchRoundTrips() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-cf")
        let vm = ProfilesViewModel(client: client)
        await vm.load()

        let patch = Fixtures.fullProfilePatch(name: "Charlie")
        let p = try await vm.create(patch)
        #expect(p.name == "Charlie")
        #expect(p.systemMessage == "You are a helpful assistant.")
        #expect(p.favorite == true)
        #expect(vm.profiles.contains(where: { $0.id == p.id }))
    }

    @Test("create error path leaves profiles list unchanged")
    func createErrorLeavesListUnchanged() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-ce")
        let vm = ProfilesViewModel(client: client)
        _ = try await vm.create(Fixtures.minimalProfilePatch(name: "Existing"))
        let before = vm.profiles

        // Empty name → InvalidArgument.
        let bad = ClarkProfilePatch(name: "")
        do {
            _ = try await vm.create(bad)
            Issue.record("expected create to throw")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
        #expect(vm.profiles == before)
    }

    // MARK: - update (case 7)

    @Test("update with partial patch + clearFields round-trips")
    func updatePartialAndClear() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-upd")
        let vm = ProfilesViewModel(client: client)
        let original = try await vm.create(Fixtures.fullProfilePatch(name: "Mutable"))

        // Partial: rename only.
        var patch = ClarkProfilePatch(name: "Mutated")
        let renamed = try await vm.update(id: original.id, patch: patch)
        #expect(renamed.name == "Mutated")
        #expect(renamed.systemMessage == "You are a helpful assistant.")  // untouched

        // Clear: drop the system_message field.
        patch = ClarkProfilePatch()
        let cleared = try await vm.update(id: original.id, patch: patch, clearFields: ["system_message"])
        #expect(cleared.systemMessage == nil)
    }

    // MARK: - conciseName / parentChainName (cases 8, 9)

    @Test("conciseName joins this name and parent chain with slashes")
    func conciseNameWalksParents() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-cn")
        let vm = ProfilesViewModel(client: client)
        let grandparent = try await vm.create(Fixtures.minimalProfilePatch(name: "GP"))
        let parent = try await vm.create(ClarkProfilePatch(name: "P", parentProfileID: grandparent.id))
        let child  = try await vm.create(ClarkProfilePatch(name: "C", parentProfileID: parent.id))

        let leaf = vm.profiles.first(where: { $0.id == child.id })!
        #expect(vm.conciseName(for: leaf) == "C / P / GP")
    }

    @Test("parentChainName returns just the parent chain without the leaf name")
    func parentChainName() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-pcn")
        let vm = ProfilesViewModel(client: client)
        let parent = try await vm.create(Fixtures.minimalProfilePatch(name: "Parent"))
        let child  = try await vm.create(ClarkProfilePatch(name: "Child", parentProfileID: parent.id))

        let leaf = vm.profiles.first(where: { $0.id == child.id })!
        #expect(vm.parentChainName(for: leaf) == "Parent")

        let standalone = vm.profiles.first(where: { $0.id == parent.id })!
        #expect(vm.parentChainName(for: standalone) == "")
    }

    // MARK: - toggleFavorite (case 10)

    @Test("toggleFavorite flips and persists across reload")
    func toggleFavoritePersists() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-fav")
        let vm = ProfilesViewModel(client: client)
        let p = try await vm.create(Fixtures.minimalProfilePatch(name: "F"))
        await vm.toggleFavorite(p.id)

        let local = vm.profiles.first(where: { $0.id == p.id })
        #expect(local?.favorite == true)

        // Reload to confirm server persisted it.
        let vm2 = ProfilesViewModel(client: client)
        await vm2.load()
        let reloaded = vm2.profiles.first(where: { $0.id == p.id })
        #expect(reloaded?.favorite == true)
    }

    // MARK: - hasChildren (case 11)

    @Test("hasChildren returns false for a leaf and true for a parent-of")
    func hasChildren() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-hc")
        let vm = ProfilesViewModel(client: client)
        let parent = try await vm.create(Fixtures.minimalProfilePatch(name: "Parent"))
        let child  = try await vm.create(ClarkProfilePatch(name: "Child", parentProfileID: parent.id))

        #expect(vm.hasChildren(parent.id) == true)
        #expect(vm.hasChildren(child.id) == false)
    }

    // MARK: - loadPluginTypes (case 12)

    @Test("loadPluginTypes populates list (sorted by name)")
    func loadPluginTypesSorted() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-lpt")
        let vm = ProfilesViewModel(client: client)
        await vm.loadPluginTypes()
        #expect(!vm.pluginTypes.isEmpty)
        #expect(vm.pluginTypes.contains(where: { $0.name == "lettered_choices" }))
        // Sorted by name (case-insensitive) — verify by re-running the sort.
        let names = vm.pluginTypes.map(\.name)
        #expect(names == names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }))
    }

    // MARK: - loadPlugins (case 13)

    @Test("loadPlugins(forProfileID:) populates the dict for that profile")
    func loadPluginsPopulatesDict() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-lp")
        let vm = ProfilesViewModel(client: client)
        let profile = try await vm.create(Fixtures.minimalProfilePatch(name: "P"))

        // Empty initially.
        await vm.loadPlugins(forProfileID: profile.id)
        #expect(vm.profilePlugins[profile.id]?.isEmpty == true)

        // After a save, the dict reflects the new list.
        _ = try await client.profiles.setProfilePlugins(
            profileID: profile.id,
            plugins: [Fixtures.letteredChoicesPlugin(ordinal: 0)]
        )
        await vm.loadPlugins(forProfileID: profile.id)
        #expect(vm.profilePlugins[profile.id]?.count == 1)
        #expect(vm.profilePlugins[profile.id]?.first?.pluginName == "lettered_choices")
    }

    // MARK: - savePlugins (cases 14, 15)

    @Test("savePlugins persists, updates dict, survives reload")
    func savePluginsPersistsAndReloads() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-sp")
        let vm = ProfilesViewModel(client: client)
        let profile = try await vm.create(Fixtures.minimalProfilePatch(name: "P"))

        try await vm.savePlugins(
            forProfileID: profile.id,
            plugins: [Fixtures.letteredChoicesPlugin(ordinal: 0)]
        )
        #expect(vm.profilePlugins[profile.id]?.count == 1)
        #expect(vm.profilePlugins[profile.id]?.first?.pluginName == "lettered_choices")

        // Reload from a fresh VM and confirm server persisted.
        let vm2 = ProfilesViewModel(client: client)
        await vm2.loadPlugins(forProfileID: profile.id)
        #expect(vm2.profilePlugins[profile.id]?.first?.pluginName == "lettered_choices")
    }

    @Test("savePlugins with an unknown plugin name surfaces InvalidArgument")
    func savePluginsUnknownPluginThrows() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-spi")
        let vm = ProfilesViewModel(client: client)
        let profile = try await vm.create(Fixtures.minimalProfilePatch(name: "P"))
        do {
            try await vm.savePlugins(forProfileID: profile.id, plugins: [Fixtures.unknownPlugin()])
            Issue.record("expected savePlugins to throw")
        } catch let ClarkError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }

    // MARK: - deleteSelected (case 16)

    @Test("deleteSelected removes the selected profile and falls back selectedID")
    func deleteSelected() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "pvm-del")
        let vm = ProfilesViewModel(client: client)
        let a = try await vm.create(Fixtures.minimalProfilePatch(name: "A"))
        _ = try await vm.create(Fixtures.minimalProfilePatch(name: "B"))
        await vm.load()

        vm.select(a.id)
        await vm.deleteSelected()
        #expect(!vm.profiles.contains(where: { $0.id == a.id }))
        // selectedID falls back to whatever is now first.
        #expect(vm.selectedID != a.id)
        #expect(vm.detailMode == .viewing)
    }
}
