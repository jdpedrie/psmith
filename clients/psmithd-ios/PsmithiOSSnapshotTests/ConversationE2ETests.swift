import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The conversation screen end to end: sending and streaming in the
/// situations the screen meets on a phone, and every transcript action
/// against the server. Recorded frame by frame where something could
/// flicker; read back from the server where something should persist.
@MainActor
final class ConversationE2ETests: E2ETestCase {

    /// Opens `conv` in the chats stack and waits for its first load.
    private func open(_ conv: PsmithConversation, _ app: AppModel, _ convos: ConversationsModel,
                      minMessages: Int = 0) async -> UIWindow {
        await convos.refresh()
        let w = mountStack(.conversation(conv), app: app, convos: convos)
        await waitFor("the conversation never loaded", timeout: 20) {
            built.last.map { !$0.0.loading && $0.0.hasLoadedFromServer && $0.0.messages.count >= minMessages } ?? false
        }
        return w
    }

    // MARK: Returning from a page

    /// Coming back from a pushed page (Info here) builds a fresh view
    /// model, by design. The transcript must follow it: a send after
    /// the return shows the user's message and the reply throughout.
    func testSendAfterReturningFromInfoShowsBothMessages() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Info return")
        try await seedTurn(app, conv, "echo marmalade")
        let w = await open(conv, app, convos, minMessages: 2)
        await spin(0.5)

        built.last!.1.page = .info  // the context gauge's tap
        await waitFor("Info never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await spin(0.8)
        built.last!.1.page = nil  // back
        await waitFor("Info never popped") { E2ETimeline.navigationDepth(w) == 2 }
        await waitFor("the screen didn't reload after the page", timeout: 15) {
            built.count == 2 && built.last!.0.hasLoadedFromServer && !built.last!.0.loading
        }
        await spin(0.8)

        try await sendAndWatch(w, name: "send-after-info", text: "echo periwinkle", user: "echo periwinkle",
                               reply: "heard periwinkle", models: 2)
    }

    /// The same after the model page, the common case on a phone: change
    /// the model, come back, send.
    func testSendAfterChangingTheModelShowsBothMessages() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Model return")
        try await seedTurn(app, conv, "echo marmalade")
        let w = await open(conv, app, convos, minMessages: 2)

        built.last!.1.page = .models
        await waitFor("the model page never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await built.last!.0.selectModel(providerID: seeded.provider.id, modelID: "model-two")
        built.last!.1.page = nil
        await waitFor("the model page never popped") { E2ETimeline.navigationDepth(w) == 2 }
        // Whether the pop rebuilds the view model depends on whether
        // SwiftUI re-runs the screen's task; the send has to show either way.
        await spin(1)
        await waitFor("the screen didn't settle after the page", timeout: 15) {
            built.last!.0.hasLoadedFromServer && !built.last!.0.loading
        }
        XCTAssertEqual(built.last!.0.selectedModelID, "model-two", "the screen lost the model just picked")

        try await sendAndWatch(w, name: "send-after-models", text: "echo lavender", user: "echo lavender",
                               reply: "heard lavender", models: built.count)
        let msgs = try await messages(app, conv)
        XCTAssertEqual(msgs.last?.modelID, "model-two", "the reply didn't come from the model picked")
    }

    // MARK: Sending under pressure

