import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The pages a conversation pushes (Info and its tabs, Call settings, the
/// model picker, the full-text reader, New context) end to end: each one
/// opened from the conversation the way its control opens it, its change
/// read back from the server, and the page shown again after it's rebuilt.
@MainActor
final class ConversationPagesE2ETests: E2ETestCase {

    private func open(_ conv: PsmithConversation, _ app: AppModel, _ convos: ConversationsModel,
                      minMessages: Int = 0) async -> UIWindow {
        await convos.refresh()
        let w = mountStack(.conversation(conv), app: app, convos: convos)
        await waitFor("the conversation never loaded", timeout: 20) {
            built.last.map { !$0.0.loading && $0.0.hasLoadedFromServer && $0.0.messages.count >= minMessages } ?? false
        }
        return w
    }

    private func push(_ page: ConversationPage, _ w: UIWindow) async {
        built.last!.1.page = page
        await waitFor("\(page) never pushed") { E2ETimeline.navigationDepth(w) >= 3 }
        await spin(0.6)
    }

    private func pop(_ w: UIWindow) async {
        built.last!.1.page = nil
        await waitFor("the page never popped") { E2ETimeline.navigationDepth(w) == 2 }
        await waitFor("the conversation never reloaded", timeout: 15) {
            built.last.map { $0.0.hasLoadedFromServer && !$0.0.loading } ?? false
        }
    }

    // MARK: Info

    func testInfoReadsOutTheConversationAndItsTabs() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Info tabs")
        try await seedTurn(app, conv, "echo heron")
        let w = await open(conv, app, convos, minMessages: 2)
        await push(.info, w)
        await waitForText("contexts")
        await waitForText("alpha")  // the Profile row
        await press("Settings")
        await waitForText("model one")
        await press("Plugins")
        await spin(0.5)
        await press("Context")
        await waitForText("contexts")
    }

    func testInfoPinsAndArchives() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Info actions")
        let w = await open(conv, app, convos)
        await push(.info, w)
        await press("Pin")
        await eventually("Pin never reached the server") { try await app.client.conversations.get(id: conv.id).0.pinnedAt != nil }
        await waitFor("the row never turned into Unpin") { self.element("Unpin") != nil }
        await press("Unpin")
        await eventually("Unpin never reached the server") { try await app.client.conversations.get(id: conv.id).0.pinnedAt == nil }

        await press("Archive")
        await eventually("Archive never reached the server") {
            try await app.client.conversations.get(id: conv.id).0.archivedAt != nil
        }
        await waitFor("Archive didn't leave the page") { E2ETimeline.navigationDepth(w) <= 2 }
    }

    func testInfoDeletesTheConversationAfterAsking() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Info delete")
        let w = await open(conv, app, convos)
        await push(.info, w)
        await press("Delete Conversation")
        await waitForText("delete this conversation?")
        await press("Delete")
        await eventually("the conversation is still on the server") {
            do { _ = try await app.client.conversations.get(id: conv.id); return false } catch { return true }
        }
        await waitFor("Delete didn't leave the page") { E2ETimeline.navigationDepth(w) <= 2 }
    }

    /// New context, from Info's plus: the conversation moves to it, and
    /// the Contexts list on Info shows both.
    func testNewContextFromInfo() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "New context")
        try await seedTurn(app, conv, "echo ember")
        let w = await open(conv, app, convos, minMessages: 2)
        let before = try await app.client.conversations.get(id: conv.id).1.id
        await push(.info, w)
        await press("New context")
        await waitForText("create context")
        await press(containing: "Create Context")
        await eventually("the server never moved to a new context", timeout: 15) {
            try await app.client.conversations.get(id: conv.id).1.id != before
        }
        let contexts = try await app.client.conversations.listContexts(conversationID: conv.id)
        XCTAssertEqual(contexts.count, 2)
        await waitFor("the screen never followed to the new context", timeout: 10) {
            self.built.last!.0.activeContext?.id != before
        }
    }

    /// Switching back to an older context from Info's Contexts list: the
    /// conversation returns showing that context's messages.
    func testSwitchingToAnOlderContextShowsItsMessages() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Old context")
        try await seedTurn(app, conv, "echo ember")
        let first = try await app.client.conversations.get(id: conv.id).1.id
        _ = try await app.client.conversations.createContextManual(conversationID: conv.id,
                                                                   initialUserMessage: "echo frost", mode: .replace)
        let w = await open(conv, app, convos)
        await waitFor("the conversation didn't open on the new context") {
            self.built.last!.0.activeContext?.id != first
        }
        // A page visited earlier, as in normal use, before Info.
        await push(.models, w)
        await pop(w)
        await push(.info, w)
        // The old context is named after the conversation's first title.
        await press(containing: "2 messages")
        await eventually("the server never activated the old context", timeout: 10) {
            try await app.client.conversations.get(id: conv.id).1.id == first
        }
        await waitFor("Info never closed") { E2ETimeline.navigationDepth(w) == 2 }
        await waitFor("the screen never showed the old context's messages", timeout: 10) {
            let m = self.built.last!.0
            return m.activeContext?.id == first && m.messages.contains { $0.content == "echo ember" }
        }
        await waitForText("heard ember")
    }

    /// Runs a transcript row's long-press through its accessibility action,
    /// which calls the same closure the gesture does.
    private func longPress(_ text: String) async {
        func find() -> NSObject? {
            elements().last {
                ($0.accessibilityLabel ?? "").contains(text)
                    && ($0.accessibilityCustomActions ?? []).contains { $0.name == "Message actions" }
            }
        }
        let end = Date().addingTimeInterval(5)
        var row = find()
        while row == nil && Date() < end { await spin(0.2); row = find() }
        guard let row, let action = row.accessibilityCustomActions?.first(where: { $0.name == "Message actions" }) else {
            let carriers = elements().filter { ($0.accessibilityCustomActions ?? []).contains { $0.name == "Message actions" } }
                .map { "\(Swift.type(of: $0)) label=\($0.accessibilityLabel ?? "-") el=\($0.isAccessibilityElement)" }
            let named = elements().filter { ($0.accessibilityLabel ?? "").contains(text) }
                .map { "\(Swift.type(of: $0)) actions=\(($0.accessibilityCustomActions ?? []).map(\.name))" }
            return XCTFail("no row “\(text)” with Message actions. Carriers: \(carriers). Named: \(named)")
        }
        if let handler = action.actionHandler { _ = handler(action) } else if let t = action.target as? NSObject {
            t.perform(action.selector, with: action)
        }
        await spin(0.7)
    }

    /// After a page pops, a row's menu still deletes and edits that
    /// message: the screen's transcript is the view model it acts on.
    func testMessageActionsWorkAfterAPagePops() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Actions after pop")
        try await seedTurn(app, conv, "echo maple")
        try await seedTurn(app, conv, "echo cedar")
        let w = await open(conv, app, convos, minMessages: 4)
        await push(.info, w)
        await pop(w)

        await longPress("echo cedar")
        await waitFor("the menu never opened on the screen's model") { self.built.last!.0.actionMenuMessage != nil }
        await press("Delete")
        await waitForText("delete this message?")
        await press("Delete")
        await eventually("the delete never reached the server") {
            try await self.messages(app, conv).allSatisfy { $0.content != "echo cedar" }
        }

        await longPress("echo maple")
        await press("Edit")
        await waitFor("the edit card never opened") { self.built.last!.0.editingMessage != nil }
        await waitForText("save and resend")
    }

    // MARK: Call settings

    /// A change on Call settings saves to the conversation on the server
    /// and is there when the page opens again.
    func testCallSettingsSaveAndShowOnReturn() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Call settings")
        let w = await open(conv, app, convos)
        await push(.callSettings, w)
        await waitForText("max output tokens")
        await press("Increase max output tokens")
        await press("Increase max output tokens")
        await press("Save")
        var saved: Int32?
        await eventually("the override never reached the server") {
            saved = try await app.client.conversations.get(id: conv.id).0.settings?.callSettings?.maxOutputTokens
            return saved != nil
        }
        await pop(w)
        await push(.callSettings, w)
        let shown = try XCTUnwrap(saved).formatted().lowercased()
        await waitForText(shown)
        XCTAssertEqual(built.last!.0.conversationCallSettingsDraft.maxOutputTokens, saved,
                       "the rebuilt page didn't load the saved override")
    }

    // MARK: Model picker

    func testModelPickerPicksAndPopsBack() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Picker")
        let w = await open(conv, app, convos)
        await push(.models, w)
        await waitForText("model two")
        await press(containing: "Model Two")
        await waitFor("picking didn't pop the page") { E2ETimeline.navigationDepth(w) == 2 }
        await eventually("the pick never reached the server") {
            try await app.client.conversations.get(id: conv.id).0.settings?.defaultModelID == "model-two"
        }
        await waitFor("the screen doesn't show the pick", timeout: 15) { self.built.last!.0.selectedModelID == "model-two" }

        // And back to the profile's own model, which unpins it.
        await push(.models, w)
        await press(containing: "Use the profile")
        await waitFor("picking didn't pop the page") { E2ETimeline.navigationDepth(w) == 2 }
        await eventually("the conversation is still pinned to model two") {
            try await app.client.conversations.get(id: conv.id).0.settings?.defaultModelID != "model-two"
        }
    }

    // MARK: Full text

    /// Select Text on your own message opens it whole on the reader page.
    func testFullTextShowsTheWholeMessage() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Reader")
        try await seedTurn(app, conv, "echo kestrel and a reasonably long tail so the reader has something to show")
        let w = await open(conv, app, convos, minMessages: 2)
        let vm = built.last!.0
        let mine = try XCTUnwrap(vm.messages.first { $0.role == .user })
        vm.actionMenuMessage = mine
        await press("Select Text")
        await waitFor("the reader never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await waitForText("message text")
        await waitForText("reasonably long tail")
    }

    // MARK: Rename from the title

    func testRenameFromTheTitle() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Title rename")
        _ = await open(conv, app, convos)
        await press("\(conv.title!), rename conversation")
        await waitFor("the title never became a field") { self.field("Conversation title") != nil }
        let title = "Retitled \(seeded.tag)"
        await type(title, into: try XCTUnwrap(field("Conversation title")))
        await press("Done")
        await eventually("the title never reached the server") {
            try await app.client.conversations.get(id: conv.id).0.title == title
        }
        await waitForText("retitled")
    }
}
