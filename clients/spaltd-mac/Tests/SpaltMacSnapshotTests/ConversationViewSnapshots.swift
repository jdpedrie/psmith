import Testing
import SwiftUI
@testable import SpaltMac
import SpaltKit
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
        liveConversation: SpaltConversation? = nil
    ) -> some View {
        let env = SnapshotEnvironment.standard(
            conversations: [model.conversation],
            selectedID: model.conversation.id
        )
        return SpaltMacEnvironment(
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
    func withThinkingEnabled() {
        // Assistant message that carries reasoning_tokens — the usage
        // chip's monospaced summary picks it up.
        let usage = SpaltMessageUsage(
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
        var draft = SpaltCallSettings()
        draft.temperature = 0.7
        let inherited = SpaltCallSettings(temperature: 1.0)
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
