import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// ConversationView snapshots. Renders the internal `ConversationBody`
/// directly with a pre-populated `ConversationViewModel` (the outer
/// `ConversationView` would otherwise fire `model.load()` against the
/// null host on `task(id:)`, leaving us snapshotting a ProgressView).
///
/// State is pushed onto the live `@Observable` view-model via
/// `SnapshotStubs.makeConversationViewModel` — the same pattern used for
/// HomeView's nested ConversationsModel injection. The `streamRunID` /
/// `streamingText` / `isCompacting` knobs synthesise the streaming and
/// compacting states without touching the wire.
///
/// Sizes: each scenario snapshots at `default` + `minColumn` to catch the
/// narrow-pane case where message rows or the composer might clip.
@MainActor
struct ConversationViewSnapshots {

    /// Builds an environment + ConversationBody with the given model state.
    /// Wraps in NavigationStack because ConversationBody declares
    /// `.navigationTitle(…)` / `.toolbar(…)` modifiers that need a host.
    private func body(
        for model: ConversationViewModel,
        liveConversation: PsmithConversation? = nil
    ) -> some View {
        let env = SnapshotEnvironment.standard(
            conversations: [model.conversation],
            selectedID: model.conversation.id
        )
        return PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            NavigationStack {
                ConversationBody(
                    model: model,
                    liveConversation: liveConversation ?? model.conversation
                )
            }
        }
    }

    // MARK: - Loaded variants

    @Test
    func empty() {
        // Just the system prelude — no user/assistant turns yet.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [SnapshotFixtures.systemMessage()],
            tokenCount: nil,
            contextWindow: nil
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func userAndAssistantPair() {
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages()
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func pendingCompressionReview() {
        // A clean compression summary awaiting the user's verdict: the
        // composer is REPLACED by the CompressionReviewBar (Delete /
        // Confirm) and the summary card itself carries no inline
        // action row — content in the transcript, decision in the bar.
        // If this snapshot ever shows the send field, the pending gate
        // regressed.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages()
                + [SnapshotFixtures.compressionSummaryMessage()]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func wideBlocksContained() {
        // Pins the horizontal containment of the two content-driven
        // wide block classes: fenced code and markdown tables. Both
        // render inside their own horizontal scroller (`.clarkChat`
        // codeBlock/table themes) so a wide block can never widen the
        // chat pane — the iOS "margins shift left during generation"
        // bug rode exactly this overflow. If this snapshot ever shows
        // the table or code grid running past the bubble edge, the
        // containment regressed.
        let wide = """
        A wide table:

        | alpha | bravo | charlie | delta | echo | foxtrot | golf | hotel |
        |---|---|---|---|---|---|---|---|
        | some longer cell content | more cell content here | and again for width | keeps going wider | even wider now | almost there | nearly done | last column |

        And wide code:

        ```text
        row-0: \(String(repeating: "column-data ", count: 24))END
        ```
        """
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.userMessage(content: "show me wide output"),
                SnapshotFixtures.assistantMessage(content: wide),
            ]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func longBullets() {
        // Pins multi-line wrap inside markdown list items. Bullets
        // whose text wraps past ~2 lines were truncating with an
        // ellipsis on Mac (user-reported) — a height mismatch, not a
        // lineLimit; this snapshot fails if any bullet shows "…"
        // instead of its full wrapped text.
        let bullets = """
        Here are the tradeoffs to weigh:

        - **Latency versus throughput** — batching requests amortizes connection setup and lets the server pipeline work, but every request in the batch waits for the slowest member, so p99 latency degrades exactly when the queue is deepest and users notice it most
        - **The `staged backfill` approach** keeps the viewport anchored while history mounts in small batches, which bounds the estimate error any single re-solve can observe, at the cost of a short window where scrolling up hits the mounted boundary
        - Short one for contrast
        - **Cache locality** matters more than algorithmic
          complexity for these row sizes, because the whole working set
          fits in L2 and the branch predictor learns the access pattern
          within a few iterations of the inner loop
        - A final long item written without any inline styling at all so we can tell whether the truncation correlates with formatting spans or applies to any list item that wraps past the second line of rendered text
        """
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.userMessage(content: "list the tradeoffs"),
                SnapshotFixtures.assistantMessage(content: bullets),
            ]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func longBulletsScaled110() {
        // Real-model content shapes at the user's scale (1.1),
        // mirroring the APP's exact scaled environment: PsmithMacApp
        // injects BOTH `\.fontScale` AND a root `\.font` when scale
        // ≠ 1.0. Bold leads, inline code, and source-wrapped
        // continuation lines — the shapes real assistant bullets
        // carry.
        let bullets = """
        Here are the tradeoffs to weigh:

        - **Latency versus throughput** — batching requests amortizes connection setup and lets the server pipeline work, but every request in the batch waits for the slowest member, so p99 latency degrades exactly when the queue is deepest and users notice it most
        - **The `staged backfill` approach** keeps the viewport anchored while history mounts in small batches, which bounds the estimate error any single re-solve can observe, at the cost of a short window where scrolling up hits the mounted boundary
        - Short one for contrast
        - **Cache locality** matters more than algorithmic
          complexity for these row sizes, because the whole working set
          fits in L2 and the branch predictor learns the access pattern
          within a few iterations of the inner loop
        - A final long item written without any inline styling at all so we can tell whether the truncation correlates with formatting spans or applies to any list item that wraps past the second line of rendered text
        """
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.userMessage(content: "list the tradeoffs"),
                SnapshotFixtures.assistantMessage(content: bullets),
            ]
        )
        assertViewSnapshots(
            body(for: model)
                .environment(\.fontScale, 1.1)
                .environment(\.font, .system(size: baseSize(for: .body) * 1.1)),
            sizes: columnSizes
        )
    }

    @Test
    func longBlockquotesScaled110() {
        // Blockquote sibling of longBulletsScaled110 — quotes whose
        // text wraps past ~2 lines were truncating with an ellipsis on
        // Mac (user-reported, same height-mismatch class as the bullet
        // bug). Same triggering shapes: bold leads, inline code,
        // wrapped continuation lines, at the user's 1.1 scale with the
        // app's exact scaled environment. Fails if any quote line
        // shows "…" instead of its full wrapped text.
        let quotes = """
        The design doc puts it this way:

        > **Latency versus throughput** — batching requests amortizes connection setup and lets the server pipeline work, but every request in the batch waits for the slowest member, so p99 latency degrades exactly when the queue is deepest and users notice it most

        And later, on the `staged backfill` approach:

        > **The `staged backfill` approach** keeps the viewport anchored while history mounts in small batches, which bounds the estimate error any single re-solve can observe, at the cost of a short window where scrolling up hits the mounted boundary
        >
        > A second paragraph in the same quote written without any inline styling at all so we can tell whether the truncation correlates with formatting spans or applies to any quote that wraps past the second line of rendered text

        > Short one for contrast
        """
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.userMessage(content: "quote the doc"),
                SnapshotFixtures.assistantMessage(content: quotes),
            ]
        )
        assertViewSnapshots(
            body(for: model)
                .environment(\.fontScale, 1.1)
                .environment(\.font, .system(size: baseSize(for: .body) * 1.1)),
            sizes: columnSizes
        )
    }

    @Test
    func userAndAssistantPairScaled130() {
        // Pins the app-wide fontScale plumbing: every label and the
        // markdown body must render ~30% larger. If this snapshot ever
        // matches the unscaled pair, a migration regressed a call
        // site back to a fixed .font().
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages()
        )
        assertViewSnapshots(
            body(for: model).environment(\.fontScale, 1.3),
            sizes: columnSizes
        )
    }

    @Test
    func withThinkingEnabled() {
        // Assistant message that carries reasoning_tokens — the usage
        // chip's monospaced summary picks it up.
        let usage = PsmithMessageUsage(
            inputTokens: 1_280,
            outputTokens: 462,
            cacheReadTokens: 980,
            cacheWriteTokens: 220,
            reasoningTokens: 1_536,
            inputCostUsd: 0.0192,
            outputCostUsd: 0.0347,
            cacheReadCostUsd: 0.00147,
            cacheWriteCostUsd: 0.00413,
            totalCostUsd: 0.0595
        )
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                SnapshotFixtures.userMessage(content: "Walk me through the proof step by step."),
                SnapshotFixtures.assistantMessage(
                    content: "Sure — here's the chain of reasoning.\n\n1. Establish the base case.\n2. Show the inductive step.\n3. Conclude.",
                    usage: usage
                ),
            ]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func historicalToolCalls() {
        // Two tool calls on the assistant message — one ok (412ms) and
        // one errored (1240ms). Renders the settled disclosure pills
        // collapsed; expansion is exercised separately.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                SnapshotFixtures.userMessage(content: "What horses are running in the 2026 Kentucky Derby?"),
                SnapshotFixtures.assistantMessage(
                    content: "Here is the field for the 152nd running of the Kentucky Derby.",
                    toolCalls: SnapshotFixtures.sampleToolCalls()
                ),
            ]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func liveStreamingToolCall() {
        // Mid-stream: one tool call has already resolved (so the timer
        // freezes at the deterministic `done` value rather than ticking
        // against `Date()`, which would make the snapshot non-deterministic).
        let started = Date()
        var live = LiveToolCall(id: "call-1", name: "web_search", startedAt: started)
        live.argsCompletedAt = started
        live.resultArrivedAt = started
        live.elapsedMs = 412
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                SnapshotFixtures.userMessage(content: "What's the weather in Tokyo?"),
            ],
            streamRunID: "stream-run-1",
            streamingText: "Tokyo is currently",
            streamingToolCalls: [live]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func streaming() {
        // streamRunID set + isCompacting false → isStreaming == true,
        // composer flips to the cancel button, StreamingRow renders
        // partial text.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                SnapshotFixtures.userMessage(content: "Translate this to French."),
            ],
            streamRunID: "stream-run-1",
            streamingText: "Bien sûr, voici la traduction"
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func erroredStream() {
        // Errored assistant turn is materialized as a real message row
        // with `errorText`; the supervisor reloads the message list after
        // failure so streamRunID is back to nil.
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                SnapshotFixtures.userMessage(),
                SnapshotFixtures.erroredAssistantMessage(
                    partialContent: "I started typing but",
                    errorText: "context_length_exceeded: prompt has 220k tokens, model max 200k"
                ),
            ]
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func userMessageEditMode() {
        // editingMessage non-nil + matching id → MessageRow swaps to
        // the inline TextEditor + Save/Cancel buttons.
        let userMsg = SnapshotFixtures.userMessage(content: "What's a good way to test SwiftUI views?")
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.systemMessage(),
                userMsg,
                SnapshotFixtures.assistantMessage(),
            ],
            editingMessage: userMsg
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    // MARK: - Page-replaces-pane variants

    @Test
    func compactModePage() {
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages(),
            showingCompactView: true,
            compactPromptDraft: "Summarize this conversation focusing on testing strategy.",
            compactProviderID: "provider-anthropic",
            compactModelID: "claude-opus-4-7"
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func settingsModePage() {
        var draft = PsmithCallSettings()
        draft.temperature = 0.7
        let inherited = PsmithCallSettings(temperature: 1.0)
        let model = SnapshotStubs.makeConversationViewModel(
            messages: SnapshotFixtures.sampleMessages(),
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    @Test
    func contextsModePage() {
        let chain = SnapshotFixtures.contextChain()
        let convo = SnapshotFixtures.conversation()
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: convo,
            messages: SnapshotFixtures.sampleMessages(),
            contexts: chain,
            showingContextList: true
        )
        // activate the leaf so the highlight renders on a non-root row.
        model.activeContext = chain.last
        assertViewSnapshots(body(for: model), sizes: columnSizes)
    }

    // SKIP: usage popover open with cache-read split — popovers render via
    // a separate AppKit window that NSView.cacheDisplay doesn't see. The
    // assistant row's usage button is captured in the userAndAssistantPair
    // snapshot; the popover content is exercised by hand-testing for now.
    // TODO: Layer 3 (XCUITest).
}
