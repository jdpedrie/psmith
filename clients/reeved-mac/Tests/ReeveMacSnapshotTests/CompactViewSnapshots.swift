import Testing
import SwiftUI
@testable import ReeveMac
import ReeveKit
import SnapshotHarness

/// CompactPane snapshots. The page-replaces-pane "Compact this conversation"
/// view shown when the user taps the wand toolbar button. Drives a pre-
/// populated `ConversationViewModel` straight into the view; the view's
/// `.task { … }` does kick off `prepareCompactView` against the null host
/// but the snapshot reads state we set first.
@MainActor
struct CompactViewSnapshots {

    private func wrap(model: ConversationViewModel) -> some View {
        let env = SnapshotEnvironment.standard()
        return ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { CompactPane(model: model) }
    }

    @Test
    func defaultState() {
        // Replace-mode is the implicit default — there's no append toggle
        // surfaced in the UI for this v1 of CompactView; the prompt seeds
        // from the resolved profile's compressionGuide and the model from
        // its compressionModelID.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages(),
            showingCompactView: true,
            compactPromptDraft: "Summarize the conversation, focusing on the user's actual goals.",
            compactProviderID: "provider-anthropic",
            compactModelID: "claude-opus-4-7"
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    // SKIP: append mode selected — CompactView's v1 UI doesn't expose a
    // replace/append mode toggle. Compaction mode is set on the profile,
    // not chosen per-call. Re-enable when the page grows that affordance.

    @Test
    func customCompressionModelPicked() {
        // A second user model is enabled; the user picks it for this run.
        let alt = ReeveUserModel(
            providerID: "provider-anthropic",
            modelID: "claude-haiku-4-5",
            displayName: "Claude Haiku 4.5",
            contextWindow: 200_000,
            maxOutputTokens: 4_096,
            pricing: ReeveModelPricing(
                inputPerMillion: 1.0,
                outputPerMillion: 5.0,
                cacheReadPerMillion: 0.1,
                cacheWritePerMillion: 1.25
            ),
            knowledgeCutoff: "2026-01",
            modalities: ["text"],
            capabilities: ReeveModelCapabilities(
                streaming: true, thinking: false, toolUse: true,
                vision: false, promptCaching: true
            ),
            favorite: false,
            defaultSettings: nil
        )
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages(),
            availableModels: [SnapshotFixtures.userModel(), alt],
            showingCompactView: true,
            compactPromptDraft: "Summarize this conversation tightly.",
            compactProviderID: alt.providerID,
            compactModelID: alt.modelID
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func running() {
        // isCompacting flips to true after submit; the compaction shows
        // back in the parent ConversationBody as a CompactingRow.
        // CompactPane itself doesn't render a progress indicator — the
        // submit button is owned by ConversationBody's toolbar — so this
        // snapshot just verifies the page stays interactive while a
        // compact is running on the background.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages(),
            isCompacting: true,
            showingCompactView: true,
            compactPromptDraft: "Summarize the conversation.",
            compactProviderID: "provider-anthropic",
            compactModelID: "claude-opus-4-7"
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }
}
