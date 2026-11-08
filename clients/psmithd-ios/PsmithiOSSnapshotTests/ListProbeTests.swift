import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The list's state, held where a test can read and set it.
@MainActor @Observable
final class ListState {
    var filter: ChatsFilter = .all
    var searchText = ""
    var searchArchived = false
    var selecting = false
    var selection: Set<String> = []
    var confirmingDelete: String?
    var confirmingBulkDelete = false
    var renaming: String?
    var renameDraft = ""
    var opened: [ChatRoute] = []
}

struct ListHost: View {
    @Bindable var state: ListState
    var archived: [PsmithConversation]?
    @FocusState private var focused: Bool

    var body: some View {
        ChatsListScreen(
            user: Board.user, filter: $state.filter, searchText: $state.searchText,
            searchArchived: $state.searchArchived, searchFocused: $focused, selecting: $state.selecting,
            selection: $state.selection, confirmingDelete: $state.confirmingDelete,
            confirmingBulkDelete: $state.confirmingBulkDelete, renaming: $state.renaming,
            renameDraft: $state.renameDraft, open: { state.opened.append($0) }, now: Board.now,
            archivedFixture: archived
        )
    }
}

@MainActor
enum ListFixture {
    static func models(_ conversations: [PsmithConversation], offline: Bool = false) -> (AppModel, ConversationsModel) {
        let app = Shell.appModel(host: SnapshotStubs.nullHost, offline: offline)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: conversations,
                                                          profiles: Board.profiles)
        return (app, convos)
    }

    static func view(_ state: ListState, _ conversations: [PsmithConversation], archived: [PsmithConversation]? = nil,
                     offline: Bool = false, configure: (AppModel) -> Void = { _ in }) -> some View {
        let (app, convos) = models(conversations, offline: offline)
        configure(app)
        return ListHost(state: state, archived: archived)
            .environment(app)
            .environment(convos)
            .environment(Shell.accounts(other: false))
    }
}

/// The list's other boards: ListSearch, ListSwipe, ListRowMenu, ListEmpty,
/// ListArchived, ListOffline, ListSelect.
@MainActor
final class ListProbeTests: XCTestCase {
    override func setUp() {
        DraftStore.save(conversationID: "c-pirate", text: "Arr, so what be three quarters of a")
    }

    override func tearDown() {
        DraftStore.clear(conversationID: "c-pirate")
        UserDefaults.standard.removeObject(forKey: Self.queueKey)
    }

    private static let queueKey = "psmith.outboundQueue"

    /// Puts the Lisbon send in the stored queue the app model loads at
    /// init. Enqueueing on a live queue would post a change that makes
    /// every connectivity monitor probe the unroutable host and go
    /// offline mid-render.
    private func queueLisbon() {
        let entry = OutboundQueueEntry(
            conversationID: "c-lisbon", content: "Which neighborhoods are walkable from the river?",
            providerID: nil, modelID: nil, parentMessageID: nil, attachmentFileIDs: [], deviceFacts: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? enc.encode([entry]), forKey: Self.queueKey)
    }

    func testSearch() {
        IKRender.shoot("ListSearch") {
            let s = ListState()
            s.searchText = "vacuum"
            return ListFixture.view(s, Shell.searchActive, archived: Shell.searchArchived)
        }
    }

    func testSearchArchived() {
        IKRender.shoot("ListSearchArchived", sizes: [IKRender.sizes[1]]) {
            let s = ListState()
            s.searchText = "vacuum"
            s.searchArchived = true
            return ListFixture.view(s, Shell.searchActive, archived: Shell.searchArchived)
        }
    }

    /// The swipe itself is UIKit's and can't be held open in a render; this
    /// shoots the delete confirm and the rename it leads to.
    func testSwipe() {
        DraftStore.clear(conversationID: "c-pirate")
        IKRender.shoot("ListSwipe") {
            let s = ListState()
            s.confirmingDelete = "c-vacuum"
            s.renaming = "c-council"
            s.renameDraft = "Council: pricing for launch"
            return ListFixture.view(s, Shell.swipeList)
        }
    }

    /// The menu is the system's; this shoots the lifted preview card.
    func testRowMenuPreview() {
        IKRender.shoot("ListRowMenu") {
            ZStack(alignment: .top) {
                Color.dynamic(light: .hex("#C9D1DA"), dark: .hex("#0A1017")).ignoresSafeArea()
                ChatRowPreview(conversation: Board.mainList[1], profileName: "Demo",
                               profileColor: ProfileColor.color(for: Board.demo.id, theme: .slate), now: Board.now)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.top, 91)
            }
        }
    }

    func testEmpty() {
        IKRender.shoot("ListEmpty") { ListFixture.view(ListState(), []) }
    }

    func testArchived() {
        IKRender.shoot("ListArchived") {
            let s = ListState()
            s.filter = .archived
            return ListFixture.view(s, Board.mainList, archived: Shell.archived)
        }
    }

    func testOffline() {
        queueLisbon()
        IKRender.shoot("ListOffline") { ListFixture.view(ListState(), Shell.offlineList, offline: true) }
    }

    /// Board Main: Postgres is replying, the Lisbon send waits in the queue.
    func testMain() {
        queueLisbon()
        IKRender.shoot("Main") {
            ListFixture.view(ListState(), Shell.mainList) { app in
                app.streamHub.seedForPreview(StreamHub.ActiveStream(
                    runID: "run-vacuum", conversationID: "c-vacuum", contextID: "ctx-c-vacuum",
                    purpose: .assistantResponse))
            }
        }
    }

    func testSelect() {
        queueLisbon()
        IKRender.shoot("ListSelect") {
            let s = ListState()
            s.selecting = true
            s.selection = ["c-scroll", "c-pirate", "c-swift"]
            return ListFixture.view(s, Board.mainList)
        }
    }
}
