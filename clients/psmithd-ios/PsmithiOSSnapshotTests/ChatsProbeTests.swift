import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Renders the Chats list states with the boards' content for comparison
/// (the delete confirm; the boards' list states, Main included, are in ListProbeTests).
@MainActor
final class ChatsProbeTests: XCTestCase {
    private func harness(conversations: [PsmithConversation] = Board.mainList,
                         archived: [PsmithConversation] = [],
                         offline: Bool = false,
                         filter: ChatsFilter = .all,
                         selecting: Bool = false,
                         selection: Set<String> = [],
                         confirmingDelete: String? = nil) -> some View {
        let app = SnapshotStubs.makeAppModel(profiles: Board.profiles, connectivityState: offline ? .offline : .online)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: conversations, profiles: Board.profiles)
        let accounts = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith-snap-accounts")!))
        return ChatsProbeHost(filter: filter, selecting: selecting, selection: selection, confirmingDelete: confirmingDelete)
            .environment(app)
            .environment(accounts)
            .environment(convos)
    }

    override func setUp() {
        DraftStore.save(conversationID: "c-pirate", text: "Arr, so what be three quarters of a")
    }

    override func tearDown() {
        DraftStore.clear(conversationID: "c-pirate")
    }

    func testDeleteConfirm() {
        IKRender.shoot("ListDeleteConfirm") { harness(confirmingDelete: "c-vacuum") }
    }
}

private struct ChatsProbeHost: View {
    @State var filter: ChatsFilter
    @State var selecting: Bool
    @State var selection: Set<String>
    @State var confirmingDelete: String?
    @State private var searchText = ""
    @State private var searchArchived = false
    @FocusState private var focused: Bool
    @State private var bulk = false
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        ChatsListScreen(
            user: Board.user, filter: $filter, searchText: $searchText, searchArchived: $searchArchived,
            searchFocused: $focused, selecting: $selecting, selection: $selection,
            confirmingDelete: $confirmingDelete, confirmingBulkDelete: $bulk, renaming: $renaming,
            renameDraft: $draft, open: { _ in }, now: Board.now
        )
    }
}
