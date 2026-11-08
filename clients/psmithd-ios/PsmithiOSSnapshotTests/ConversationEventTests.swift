import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The conversation's controls, driven through the same calls their
/// buttons make, with the screen mounted in a real window around each
/// step so every state renders. SwiftUI builds no accessibility tree in
/// a unit-test host, so the controls can't be found and tapped by label.
@MainActor
final class ConversationEventTests: XCTestCase {
    private var window: UIWindow?
    private var app: AppModel!

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func mount(_ s: ConversationProbeTests.Setup) -> (ConversationViewModel, ConversationUIState) {
        app = SnapshotStubs.makeAppModel(models: [Convo.opus, Convo.haiku], profiles: s.profiles,
                                         connectivityState: s.offline ? .offline : .online)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: s.conversations, profiles: s.profiles)
        let vm = Convo.model(s.messages, conversation: s.conversation, client: app.client, tokenCount: s.tokenCount,
                             contextWindow: s.contextWindow, stream: s.stream, draft: s.draft)
        let ui = ConversationUIState()
        s.configure(vm, ui)
        let root = ProbeHost(model: vm, ui: ui, elicit: s.elicit)
            .environment(app)
            .environment(convos)
            .environment(\.theme, .slate)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = UIHostingController(rootView: root)
        w.isHidden = false
        window = w
        settle()
        return (vm, ui)
    }

    private func settle(_ turns: Int = 6) {
        for _ in 0..<turns { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        window?.layoutIfNeeded()
    }

    /// Waits for the snapshot host's refused connection to come back.
    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }

    // MARK: Composer

    func testSendClearsTheDraftAndPostsTheQuestion() {
        let (vm, ui) = mount(.init(draft: "And past a few hundred?"))
        let composer = Composer(model: vm, ui: ui)
        XCTAssertTrue(composer.canSend)
        composer.send()
        // The send goes out, fails against the absent server, and hands
        // the words back to the composer rather than losing them.
        waitFor("send never reached the server") { vm.loadError != nil }
        XCTAssertEqual(vm.draft, "And past a few hundred?")
        XCTAssertNil(vm.pendingUserText)
    }

    func testSendIsRefusedWithNothingToSay() {
        let (vm, ui) = mount(.init(draft: "   "))
        let composer = Composer(model: vm, ui: ui)
        XCTAssertFalse(composer.canSend)
        composer.send()
        settle()
        XCTAssertEqual(vm.draft, "   ")
        XCTAssertNil(vm.pendingUserText)
    }

    func testStopCancelsTheReply() {
        var stopped = 0
        let (vm, ui) = mount(.init(messages: Convo.streamingHistory, stream: Convo.stream(text: "Past a few hundred rows")))
        XCTAssertTrue(vm.isStreaming)
        Composer(model: vm, ui: ui, onStop: { stopped += 1 }).stop()
        XCTAssertEqual(stopped, 1)
    }

    func testTrayOpensAndCloses() {
        let (vm, ui) = mount(.init())
        let composer = Composer(model: vm, ui: ui)
        composer.toggleTray()
        settle()
        XCTAssertTrue(ui.trayOpen)
        composer.toggleTray()
        settle()
        XCTAssertFalse(ui.trayOpen)
    }

    func testCompressTakesTheSlotAndCancelGivesItBack() {
        let (vm, ui) = mount(.init(configure: { _, ui in ui.trayOpen = true }))
        // The tray's Compress tile.
        ui.openCompress(model: vm)
        settle()
        XCTAssertTrue(vm.showingCompactView)
        XCTAssertFalse(ui.trayOpen, "the tray closes when compress takes the slot")
        // The card's Cancel.
        ui.cancelCompress(model: vm)
        settle()
        XCTAssertFalse(vm.showingCompactView)
    }

    func testCompressStartsAndGivesTheSlotBack() {
        let (vm, ui) = mount(.init(configure: { vm, _ in
            vm.showingCompactView = true
            vm.compactPromptDraft = "Keep decisions."
            vm.compactProviderID = Convo.anthropic
            vm.compactModelID = "claude-haiku-4-5"
        }))
        ui.startCompress(model: vm)
        XCTAssertFalse(vm.showingCompactView)
        // The call fails against the absent server; the card comes back
        // holding the error.
        waitFor("compress never reached the server") { vm.compactError != nil }
        XCTAssertTrue(vm.showingCompactView)
    }

    // MARK: Messages

    func testDeleteAsksInPlaceThenDeletes() {
        let states = Convo.states
        let (vm, ui) = mount(.init(messages: states))
        // Long-press menu, then Delete: the row turns into the question.
        vm.actionMenuMessage = states[1]
        settle()
        ui.requestDelete(states[1])
        vm.actionMenuMessage = nil
        settle()
        XCTAssertEqual(ui.confirmingDelete, .init(messageID: "a1", cascade: false))
        ui.cancelDelete()
        settle()
        XCTAssertNil(ui.confirmingDelete)
        XCTAssertNil(vm.loadError, "cancel must not delete")

        ui.requestDelete(states[1])
        settle()
        ui.confirmDelete(model: vm)
        settle()
        XCTAssertNil(ui.confirmingDelete)
        waitFor("the delete never reached the server") { vm.loadError != nil }
    }

    func testInlineEditSaves() {
        let states = Convo.states
        let (vm, _) = mount(.init(messages: states) { vm, _ in vm.editingMessage = states[2] })
        MessageEditCard(message: states[2], model: vm).save()
        settle()
        XCTAssertNil(vm.editingMessage)
        waitFor("the edit never reached the server") { vm.loadError != nil }
    }

    func testUsageOpensUnderTheReply() {
        let (_, ui) = mount(.init(messages: Convo.usageBoard))
        ui.toggleUsage("a1")
        settle()
        XCTAssertTrue(ui.usageExpanded.contains("a1"))
        ui.toggleUsage("a1")
        settle()
        XCTAssertFalse(ui.usageExpanded.contains("a1"))
    }
}
