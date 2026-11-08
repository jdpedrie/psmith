import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// The main window's boards as snapshots: the list column and reading
/// pane with the boards' content (see BoardProbe), at the default window
/// and the smallest one. Every conversation is from today so no weekday
/// label changes from one day to the next.
@MainActor
struct MainWindowSnapshots {
    private let sizes: [(label: String, size: CGSize)] = [
        ("default", CGSize(width: 1280, height: 800)),
        ("minWindow", CGSize(width: 1080, height: 600)),
    ]

    private static let conversations: [PsmithConversation] = [
        BoardProbe.conversation("c-weekly", "Weekly planning", "p-chief", daysAgo: 0, hour: 0, minute: 1, pinned: true),
        BoardProbe.conversation("c-scroll", "Scroll architecture review", "p-demo", daysAgo: 0, hour: 0, minute: 14),
        BoardProbe.conversation("c-pirate", "Pirate tutor: fractions", "p-pirate", daysAgo: 0, hour: 0, minute: 10),
        BoardProbe.conversation("c-council", "Council: pricing debate", "p-council", daysAgo: 0, hour: 0, minute: 5),
    ]

    private func window(
        selected: String? = "c-scroll",
        messages: [PsmithMessage] = BoardProbe.thread,
        streamingText: String = "",
        isCompacting: Bool = false,
        configure: (ConversationViewModel, Navigator) -> Void = { _, _ in }
    ) -> some View {
        let app = SnapshotStubs.makeAppModel(profiles: BoardProbe.profiles, connectivityState: .online)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: Self.conversations,
                                                          profiles: BoardProbe.profiles, selectedID: selected)
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: Self.conversations[1], client: app.client, messages: messages,
            contexts: [SnapshotFixtures.context(id: "context-c-scroll-1", conversationID: "c-scroll", messageCount: 92, lastMessageTotalTokens: 151_000, cumulativeCostUsd: 1.92),
                       SnapshotFixtures.context(id: "context-c-scroll-2", conversationID: "c-scroll", parentContextID: "context-c-scroll-1", messageCount: 36, lastMessageTotalTokens: 82_140, cumulativeCostUsd: 0.4183)],
            tokenCount: 82_140,
            streamRunID: streamingText.isEmpty ? nil : "run",
            streamingText: streamingText,
            isCompacting: isCompacting)
        let navigator = Navigator()
        configure(model, navigator)
        return PsmithMacEnvironment(app: app, convos: convos, navigator: navigator, windowState: WindowState()) {
            BoardProbe.Window(convos: convos, model: selected == nil ? nil : model)
                .environment(\.theme, .slate)
                .background(Theme.slate.chrome)
        }
    }

    @Test func conversation() { assertViewSnapshots(window(), sizes: sizes) }

    @Test func inspectorContext() {
        assertViewSnapshots(window { _, n in n.inspectorShown = true; n.inspectorTab = .context }, sizes: sizes)
    }

    @Test func inspectorSettings() {
        assertViewSnapshots(window { _, n in n.inspectorShown = true; n.inspectorTab = .settings }, sizes: sizes)
    }

    @Test func inspectorPlugins() {
        assertViewSnapshots(window { _, n in n.inspectorShown = true; n.inspectorTab = .plugins }, sizes: sizes)
    }

    @Test func nothingOpen() { assertViewSnapshots(window(selected: nil), sizes: sizes) }

    @Test func listHidden() { assertViewSnapshots(window { _, n in n.listShown = false }, sizes: sizes) }

    @Test func compressInTheComposersPlace() {
        assertViewSnapshots(window { m, _ in
            m.showingCompactView = true
            m.compactPromptDraft = "Summarize the conversation so far for a fresh context. Keep decisions, open questions, names and numbers."
        }, sizes: sizes)
    }

    @Test func compacting() {
        assertViewSnapshots(window(streamingText: "The conversation reviews why the transcript jumps.", isCompacting: true), sizes: sizes)
    }

    @Test func summaryAwaitingReview() {
        assertViewSnapshots(window(messages: Array(BoardProbe.thread.prefix(2)) + [SnapshotFixtures.compressionSummaryMessage(contextID: "context-c-scroll-2")]), sizes: sizes)
    }

    @Test func truncatedSummaryAwaitingReview() {
        assertViewSnapshots(window(messages: Array(BoardProbe.thread.prefix(2)) + [SnapshotFixtures.compressionSummaryMessage(contextID: "context-c-scroll-2", finishReason: "max_tokens")]), sizes: sizes)
    }

    @Test func streaming() {
        assertViewSnapshots(window(messages: [BoardProbe.thread[0]], streamingText: "Entry anchors at the newest message. While the view sits at the bottom, any growth re-pins it there."), sizes: sizes)
    }

    @Test func lastMessageUnanswered() {
        assertViewSnapshots(window(messages: BoardProbe.thread + [PsmithMessage(id: "m5", contextID: "context-c-scroll-2", parentID: "m4", role: .user, content: "And for the welcome reveal?")]), sizes: sizes)
    }

    @Test func failedReplyAndBanners() {
        let ctx = "context-c-scroll-2"
        assertViewSnapshots(window(messages: [
            BoardProbe.thread[0],
            PsmithMessage(id: "e", contextID: ctx, parentID: "m1", role: .assistant, content: "Partial", providerID: "provider-anthropic", modelID: "claude-opus-4-7",
                          errorText: "Anthropic returned 529: the API is overloaded. Try again in a moment."),
        ]) { m, _ in
            m.loadError = "Couldn’t load newer messages: the request timed out."
            m.compactError = "Claude Haiku 4.5 can’t fit 82,140 tokens."
        }, sizes: sizes)
    }

    @Test func modelPage() { assertViewSnapshots(window { _, n in n.page = .models }, sizes: sizes) }

    @Test func callSettingsPage() { assertViewSnapshots(window { _, n in n.page = .callSettings }, sizes: sizes) }

    @Test func fullTextPage() {
        assertViewSnapshots(window { _, n in
            n.page = .fullText(title: "Full text", markdown: String(repeating: "The eager stack makes every offset exact. ", count: 40))
        }, sizes: sizes)
    }

    @Test func usageDetails() {
        let message = BoardProbe.thread[1]
        let model = SnapshotStubs.makeConversationViewModel(messages: BoardProbe.thread)
        assertViewSnapshots(
            MessageUsageDetails(message: message, model: model).padding(20).environment(\.theme, .slate).background(Theme.slate.chrome),
            sizes: [("column", CGSize(width: 760, height: 160))])
    }
}
