import Testing
import SwiftUI
@testable import SpaltMac
import SpaltKit
import SnapshotHarness

/// ContextListPane snapshots. The full-pane "Contexts" view that replaces
/// the conversation when the user taps the inbox toolbar button. Drives a
/// pre-populated `ConversationViewModel.contexts` array directly.
@MainActor
struct ContextListViewSnapshots {

    private func wrap(model: ConversationViewModel) -> some View {
        let env = SnapshotEnvironment.standard()
        return SpaltMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ContextListPane(model: model) }
    }

    @Test
    func singleContext() {
        let ctx = SnapshotFixtures.context(
            id: "context-1",
            title: "Initial discussion",
            createdAt: SnapshotFixtures.referenceDate.addingTimeInterval(-1800),
            activationTime: SnapshotFixtures.referenceDate,
            messageCount: 4,
            lastMessageTotalTokens: 880,
            cumulativeCostUsd: 0
        )
        let model = SnapshotStubs.makeConversationViewModel(
            contexts: [ctx]
        )
        model.activeContext = ctx
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func multipleContextsWithParentChain() {
        let chain = SnapshotFixtures.contextChain()
        let model = SnapshotStubs.makeConversationViewModel(
            contexts: chain
        )
        model.activeContext = chain[1]
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func withCumulativeCosts() {
        // Same chain, but every row has a non-zero cumulative cost so the
        // dollar chip renders on each entry.
        let root = SnapshotFixtures.context(
            id: "context-1",
            title: "Phase 1",
            createdAt: SnapshotFixtures.referenceDate.addingTimeInterval(-7200),
            activationTime: SnapshotFixtures.referenceDate.addingTimeInterval(-5400),
            messageCount: 8,
            lastMessageTotalTokens: 1_840,
            cumulativeCostUsd: 0.0512
        )
        let mid = SnapshotFixtures.context(
            id: "context-2",
            parentContextID: root.id,
            title: "Phase 2",
            createdAt: SnapshotFixtures.referenceDate.addingTimeInterval(-3600),
            activationTime: SnapshotFixtures.referenceDate.addingTimeInterval(-1800),
            messageCount: 6,
            lastMessageTotalTokens: 1_240,
            cumulativeCostUsd: 0.0381
        )
        let leaf = SnapshotFixtures.context(
            id: "context-3",
            parentContextID: mid.id,
            title: "Phase 3",
            createdAt: SnapshotFixtures.referenceDate.addingTimeInterval(-600),
            activationTime: SnapshotFixtures.referenceDate,
            messageCount: 3,
            lastMessageTotalTokens: 520,
            cumulativeCostUsd: 0.0098
        )
        let model = SnapshotStubs.makeConversationViewModel(
            contexts: [root, mid, leaf]
        )
        model.activeContext = leaf
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func activatedContextHighlighted() {
        // Activate the middle row, not the newest, so the highlight reads
        // as a real selection state rather than coincidence with the
        // top-of-list ordering.
        let chain = SnapshotFixtures.contextChain()
        let model = SnapshotStubs.makeConversationViewModel(
            contexts: chain
        )
        model.activeContext = chain[0]
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }
}
