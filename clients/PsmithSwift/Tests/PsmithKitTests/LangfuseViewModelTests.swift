import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for `LangfuseViewModel`. Same shape as
/// EmbedderViewModelTests — focused on the drafts + isDirty +
/// save/delete/discardChanges state machine. We don't fire actual
/// emits here (the cloud-side Langfuse endpoint isn't part of the
/// L1 harness); the ViewModel's local state is what matters.
@Suite("LangfuseViewModel", .serialized)
@MainActor
struct LangfuseViewModelTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("load on fresh user populates default-shaped saved snapshot")
    func loadDefaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-load")
        let vm = LangfuseViewModel(client: client)
        await vm.load()

        #expect(vm.didLoad)
        // Server collapses NotFound into a default-shaped config so
        // the form never has to special-case absence.
        #expect(vm.saved?.enabled == false)
        #expect(vm.saved?.secretKeySet == false)
        #expect(vm.hostDraft == "https://us.cloud.langfuse.com")
        #expect(vm.publicKeyDraft == "")
        #expect(vm.secretKeyDraft == "")
        #expect(vm.enabledDraft == false)
    }

    @Test("isDirty false at defaults")
    func isDirtyAtDefaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-dirty-d")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        #expect(vm.isDirty == false)
    }

    @Test("isDirty flips true after editing host")
    func isDirtyAfterEdit() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-dirty-e")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        vm.hostDraft = "https://eu.cloud.langfuse.com"
        #expect(vm.isDirty == true)
    }

    @Test("isDirty true while typing into secret-key write buffer")
    func isDirtySecretKeyDraft() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-dirty-s")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        vm.secretKeyDraft = "sk-lf-something"
        #expect(vm.isDirty == true)
    }

    @Test("save persists fields + clears secret write buffer")
    func saveRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-save")
        let vm = LangfuseViewModel(client: client)
        await vm.load()

        vm.publicKeyDraft = "pk-lf-test"
        vm.secretKeyDraft = "sk-lf-test"
        vm.enabledDraft = true

        let ok = await vm.save()
        #expect(ok == true, "save failed: \(vm.saveError ?? "<nil>")")
        #expect(vm.isDirty == false)
        #expect(vm.secretKeyDraft.isEmpty,
                "write-buffer should clear after save; got \(vm.secretKeyDraft)")
        #expect(vm.saved?.secretKeySet == true)
        #expect(vm.saved?.publicKey == "pk-lf-test")
        #expect(vm.saved?.enabled == true)
    }

    @Test("discardChanges resets drafts to saved snapshot")
    func discardResetsToSaved() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-disc")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        vm.publicKeyDraft = "pk-keep"
        vm.secretKeyDraft = "sk-keep"
        _ = await vm.save()
        #expect(vm.saved?.publicKey == "pk-keep")

        // Mutate then discard.
        vm.publicKeyDraft = "scrap"
        vm.secretKeyDraft = "should-clear-on-discard"
        vm.discardChanges()

        #expect(vm.publicKeyDraft == "pk-keep")
        #expect(vm.secretKeyDraft.isEmpty)
        #expect(vm.isDirty == false)
    }

    @Test("delete clears saved snapshot + drafts revert to defaults")
    func deleteClears() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-del")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        vm.publicKeyDraft = "pk-x"
        vm.secretKeyDraft = "sk-x"
        vm.enabledDraft = true
        let ok = await vm.save()
        #expect(ok, "save failed: \(vm.saveError ?? "<nil>")")

        await vm.delete()
        #expect(vm.saved == nil)
        #expect(vm.hostDraft == "https://us.cloud.langfuse.com")
        #expect(vm.publicKeyDraft.isEmpty)
        #expect(vm.secretKeyDraft.isEmpty)
        #expect(vm.enabledDraft == false)
    }

    @Test("save with empty secret-key draft preserves existing secret (tri-state nil)")
    func saveEmptySecretPreserves() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "lf-tri")
        let vm = LangfuseViewModel(client: client)
        await vm.load()
        vm.publicKeyDraft = "pk-original"
        vm.secretKeyDraft = "sk-original"
        _ = await vm.save()
        #expect(vm.saved?.secretKeySet == true)

        // Second save with secretKeyDraft empty should leave the
        // server-side secret alone.
        vm.publicKeyDraft = "pk-updated"
        #expect(vm.secretKeyDraft.isEmpty)
        _ = await vm.save()
        #expect(vm.saved?.secretKeySet == true)
        #expect(vm.saved?.publicKey == "pk-updated")
    }
}
