import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The chats list end to end: the real ChatsRoot (or its list screen, for
/// the row actions whose state ChatsRoot keeps private) over a real
/// server. Every action is checked where it lands, on the server, and
/// where the user sees it, on screen.
@MainActor
final class ChatsE2ETests: E2ETestCase {

    @discardableResult
    private func mountRoot(_ app: AppModel, _ convos: ConversationsModel) -> UIWindow {
        mount(ChatsRoot(user: app.authState.currentUser!), app: app, convos: convos)
    }

    /// The list screen over state the test holds, the way ChatsRoot holds
    /// it, so a row action's in-place states (confirm card, rename field,
    /// selection) can be driven and read.
    @discardableResult
    private func mountList(_ state: ListState, _ app: AppModel, _ convos: ConversationsModel) -> UIWindow {
        mount(E2EListHost(state: state, user: app.authState.currentUser!), app: app, convos: convos)
    }

    private func actions(_ state: ListState, _ convos: ConversationsModel) -> ChatRowActions {
        let s = Bindable(state)
        return ChatRowActions(convos: convos, confirmingDelete: s.confirmingDelete, renaming: s.renaming,
                              renameDraft: s.renameDraft)
    }

    private func live(_ app: AppModel, _ id: String) async throws -> PsmithConversation {
        try await app.client.conversations.get(id: id).0
    }

    // MARK: List and search

    func testListShowsServerConversationsAndSearchNarrowsThem() async throws {
        let (app, convos, seeded) = try await signedIn()
        let aardvark = try await makeConversation(app, seeded, title: "Aardvark")
        let zebra = try await makeConversation(app, seeded, title: "Zebra")
        await convos.refresh()
        mountRoot(app, convos)
        await waitForText(words(aardvark))
        await waitForText(words(zebra))

        let search = try XCTUnwrap(field("Search"), "no search field")
        await type("Aardvark \(seeded.tag)", into: search)
        await waitFor("the search never narrowed the list on the server", timeout: 10) {
            convos.listMode == .search && convos.conversations.map(\.id) == [aardvark.id]
        }
        await waitForText("1 result")
        XCTAssertFalse(screenText().contains(words(zebra).lowercased()), "a non-matching conversation still shows")

        await press("Clear search")
        await waitFor("clearing the search never brought the list back") {
            convos.listMode == .allChats && convos.conversations.contains { $0.id == zebra.id }
        }
        await waitForText(words(zebra))
    }

    /// A conversation created on another device lands in the list from the
    /// account event stream, without a pull. "Another device" is a second
    /// client signed in as the same user: the stream skips the echo of
    /// this client's own changes.
    func testAConversationMadeElsewhereShowsUpWithoutARefresh() async throws {
        let (app, convos, seeded) = try await signedIn()
        let s = try server()
        let other = AppModel(host: s.url, tokenStore: InMemoryTokenStore(), connectivityState: .online)
        _ = try await other.client.auth.login(username: s.user, password: s.password)
        mountRoot(app, convos)
        // The account event stream has to be up before the change it
        // should carry.
        await spin(3)
        let elsewhere = try await makeConversation(other, seeded, title: "Elsewhere")
        await waitFor("the new conversation never reached the list", timeout: 20) {
            convos.conversations.contains { $0.id == elsewhere.id }
        }
        await waitForText(words(elsewhere))
    }

    // MARK: Row actions

    func testPinAndUnpinFromTheRow() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "Pinnable")
        await convos.refresh()
        let state = ListState()
        mountList(state, app, convos)
        await waitForText(words(c))

        let row = try XCTUnwrap(convos.conversations.first { $0.id == c.id })
        XCTAssertEqual(ChatRowAction.swipeLeading(row), [.pin])
        actions(state, convos).perform(.pin, on: row)
        await eventually("pin never reached the server") { try await self.live(app, c.id).pinnedAt != nil }
        await waitFor("the list never showed the pin") { convos.conversations.first { $0.id == c.id }?.pinnedAt != nil }
        await waitFor("the row never showed its pin") { self.element("Pinned") != nil }
        XCTAssertEqual(convos.conversations.first?.id, c.id, "a pinned conversation leads the list")

        let pinned = try XCTUnwrap(convos.conversations.first { $0.id == c.id })
        XCTAssertEqual(ChatRowAction.swipeLeading(pinned), [.unpin])
        actions(state, convos).perform(.unpin, on: pinned)
        await eventually("unpin never reached the server") { try await self.live(app, c.id).pinnedAt == nil }
        await waitFor("the row still shows its pin") { self.element("Pinned") == nil }
    }

    func testRenameInPlaceSavesTheTitle() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "Before rename")
        await convos.refresh()
        let state = ListState()
        mountList(state, app, convos)
        await waitForText(words(c))

        actions(state, convos).perform(.rename, on: try XCTUnwrap(convos.conversations.first { $0.id == c.id }))
        await waitFor("the row never became a field") { self.textFields().contains { $0.text == c.title } }
        let field = try XCTUnwrap(textFields().first { $0.text == c.title })
        let title = "Renamed \(seeded.tag)"
        await type(title, into: field)
        // The return key: UIKit asks the delegate, then fires the
        // did-end-on-exit action SwiftUI's onSubmit listens to.
        if field.delegate?.textFieldShouldReturn?(field) ?? true { field.sendActions(for: .editingDidEndOnExit) }
        await eventually("the new title never reached the server") { try await self.live(app, c.id).title == title }
        XCTAssertNil(state.renaming, "Done closes the field")
        await waitForText("renamed")
    }

    func testArchiveThenUnarchiveFromTheArchive() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "Archivable")
        // Something stays active: with nothing active the list shows its
        // empty state, which has no filter chips.
        _ = try await makeConversation(app, seeded, title: "Keeper")
        await convos.refresh()
        let state = ListState()
        mountList(state, app, convos)
        await waitForText(words(c))

        actions(state, convos).perform(.archive, on: try XCTUnwrap(convos.conversations.first { $0.id == c.id }))
        await eventually("archive never reached the server") { try await self.live(app, c.id).archivedAt != nil }
        await waitFor("the archived conversation is still in the active list") {
            !convos.conversations.contains { $0.id == c.id }
        }

        // The Archived chip, as ChatsRoot runs it.
        await press("Archived")
        await convos.loadArchived()
        XCTAssertEqual(state.filter, .archived)
        await waitForText(words(c))
        let archived = try XCTUnwrap(convos.archivedConversations.first { $0.id == c.id })
        XCTAssertEqual(ChatRowAction.swipeTrailing(archived), [.delete, .unarchive])
        actions(state, convos).perform(.unarchive, on: archived)
        await eventually("unarchive never reached the server") { try await self.live(app, c.id).archivedAt == nil }
        await waitFor("the conversation never came back to the active list") {
            convos.conversations.contains { $0.id == c.id } && !convos.archivedConversations.contains { $0.id == c.id }
        }
        await press("All")
        await waitForText(words(c))
    }

    func testDeleteAsksInPlaceThenDeletes() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "Deletable")
        await convos.refresh()
        let state = ListState()
        mountList(state, app, convos)
        await waitForText(words(c))

        actions(state, convos).perform(.delete, on: try XCTUnwrap(convos.conversations.first { $0.id == c.id }))
        XCTAssertEqual(state.confirmingDelete, c.id)
        await press("Cancel")
        XCTAssertNil(state.confirmingDelete)
        _ = try await live(app, c.id)  // still there

        actions(state, convos).perform(.delete, on: try XCTUnwrap(convos.conversations.first { $0.id == c.id }))
        await press("Delete")
        await eventually("the conversation is still on the server") {
            do { _ = try await self.live(app, c.id); return false } catch { return true }
        }
        await waitFor("the row is still in the list") { !convos.conversations.contains { $0.id == c.id } }
        await spin(0.5)
        XCTAssertFalse(screenText().contains(words(c).lowercased()), "the deleted row still shows")
    }

    func testSelectModePinsArchivesAndDeletesInBulk() async throws {
        let (app, convos, seeded) = try await signedIn()
        let a = try await makeConversation(app, seeded, title: "Bulk A")
        let b = try await makeConversation(app, seeded, title: "Bulk B")
        await convos.refresh()
        let state = ListState()
        state.selecting = true
        mountList(state, app, convos)
        await waitForText(words(a))

        await press(containing: a.title!)
        await press(containing: b.title!)
        XCTAssertEqual(state.selection, [a.id, b.id])
        await press("Pin")
        await eventually("bulk pin never reached the server") {
            let pa = try await self.live(app, a.id).pinnedAt, pb = try await self.live(app, b.id).pinnedAt
            return pa != nil && pb != nil
        }
        await press("Archive")
        await eventually("bulk archive never reached the server") {
            let xa = try await self.live(app, a.id).archivedAt, xb = try await self.live(app, b.id).archivedAt
            return xa != nil && xb != nil
        }
        XCTAssertTrue(state.selection.isEmpty, "archiving clears the selection")

        let c = try await makeConversation(app, seeded, title: "Bulk C")
        let d = try await makeConversation(app, seeded, title: "Bulk D")
        await convos.refresh()
        await press(containing: c.title!)
        await press(containing: d.title!)
        await press("Delete 2")
        XCTAssertTrue(state.confirmingBulkDelete, "bulk delete asks first")
        await press("Delete")
        await eventually("bulk delete never reached the server") {
            for id in [c.id, d.id] { if (try? await self.live(app, id)) != nil { return false } }
            return true
        }
        XCTAssertFalse(state.selecting, "deleting leaves select mode")
    }

    // MARK: Into a conversation

    /// The path the user takes on device: tap a row, type, tap Send. The
    /// message and the reply show from the moment they appear.
    func testOpeningARowAndSendingShowsBothMessages() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "From the list")
        try await seedTurn(app, c, "echo cobalt")
        await convos.refresh()
        let w = mountRoot(app, convos)
        await waitForText(words(c))
        await press(containing: c.title!)
        await waitFor("the conversation never pushed") { E2ETimeline.navigationDepth(w) == 2 }
        await waitForText("heard cobalt", timeout: 15)
        try await typeAndWatch(w, app: app, conv: c, word: "saffron", name: "list-open-send")
    }

    /// The same while the list refreshes underneath, as the account event
    /// stream makes it do on every send and terminal.
    func testSendingWhileTheListRefreshesUnderneath() async throws {
        let (app, convos, seeded) = try await signedIn()
        let c = try await makeConversation(app, seeded, title: "Busy list")
        try await seedTurn(app, c, "echo cobalt")
        await convos.refresh()
        let w = mountRoot(app, convos)
        await waitForText(words(c))
        await press(containing: c.title!)
        await waitForText("heard cobalt", timeout: 15)
        let refresher = Task { @MainActor in
            for _ in 0..<40 {
                await convos.refresh()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { refresher.cancel() }
        try await typeAndWatch(w, app: app, conv: c, word: "thistle", name: "list-refresh-send")
    }

    /// New conversation from the list's button: nothing exists until the
    /// first send, which creates it, lists it and streams its reply.
    func testNewConversationFromTheListCreatesItOnFirstSend() async throws {
        let (app, convos, _) = try await signedIn()
        let before = Set(convos.conversations.map(\.id))
        let w = mountRoot(app, convos)
        await press("New conversation")
        await waitFor("the draft never pushed") { E2ETimeline.navigationDepth(w) == 2 }
        await spin(1.5)
        await typeMessage("echo juniper")
        await press("Send")
        await waitFor("the first send never listed the new conversation", timeout: 15) {
            convos.conversations.contains { !before.contains($0.id) }
        }
        let created = try XCTUnwrap(convos.conversations.first { !before.contains($0.id) })
        await waitForText("heard juniper", timeout: 20)
        let msgs = try await messages(app, created)
        XCTAssertTrue(msgs.contains { $0.role == .user && $0.content == "echo juniper" })
    }

    /// Types into the composer, taps Send and records the screen until the
    /// server has the reply and it has settled on screen.
    private func typeAndWatch(_ w: UIWindow, app: AppModel, conv: PsmithConversation, word: String, name: String) async throws {
        let user = "echo \(word)", reply = "heard \(word)"
        let tl = E2ETimeline(name: name)
        defer { tl.write() }
        await typeMessage(user)
        tl.sample(w, "typed", needles: [user, reply])
        await press("Send")
        let sentAt = tl.samples.last!.t
        // record() takes a sync condition; the server is polled beside it.
        @MainActor final class Flag { var at: Date? }
        let replied = Flag()
        let poll = Task { @MainActor in
            while replied.at == nil && !Task.isCancelled {
                if let msgs = try? await self.messages(app, conv),
                   msgs.contains(where: { $0.role == .assistant && $0.content.lowercased().contains(reply) }) {
                    replied.at = Date()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poll.cancel() }
        await tl.record(w, timeout: 30, needles: [user, reply], state: { replied.at == nil ? "" : "server has reply" }) {
            replied.at.map { Date().timeIntervalSince($0) > 3 } ?? false
        }
        XCTAssertNotNil(replied.at, "the reply never landed on the server. Frames: \(tl.dir.path)")
        XCTAssertEqual(tl.gaps(user, from: sentAt + 1).map(\.t), [],
                       "the user's message was missing from these frames (seconds). Frames: \(tl.dir.path)")
        if let first = tl.firstSeen(reply) {
            XCTAssertEqual(tl.gaps(reply, from: first).map(\.t), [],
                           "the reply disappeared in these frames (seconds). Frames: \(tl.dir.path)")
        } else {
            XCTFail("the reply never showed on screen. Frames: \(tl.dir.path)")
        }
    }
}

/// ChatsListScreen over a `ListState` the test holds, running the same
/// side effects ChatsRoot runs when that state changes.
private struct E2EListHost: View {
    @Bindable var state: ListState
    let user: PsmithUser
    @Environment(ConversationsModel.self) private var convos
    @FocusState private var focused: Bool

    var body: some View {
        ChatsListScreen(
            user: user, filter: $state.filter, searchText: $state.searchText,
            searchArchived: $state.searchArchived, searchFocused: $focused, selecting: $state.selecting,
            selection: $state.selection, confirmingDelete: $state.confirmingDelete,
            confirmingBulkDelete: $state.confirmingBulkDelete, renaming: $state.renaming,
            renameDraft: $state.renameDraft, open: { state.opened.append($0) }
        )
        .onChange(of: state.filter) { _, f in
            if f == .archived { Task { await convos.loadArchived() } }
        }
    }
}
