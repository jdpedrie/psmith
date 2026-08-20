import Foundation
import Testing
@testable import PsmithKit

/// The rules a harness conversation runs under, as the view model reports
/// them.
///
/// These are pure functions of the binding the server sends, which is why they
/// are tested without a server: the point is that Mac, iOS and web all read
/// the same answer, not that the answer round-trips. The server enforces every
/// one of these independently, and `TestStatefulSend_*` in
/// `server/conversations` is where that is proven.
@Suite("Harness binding")
struct HarnessBindingTests {

    private func conversation(harness: PsmithHarnessBinding?) -> PsmithConversation {
        PsmithConversation(
            id: "conv-1",
            profileID: "prof-1",
            title: "Test",
            activeContextID: "ctx-1",
            ownerUserID: "user-1",
            createdAt: Date(),
            updatedAt: Date(),
            harness: harness
        )
    }

    private let codex = PsmithHarnessBinding(
        providerID: "prov-codex",
        providerLabel: "Codex",
        driverType: "codex-app-server"
    )

    private func model(_ providerID: String, _ modelID: String) -> PsmithUserModel {
        PsmithUserModel(
            providerID: providerID,
            modelID: modelID,
            displayName: modelID,
            contextWindow: nil,
            maxOutputTokens: nil,
            pricing: nil,
            knowledgeCutoff: nil,
            modalities: [],
            capabilities: nil,
            favorite: false
        )
    }

    private func models() -> [PsmithUserModel] {
        [
            model("prov-codex", "gpt-5.6"),
            model("prov-codex", "gpt-5.6-mini"),
            model("prov-anthropic", "opus"),
        ]
    }

    /// No server is contacted: every property under test reads the
    /// conversation the view model was handed. The client exists because the
    /// initializer wants one.
    @MainActor
    private func viewModel(harness: PsmithHarnessBinding?) -> ConversationViewModel {
        let client = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "not-used"),
            authState: AuthState()
        )
        let vm = ConversationViewModel(
            conversation: conversation(harness: harness),
            client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { },
            localTitler: nil
        )
        vm.availableModels = models()
        return vm
    }

    /// An ordinary conversation must be untouched by any of this.
    @MainActor
    @Test("unbound conversation keeps every affordance")
    func unboundIsUnconstrained() {
        let vm = viewModel(harness: nil)
        #expect(vm.harness == nil)
        #expect(vm.canAttachFiles)
        #expect(vm.canChangeProvider)
        #expect(!vm.systemPromptIsFrozen)
        #expect(vm.harnessNotice == nil)
        #expect(vm.selectableModels.count == 3)
    }

    @MainActor
    @Test("bound conversation loses attachments, provider changes and prompt edits")
    func boundIsConstrained() {
        let vm = viewModel(harness: codex)
        #expect(!vm.canAttachFiles)
        #expect(!vm.canChangeProvider)
        #expect(vm.systemPromptIsFrozen)
        #expect(vm.harnessNotice != nil)
    }

    /// Model switching stays available. The handle encodes the model, so the
    /// next turn simply opens against the new one; it is the provider that
    /// cannot move.
    @MainActor
    @Test("bound conversation may still change model within its provider")
    func boundKeepsItsOwnModels() {
        let vm = viewModel(harness: codex)
        let ids = Set(vm.selectableModels.map(\.modelID))
        #expect(ids == ["gpt-5.6", "gpt-5.6-mini"])
        #expect(vm.selectableModels.allSatisfy { $0.providerID == "prov-codex" })
    }

    /// A harness that grew file support must not need a client release. The
    /// flags travel on the binding for exactly this reason.
    @MainActor
    @Test("attachment support is read from the binding, not assumed")
    func attachmentSupportComesFromTheServer() {
        let permissive = PsmithHarnessBinding(
            providerID: "prov-codex",
            providerLabel: "Codex",
            driverType: "codex-app-server",
            systemPromptFrozen: true,
            acceptsAttachments: true
        )
        let vm = viewModel(harness: permissive)
        #expect(vm.canAttachFiles)
        // Still bound: file support and provider switching are unrelated.
        #expect(!vm.canChangeProvider)
    }

    /// The explanation names the provider, because "this provider" in a list
    /// of providers explains nothing.
    @Test("the explanation names the provider")
    func explanationNamesTheProvider() {
        #expect(codex.explanation.contains("Codex"))
    }

    /// Nil is the pre-load state as well as the unbound state, and the two
    /// must behave the same: let the control through and let the server refuse.
    /// A control that lies is worse than one clear error.
    @MainActor
    @Test("an unloaded conversation is treated as unconstrained")
    func nilBindingFailsOpen() {
        let vm = viewModel(harness: nil)
        #expect(vm.canAttachFiles)
        #expect(vm.selectableModels.count == vm.availableModels.count)
    }
}