    /// A model that takes seconds to say anything: the user's message
    /// holds through the wait, and the reply shows when it starts.
    func testSlowFirstChunkKeepsTheMessageUp() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Slow start")
        let w = await open(conv, app, convos)
        try await sendAndWatch(w, name: "slow-first-chunk", text: "echo saffron slowstart", user: "echo saffron",
                               reply: "heard saffron", timeout: 35)
    }

    /// Sending the moment the screen opens, while its first load is still
    /// in flight: the load landing must not wipe the optimistic message
    /// or the reply.
    func testSendWhileTheFirstLoadIsInFlight() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Early send")
        try await seedTurn(app, conv, "echo marmalade")
        await convos.refresh()
        let w = mountStack(.conversation(conv), app: app, convos: convos)
        await waitFor("the screen never built its model") { !built.isEmpty }
        try await sendAndWatch(w, name: "send-during-load", text: "echo quince", user: "echo quince",
                               reply: "heard quince")
        XCTAssertTrue(built.last!.0.messages.contains { $0.content.lowercased().contains("heard marmalade") },
                      "the earlier history went missing. \(state())")
    }

    /// Two sends in quick succession: the second waits for the first (the
    /// composer refuses while a reply streams), and both turns end up on
    /// screen and on the server.
    func testTwoQuickSends() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Quick sends")
        let w = await open(conv, app, convos)
        let (vm, ui) = built.last!
        vm.draft = "echo hazel"
        Composer(model: vm, ui: ui).send()
        await spin(0.1)
        vm.draft = "echo walnut"
        Composer(model: vm, ui: ui).send()
        await waitFor("the first reply never finished", timeout: 20) {
            !vm.isStreaming && vm.messages.contains { $0.content.lowercased().contains("heard hazel") }
        }
        XCTAssertEqual(vm.draft, "echo walnut", "a send refused mid-stream must keep its text in the composer")
        try await sendAndWatch(w, name: "second-send", text: "echo walnut", user: "echo walnut", reply: "heard walnut")
        let msgs = try await messages(app, conv)
        XCTAssertEqual(msgs.filter { $0.role == .user }.map(\.content), ["echo hazel", "echo walnut"])
    }

    /// What foregrounding the app does mid-stream: the scene-phase hooks
    /// (`refreshIfStale`), the shell's events kick and list refresh, and a
    /// stream resubscribe from the run's start, all while the reply is
    /// arriving.
    func testForegroundingMidStreamKeepsBothMessages() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Foreground")
        try await seedTurn(app, conv, "echo marmalade")
        let w = await open(conv, app, convos, minMessages: 2)
        let vm = built.last!.0
        let churn = Task { @MainActor in
            while !vm.isStreaming { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // ConversationView's .background then .active.
            vm.suspendActiveStream()
            vm.resumeStreamIfPaused()
            await vm.refreshIfStale()
            // AppShell's .active.
            app.kickEventStream()
            convos.refreshSoon()
            await app.preferences.load()
            // A resubscribe from sequence zero, as adopting a run the
            // server reports does after a reconnect.
            if let run = app.streamHub.activeStream(conversationID: conv.id) {
                app.streamHub.register(runID: run.runID, conversationID: conv.id, contextID: run.contextID,
                                       purpose: .assistantResponse)
            }
            await app.reconcileAfterReconnect()
        }
        defer { churn.cancel() }
        try await sendAndWatch(w, name: "foreground-mid-stream", text: "echo bramble", user: "echo bramble",
                               reply: "heard bramble")
    }

    /// The model fails outright: the user's message stays, the failure
    /// shows, and nothing is left streaming.
    func testAFailedReplyShowsTheErrorAndKeepsTheMessage() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Failure")
        _ = await open(conv, app, convos)
        let (vm, ui) = built.last!
        vm.draft = "echo nettle failnow"
        Composer(model: vm, ui: ui).send()
        await waitFor("the failed run never ended", timeout: 25) {
            !vm.isStreaming && !vm.sending && vm.messages.contains { $0.role == .user && $0.content == "echo nettle failnow" }
        }
        await waitFor("the failure never reached the transcript", timeout: 10) {
            vm.messages.contains { $0.errorText != nil } || vm.loadError != nil
        }
        await waitForText("echo nettle")
    }

    // MARK: Stop

    func testStopEndsTheReplyWhereItWas() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Stop")
        _ = await open(conv, app, convos)
        let vm = built.last!.0
        await typeMessage("please write a long essay")
        await press("Send")
        await waitFor("the essay never started", timeout: 15) { vm.streamingText.count > 80 }
        await press("Stop the reply")
        await waitFor("the reply never stopped", timeout: 15) { !vm.isStreaming }
        let msgs = try await messages(app, conv)
        let reply = try XCTUnwrap(msgs.last { $0.role == .assistant }, "the stopped reply wasn't kept")
        XCTAssertTrue(reply.content.hasPrefix("# A Long Essay"), "the kept reply isn't what streamed: \(reply.content.prefix(60))")
        XCTAssertFalse(reply.content.contains("Section 8"), "the reply ran to the end; Stop did nothing")
        await waitForText("long essay")
    }

    // MARK: Message actions

    /// Long-press a message, then a row of the menu, by its label.
    private func menu(_ msg: PsmithMessage, _ action: String, _ vm: ConversationViewModel) async {
        vm.actionMenuMessage = msg
        // The menu fades in; activating a control mid-fade does nothing.
        await spin(0.6)
        await press(action)
        await waitFor("the menu never closed") { vm.actionMenuMessage == nil }
    }

    func testCopyPutsTheMessageOnTheClipboard() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Copy")
        try await seedTurn(app, conv, "echo coral")
        let clip = RecordingClipboard()
        await convos.refresh()
        mount(E2EChatsStack(start: .conversation(conv)) { [weak self] m, ui in self?.built.append((m, ui)) }
                .environment(\.clipboard, clip),
              app: app, convos: convos)
        await waitFor("the conversation never loaded", timeout: 20) { built.last?.0.messages.count ?? 0 >= 2 }
        let vm = built.last!.0
        let reply = try XCTUnwrap(vm.messages.last { $0.role == .assistant })
        await menu(reply, "Copy", vm)
        XCTAssertEqual(clip.written.last, reply.content)
    }

    /// Regenerate from the menu: a second reply to the same message, the
    /// first kept as a branch, and the switcher moves between them.
    func testRegenerateAddsABranchAndTheSwitcherMovesBetweenThem() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Regenerate")
        try await seedTurn(app, conv, "echo amber")
        _ = await open(conv, app, convos, minMessages: 2)
        let vm = built.last!.0
        let first = try XCTUnwrap(vm.messages.last { $0.role == .assistant })
        await menu(first, "Regenerate", vm)
        await waitFor("the regenerated reply never landed", timeout: 25) {
            !vm.isStreaming && vm.messages.last.map { $0.role == .assistant && $0.id != first.id } ?? false
        }
        let second = vm.messages.last!
        XCTAssertEqual(second.parentID, first.parentID, "the regenerated reply isn't a sibling of the first")
        await waitFor("the branch switcher never learned of both replies", timeout: 10) {
            vm.branchInfo(for: second.id)?.siblingIDs.count == 2
        }
        await press("Previous branch")
        await waitFor("Previous never switched back to the first reply") { vm.messages.last?.id == first.id }
        await eventually("the server's leaf didn't follow the switch") {
            try await self.app_leaf(app, conv) == first.id
        }
        await press("Next branch")
        await waitFor("Next never switched to the second reply") { vm.messages.last?.id == second.id }
        await eventually("the server's leaf didn't follow the switch") {
            try await self.app_leaf(app, conv) == second.id
        }
    }

    private func app_leaf(_ app: AppModel, _ conv: PsmithConversation) async throws -> String? {
        try await app.client.conversations.get(id: conv.id).1.currentLeafMessageID
    }

    /// Edit an earlier message of yours and resend: the conversation forks
    /// there, the new branch streams, and the old one stays reachable.
    func testEditAndResendForksFromTheEditedMessage() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Edit resend")
        try await seedTurn(app, conv, "echo maple")
        try await seedTurn(app, conv, "echo cedar")
        _ = await open(conv, app, convos, minMessages: 4)
        let vm = built.last!.0
        let original = try XCTUnwrap(vm.messages.first { $0.role == .user && $0.content == "echo cedar" })
        await menu(original, "Edit", vm)
        await waitFor("the edit card never opened") { vm.editingMessage?.id == original.id }
        let editor = try XCTUnwrap(editableTextView(showing: "echo cedar"), "no editor holding the message")
        editor.selectAll(nil)
        editor.insertText("echo birch")
        await spin(0.3)
        await press("Save and Resend")
        await waitFor("the fork never streamed its reply", timeout: 25) {
            !vm.isStreaming && vm.messages.contains { $0.content.lowercased().contains("heard birch") }
        }
        XCTAssertFalse(vm.messages.contains { $0.content == "echo cedar" }, "the fork still shows the old branch's turn")
        XCTAssertTrue(vm.messages.contains { $0.content.lowercased().contains("heard maple") }, "the fork lost the turn before it")
        await waitForText("heard birch")
        let forked = try XCTUnwrap(vm.messages.first { $0.role == .user && $0.content == "echo birch" })
        XCTAssertEqual(forked.parentID, original.parentID, "the edit didn't fork from the same point")
        await waitFor("the fork point never offered both branches", timeout: 10) {
            vm.branchInfo(for: forked.id)?.siblingIDs.count == 2
        }
    }

    /// Save and Resend on the conversation's first message forks beside it
    /// as a new root, rather than appending to the end.
    func testEditAndResendTheFirstMessageForksAtTheRoot() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Edit resend root")
        try await seedTurn(app, conv, "echo maple")
        try await seedTurn(app, conv, "echo cedar")
        _ = await open(conv, app, convos, minMessages: 4)
        let vm = built.last!.0
        let first = try XCTUnwrap(vm.messages.first { $0.role == .user && $0.content == "echo maple" })
        XCTAssertNil(first.parentID, "the first message should start the context")
        await menu(first, "Edit", vm)
        await waitFor("the edit card never opened") { vm.editingMessage?.id == first.id }
        let editor = try XCTUnwrap(editableTextView(showing: "echo maple"), "no editor holding the message")
        editor.selectAll(nil)
        editor.insertText("echo birch")
        await spin(0.3)
        await press("Save and Resend")
        await waitFor("the fork never streamed its reply", timeout: 25) {
            !vm.isStreaming && vm.messages.contains { $0.content.lowercased().contains("heard birch") }
        }
        XCTAssertEqual(vm.messages.first?.content, "echo birch", "the fork didn't start the branch")
        XCTAssertFalse(vm.messages.contains { $0.content == "echo cedar" }, "the resend appended to the old branch")
        let forked = try XCTUnwrap(vm.messages.first { $0.role == .user && $0.content == "echo birch" })
        XCTAssertNil(forked.parentID)
        await waitFor("the first message never offered both branches", timeout: 10) {
            vm.branchInfo(for: forked.id)?.siblingIDs.count == 2
        }
    }

    /// Edit and plain Save rewrites the message in place, on the server.
    func testEditAndSaveRewritesInPlace() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Edit save")
        try await seedTurn(app, conv, "echo poplar")
        _ = await open(conv, app, convos, minMessages: 2)
        let vm = built.last!.0
        let reply = try XCTUnwrap(vm.messages.last { $0.role == .assistant })
        await menu(reply, "Edit", vm)
        let editor = try XCTUnwrap(editableTextView(showing: String(reply.content.prefix(20))), "no editor holding the reply")
        editor.selectAll(nil)
        editor.insertText("A rewritten reply about willows.")
        await spin(0.3)
        await press("Save")
        await eventually("the edit never reached the server") {
            try await self.messages(app, conv).contains { $0.id == reply.id && $0.content == "A rewritten reply about willows." }
        }
        await waitForText("rewritten reply about willows")
    }

    /// Delete one message, then Delete from Here on an earlier one.
    func testDeleteAndDeleteFromHere() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Delete")
        try await seedTurn(app, conv, "echo aspen")
        try await seedTurn(app, conv, "echo larch")
        _ = await open(conv, app, convos, minMessages: 4)
        let (vm, ui) = built.last!
        let lastReply = try XCTUnwrap(vm.messages.last { $0.role == .assistant })
        await menu(lastReply, "Delete", vm)
        XCTAssertEqual(ui.confirmingDelete?.messageID, lastReply.id, "Delete asks in place first")
        ui.confirmDelete(model: vm)  // the confirm card's Delete
        await eventually("the deleted reply is still on the server") {
            try await !self.messages(app, conv).contains { $0.id == lastReply.id }
        }
        await waitFor("the deleted reply still shows") { !vm.messages.contains { $0.id == lastReply.id } }

        let firstUser = try XCTUnwrap(vm.messages.first { $0.role == .user && $0.content == "echo aspen" })
        await menu(firstUser, "Delete from Here", vm)
        XCTAssertEqual(ui.confirmingDelete?.cascade, true)
        ui.confirmDelete(model: vm)
        await eventually("Delete from Here left messages on the server") {
            try await !self.messages(app, conv).contains { $0.role == .user }
        }
        await waitFor("the transcript still shows the deleted turns") { !vm.messages.contains { $0.role == .user } }
    }

    // MARK: Attachments

    /// An image pasted into the composer uploads, shows as a chip, and goes
    /// out with the message.
    func testPastedImageGoesOutWithTheMessage() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Attach")
        _ = await open(conv, app, convos)
        let vm = built.last!.0
        XCTAssertTrue(vm.canAttachFiles, "the seeded model takes images")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        // PasteAwareTextField's onImagePaste.
        await vm.attachImage(data: png, originalFilename: nil)
        XCTAssertEqual(vm.pendingAttachments.count, 1, "the paste never became a chip. error=\(vm.loadError ?? "nil")")
        await waitFor("the chip never showed") { self.element("Remove attachment") != nil }
        await typeMessage("echo pebble")
        await press("Send")
        // A message with an image goes out multi-part, which the fake
        // model answers with its canned reply.
        await waitFor("the send never finished", timeout: 25) {
            !vm.isStreaming && vm.messages.last?.role == .assistant && vm.messages.contains { $0.content == "echo pebble" }
        }
        let msgs = try await messages(app, conv)
        let sent = try XCTUnwrap(msgs.first { $0.role == .user })
        XCTAssertEqual(sent.attachments.count, 1, "the image didn't go out with the message")
        XCTAssertTrue(vm.pendingAttachments.isEmpty, "the chip stayed after sending")
    }

    // MARK: Compress

    /// Compress from the context banner's flow: the card, the run, the
    /// review card, and Confirm moving the conversation to a new context.
    func testCompressReviewThenConfirmStartsANewContext() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Compress")
        try await seedTurn(app, conv, "echo granite")
        try await seedTurn(app, conv, "echo basalt")
        _ = await open(conv, app, convos, minMessages: 4)
        let (vm, ui) = built.last!
        let firstContext = vm.activeContext?.id
        ui.openCompress(model: vm)
        await waitFor("the compress card never prepared", timeout: 10) { !vm.preparingCompactView && vm.showingCompactView }
        // The card's Instructions field: a profile without a compression
        // guide needs one typed here.
        if vm.compactPromptDraft.isEmpty { vm.compactPromptDraft = "Summarize the conversation in a few lines." }
        // And its Summarize with picker, for a profile with no compression model.
        if vm.compactModelID == nil {
            vm.compactProviderID = seeded.provider.id
            vm.compactModelID = "model-one"
        }
        ui.startCompress(model: vm)  // the card's Compress button
        await waitFor("the compression never produced a summary to review", timeout: 30) {
            !vm.isCompacting && vm.pendingCompressionSummary != nil
        }
        await waitForText("awaiting review")
        await press(containing: "Confirm")
        await waitFor("Confirm never moved to the new context", timeout: 15) {
            vm.pendingCompressionSummary == nil && vm.activeContext?.id != firstContext
        }
        let (live, ctx) = try await app.client.conversations.get(id: conv.id)
        XCTAssertNotEqual(ctx.id, firstContext, "the server is still on the old context")
        XCTAssertEqual(live.activeContextID, vm.activeContext?.id)
        // The new context takes a message.
        try await sendAndWatch(window!, name: "after-compress", text: "echo obsidian", user: "echo obsidian",
                               reply: "heard obsidian")

        // Back to the first context from Info, then forward again: each
        // switch shows that context's own messages.
        let w = window!
        // What sits at each context's end: the first ends on its summary.
        for (target, word, row, seen) in [(firstContext, "basalt", "5 messages", "compression summary"),
                                          (ctx.id, "obsidian", "3 messages", "heard obsidian")] {
            built.last!.1.page = .info
            await waitFor("Info never pushed") { E2ETimeline.navigationDepth(w) >= 3 }
            await spin(0.6)
            await press(containing: row)
            await eventually("the server never switched context", timeout: 10) {
                try await app.client.conversations.get(id: conv.id).1.id == target
            }
            await waitFor("Info never closed") { E2ETimeline.navigationDepth(w) == 2 }
            await waitFor("the screen never showed the switched-to context's messages", timeout: 10) {
                let m = self.built.last!.0
                return m.activeContext?.id == target && m.messages.contains { $0.content == "echo \(word)" }
            }
            await waitForText(seen)
        }
    }

    /// The review card's Delete throws the summary away and the
    /// conversation carries on in the same context.
    func testCompressThenDeleteTheSummaryStaysInTheContext() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Compress delete")
        try await seedTurn(app, conv, "echo quartz")
        _ = await open(conv, app, convos, minMessages: 2)
        let (vm, ui) = built.last!
        let context = vm.activeContext?.id
        ui.openCompress(model: vm)
        await waitFor("the compress card never prepared", timeout: 10) { !vm.preparingCompactView && vm.showingCompactView }
        // The card's Instructions field: a profile without a compression
        // guide needs one typed here.
        if vm.compactPromptDraft.isEmpty { vm.compactPromptDraft = "Summarize the conversation in a few lines." }
        // And its Summarize with picker, for a profile with no compression model.
        if vm.compactModelID == nil {
            vm.compactProviderID = seeded.provider.id
            vm.compactModelID = "model-one"
        }
        ui.startCompress(model: vm)
        await waitFor("no summary to review", timeout: 30) { !vm.isCompacting && vm.pendingCompressionSummary != nil }
        // No wait for the compression's closing reload: the delete must win
        // even with that load still in flight.
        // The review card's Delete, then its confirm.
        ui.confirmingSummaryDelete = true
        await waitForText("delete the summary?")
        let summary = try XCTUnwrap(vm.pendingCompressionSummary)
        ui.confirmingSummaryDelete = false
        await vm.deleteMessage(id: summary.id)
        await waitFor("the summary never went", timeout: 15) { vm.pendingCompressionSummary == nil }
        XCTAssertEqual(vm.activeContext?.id, context)
        let msgs = try await messages(app, conv)
        XCTAssertFalse(msgs.contains { $0.role == .compressionSummary }, "the summary is still on the server")
    }

    // MARK: Helpers

    private func editableTextView(showing prefix: String) -> UITextView? {
        guard let window else { return nil }
        func find(_ v: UIView) -> UITextView? {
            if v.isHidden { return nil }
            if let t = v as? UITextView, t.isEditable, t.text.hasPrefix(prefix) { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return find(window)
    }
}

/// A clipboard that remembers what was written to it.
final class RecordingClipboard: Clipboard, @unchecked Sendable {
    private(set) var written: [String] = []
    func write(_ text: String) { written.append(text) }
    func read() -> String? { written.last }
}
