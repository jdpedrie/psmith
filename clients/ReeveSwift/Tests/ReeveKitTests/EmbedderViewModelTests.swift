import Foundation
import Testing
@testable import ReeveKit
import ReeveKitTestHarness

/// Layer 1 tests for `EmbedderViewModel` — drafts, isDirty, save,
/// delete, test/listTypes-driven secondary state. Runs against a
/// fresh reeved per case so the saved-snapshot shape is real, not
/// stubbed.
@Suite("EmbedderViewModel", .serialized)
@MainActor
struct EmbedderViewModelTests {
    let server: TestReevedServer

    init() throws {
        self.server = try TestReevedServer.shared()
    }

    @Test("load on fresh user populates defaults + availableTypes")
    func loadDefaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-load")
        let vm = EmbedderViewModel(client: client)
        await vm.load()

        #expect(vm.didLoad)
        // GetEmbedderConfig always returns a config (NotFound is
        // collapsed server-side into a default shape so the form
        // never has to special-case absence). saved reflects that.
        #expect(vm.saved?.apiKeySet == false)
        #expect(vm.saved?.enabled == false)
        #expect(vm.typeDraft == "openai")
        #expect(vm.baseURLDraft == "http://localhost:11434/v1")
        #expect(vm.modelDraft == "nomic-embed-text")
        #expect(vm.dimensionsDraft == 768)
        #expect(vm.enabledDraft == false)
        // listTypes fetched the registered driver set.
        #expect(vm.availableTypes.contains("openai"))
    }

    @Test("isDirty stays false at default state")
    func isDirtyAtDefaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-dirty-d")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        #expect(vm.isDirty == false)
    }

    @Test("isDirty flips true after editing a field")
    func isDirtyAfterEdit() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-dirty-e")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        vm.modelDraft = "text-embedding-3-small"
        #expect(vm.isDirty == true)
    }

    @Test("isDirty stays false after save matches new server state")
    func isDirtyClearsAfterSave() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-save")
        let vm = EmbedderViewModel(client: client)
        await vm.load()

        vm.baseURLDraft = "https://api.openai.com/v1"
        vm.modelDraft = "text-embedding-3-small"
        vm.dimensionsDraft = 1536
        vm.apiKeyDraft = "sk-test"
        vm.enabledDraft = true
        #expect(vm.isDirty == true)

        let ok = await vm.save()
        #expect(ok == true)
        #expect(vm.isDirty == false)
        #expect(vm.apiKeyDraft.isEmpty) // write buffer clears after save
        #expect(vm.saved != nil)
        #expect(vm.saved?.apiKeySet == true)
        #expect(vm.saved?.enabled == true)
        #expect(vm.saved?.dimensions == 1536)
    }

    @Test("discardChanges resets drafts to saved snapshot")
    func discardResetsToSaved() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-disc-s")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        vm.modelDraft = "text-embedding-3-small"
        vm.dimensionsDraft = 1536
        vm.apiKeyDraft = "sk-test"
        _ = await vm.save()

        // Mutate again then discard.
        vm.modelDraft = "scrap"
        vm.dimensionsDraft = 9999
        vm.apiKeyDraft = "should-clear-on-discard"
        vm.discardChanges()

        #expect(vm.modelDraft == "text-embedding-3-small")
        #expect(vm.dimensionsDraft == 1536)
        #expect(vm.apiKeyDraft.isEmpty)
        #expect(vm.isDirty == false)
    }

    @Test("discardChanges with no saved row resets to defaults")
    func discardWithoutSavedResetsToDefaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-disc-d")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        vm.modelDraft = "mucked-up"
        vm.dimensionsDraft = 4096
        vm.enabledDraft = true
        vm.discardChanges()
        #expect(vm.modelDraft == "nomic-embed-text")
        #expect(vm.dimensionsDraft == 768)
        #expect(vm.enabledDraft == false)
    }

    @Test("delete clears saved + drafts revert to defaults")
    func deleteClears() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-del")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        vm.apiKeyDraft = "sk-test"
        vm.enabledDraft = true
        let ok = await vm.save()
        #expect(ok == true, "save failed: \(vm.saveError ?? "<nil>")")
        #expect(vm.saved != nil)

        await vm.delete()
        #expect(vm.saved == nil)
        #expect(vm.modelDraft == "nomic-embed-text")
        #expect(vm.dimensionsDraft == 768)
        #expect(vm.apiKeyDraft.isEmpty)
        #expect(vm.enabledDraft == false)
    }

    @Test("save with empty apiKeyDraft preserves existing key (tri-state nil)")
    func saveEmptyKeyPreserves() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "emb-tri")
        let vm = EmbedderViewModel(client: client)
        await vm.load()
        vm.apiKeyDraft = "sk-keep"
        _ = await vm.save()
        #expect(vm.saved?.apiKeySet == true)

        // Second save: change something else but leave apiKeyDraft empty.
        vm.modelDraft = "text-embedding-3-large"
        vm.dimensionsDraft = 3072
        #expect(vm.apiKeyDraft.isEmpty) // sanity
        _ = await vm.save()
        // Key should still be set on server (we sent nil).
        #expect(vm.saved?.apiKeySet == true)
        #expect(vm.saved?.model == "text-embedding-3-large")
    }
}
