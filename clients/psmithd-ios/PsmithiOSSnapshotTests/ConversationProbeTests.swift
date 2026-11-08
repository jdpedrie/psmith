import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Renders the conversation boards with their own content, for laying
/// over the boards.
@MainActor
final class ConversationProbeTests: XCTestCase {
    @MainActor struct Setup {
        var messages: [PsmithMessage] = Convo.conversation
        var conversation: PsmithConversation = Convo.scroll
        var profiles: [PsmithProfile] = Board.profiles
        var conversations: [PsmithConversation] = Board.mainList
        var offline = false
        var tokenCount: Int32? = 82_000
        var contextWindow: Int32? = 200_000
        var stream: StreamHub.ActiveStream?
        var draft = ""
        var queued: [String] = []
        var elicit: ElicitRequest?
        var followPill = false
        var configure: (ConversationViewModel, ConversationUIState) -> Void = { _, _ in }
    }

    static func screen(_ s: Setup) -> some View {
        let app = SnapshotStubs.makeAppModel(providers: [SnapshotFixtures.userModelProvider()],
                                             models: [Convo.opus, Convo.haiku], profiles: s.profiles,
                                             connectivityState: s.offline ? .offline : .online)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: s.conversations, profiles: s.profiles)
        let vm = Convo.model(s.messages, conversation: s.conversation, client: app.client, tokenCount: s.tokenCount,
                             contextWindow: s.contextWindow, stream: s.stream, draft: s.draft, queued: s.queued)
        let ui = ConversationUIState()
        s.configure(vm, ui)
        return ProbeHost(model: vm, ui: ui, elicit: s.elicit, followPill: s.followPill)
            .environment(app)
            .environment(convos)
    }

    func shoot(_ name: String, _ s: Setup) { IKRender.shoot(name) { Self.screen(s) } }

    func testConversation() { shoot("Conversation", Setup()) }

    func testStreaming() {
        let now = Date()
        shoot("Streaming", Setup(
            messages: Convo.streamingHistory, tokenCount: 86_000,
            stream: Convo.stream(text: "Past a few hundred rows, keep the eager stack for the last 200 and page older history in above it. The docs say a lazy stack",
                                 thinking: "Check the LazyVStack docs on estimated heights.",
                                 thinkingStarted: now.addingTimeInterval(-9), thinkingFinished: now.addingTimeInterval(-4.9),
                                 tools: [Convo.liveTool("search_docs", secondsAgo: 0.8)]),
            draft: "Then compare it with paging by date",
            followPill: true))
    }

    func testMessageMenu() {
        let msg = Convo.reply("a1", "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts.\n\nTwo changes fix it: render eagerly, then follow and park.", parent: "u1")
        shoot("MessageMenu", Setup(messages: [Convo.user("u1", "Why does the transcript jump?"), msg]) { vm, _ in
            vm.actionMenuMessage = msg
        })
    }

    func testMessageStates() {
        let states = Convo.states
        shoot("MessageStates", Setup(messages: states) { vm, ui in
            ui.requestDelete(states[0])
            vm.editingMessage = states[2]
        })
    }

    func testMessageUsage() {
        shoot("MessageUsage", Setup(messages: Convo.usageBoard) { vm, ui in
            vm.treeMessages = Convo.usageTree
            vm.expandedToolCallKeys.insert("a1:0")
            ui.usageExpanded.insert("a1")
        })
    }

    func testComposerTray() {
        shoot("ComposerTray", Setup(
            messages: [Convo.reply("a1", "About 38 ms to lay out the first time and 21 MB held. Both are fine on a phone.")],
            draft: "Here’s the trace. Where does the 38 ms go?") { vm, ui in
                vm.pendingAttachments = [
                    PendingAttachment(fileID: "f1", mimeType: "image/png", originalFilename: "trace.png",
                                      previewData: Convo.png(), width: 112, height: 112),
                    PendingAttachment(fileID: "f2", mimeType: "application/pdf", originalFilename: "scroll-trace.pdf",
                                      previewData: Data(count: 1_258_291), width: 0, height: 0),
                ]
                vm.attachmentUploadCount = 1
                ui.trayOpen = true
            })
    }

    func testCompress() {
        shoot("Compress", Setup(messages: Convo.decisionPair, tokenCount: 118_420, contextWindow: 131_000) { vm, _ in
            vm.showingCompactView = true
            vm.compactPromptDraft = "Summarize the conversation so far for a fresh context. Keep decisions, open questions, names and numbers."
            vm.compactProviderID = Convo.anthropic
            vm.compactModelID = "claude-haiku-4-5"
        })
    }

    func testCouncil() {
        shoot("Council", Setup(messages: Convo.council,
                               conversation: Board.conversation("c-council", "Council: pricing debate", Board.council, at: Board.today(8, 3))))
    }

    func testThinking() {
        shoot("Thinking", Setup(messages: Convo.thinking,
                                stream: Convo.stream(thinkingStarted: Date().addingTimeInterval(-3.2))) { vm, _ in
            vm.expandedThinkingMessageIDs.insert("a1")
            vm.expandedToolCallKeys.insert("a1:0")
        })
    }

    func testSelectText() {
        shoot("SelectText", Setup(messages: Convo.selectText) { vm, _ in vm.selectingTextMessageID = "a2" })
    }

    func testSystemStrip() {
        shoot("SystemStrip", Setup(messages: Convo.systemStrip, tokenCount: 24_000) { vm, _ in
            vm.expandedHeaderMessageIDs.insert("s1")
            // The second context, the one compression opened.
            let first = SnapshotFixtures.context(id: "ctx-first", conversationID: "c-scroll",
                                                 createdAt: Board.daysAgo(1))
            let second = SnapshotFixtures.context(id: Convo.ctx, conversationID: "c-scroll", createdAt: Board.today(10, 0))
            vm.contexts = [first, second]
            vm.activeContext = second
        })
    }

    func testAttachments() { shoot("Attachments", Setup(messages: Convo.attachments)) }

    func testLongReply() { shoot("LongReply", Setup(messages: Convo.longReply)) }

    func testFragments() {
        shoot("Fragments", Setup(messages: Convo.fragments) { _, ui in ui.pendingFork = ("a1", "A") })
    }

    func testOfflineQueued() {
        shoot("OfflineQueued", Setup(messages: Convo.offline, offline: true,
                                     queued: ["How big does a day get in practice?", "And what if one day has 900 messages?"]) { vm, _ in
            vm.loadError = "Couldn't load messages: the request timed out after 30 seconds."
        })
    }

    func testRenameTitle() {
        shoot("RenameTitle", Setup(messages: Convo.renameBoard) { _, ui in
            ui.renameDraft = "Scroll architecture review"
            ui.renaming = true
        })
    }

    func testReview() { shoot("Review", Setup(messages: Convo.review(truncated: false), tokenCount: 172_000)) }

    func testReviewTruncated() { shoot("ReviewTruncated", Setup(messages: Convo.review(truncated: true), tokenCount: 172_000)) }

    func testCompacting() {
        shoot("Compacting", Setup(
            messages: Convo.decisionPair, tokenCount: 172_000,
            stream: Convo.stream(text: "Topic: why the iOS transcript jumps when a reply finishes, and what to build instead.\n\nDecided: render the transcript eagerly and follow, then park. Estimated heights with correction",
                                 purpose: .compression)) { vm, _ in
                vm.compactProviderID = Convo.anthropic
                vm.compactModelID = "claude-haiku-4-5"
            })
    }

    func testCompressFailed() {
        shoot("CompressFailed", Setup(messages: Convo.compressFailed) { vm, _ in
            vm.compactError = "Claude Haiku 4.5 can’t fit 82,140 tokens."
        })
    }

    func testArchived() {
        let archivedAt = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        shoot("Archived", Setup(messages: Convo.archived,
                                conversation: Board.conversation("c-scroll", "Scroll architecture review", Board.demo,
                                                                 at: Board.today(10, 42), archived: archivedAt),
                                conversations: [Board.conversation("c-scroll", "Scroll architecture review", Board.demo,
                                                                   at: Board.today(10, 42), archived: archivedAt)]))
    }

    func testElicit() {
        var tool = Convo.liveTool("deploy_preview", secondsAgo: 4)
        tool.input = #"{"target":"preview"}"#
        shoot("Elicit", Setup(messages: Convo.elicit,
                              stream: Convo.stream(text: "I’ll deploy a preview build and send Jamie the link.", tools: [tool]),
                              elicit: Convo.elicitRequest))
    }

    func testDraftStart() {
        var convos = Board.mainList
        convos.append(Board.conversation("c-latest", "Latest", Board.demo, at: Board.today(10, 59)))
        shoot("DraftStart", Setup(messages: [], conversation: Self.draftConversation,
                                  profiles: Convo.describedProfiles, conversations: convos) { vm, _ in
            vm.chooseDraftProfileForTests(Convo.demoDescribed)
        })
    }

    func testDraftNoProfile() {
        shoot("DraftNoProfile", Setup(messages: [], conversation: Self.draftConversation, profiles: [], conversations: []) { vm, _ in
            vm.selectedProviderID = nil
            vm.selectedModelID = nil
        })
    }

    static var draftConversation: PsmithConversation {
        PsmithConversation(id: "", profileID: "", title: nil, activeContextID: "", ownerUserID: "",
                           createdAt: Date(), updatedAt: Date())
    }
}

extension ConversationViewModel {
    /// Picks the draft's profile now; the resolve that follows fails
    /// against the snapshot host and leaves the board's model chip.
    func chooseDraftProfileForTests(_ p: PsmithProfile) {
        Task { await chooseDraftProfile(p) }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        selectedProviderID = Convo.anthropic
        selectedModelID = "claude-opus-4-7"
    }
}

/// Mounts the screen pushed onto a stack, as the app does, so the system
/// navigation bar draws its back button.
struct ProbeHost: View {
    let model: ConversationViewModel
    let ui: ConversationUIState
    var elicit: ElicitRequest?
    var followPill = false
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    @State private var path = [1]

    var body: some View {
        // A pushed page lays out at the simulator's screen width, not the
        // test window's; pin it to the window so 390 renders at 390.
        GeometryReader { geo in
            NavigationStack(path: $path) {
                Color.clear
                    .navigationDestination(for: Int.self) { _ in
                        ConversationScreen(model: model, ui: ui, elicitOverride: elicit, onSend: onSend, onStop: onStop,
                                           forceFollowPill: followPill)
                            .frame(width: geo.size.width)
                    }
            }
        }
    }
}
