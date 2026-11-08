import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The Themes board: the list, a conversation and Settings › Appearance
/// under every theme, light and dark, at the boards' width.
@MainActor
final class ThemeProbeTests: XCTestCase {
    private let width = [IKRender.sizes[1]]

    func testListUnderEveryTheme() {
        for theme in Theme.allThemes {
            IKRender.shoot("Theme-\(theme.id)-List", sizes: width, theme: theme) { listScreen() }
        }
    }

    func testConversationUnderEveryTheme() {
        for theme in Theme.allThemes {
            IKRender.shoot("Theme-\(theme.id)-Conversation", sizes: width, theme: theme) {
                ConversationProbeTests.screen(ConversationProbeTests.Setup())
            }
        }
    }

    private func listScreen() -> some View {
        let app = SnapshotStubs.makeAppModel(profiles: Board.profiles, connectivityState: .online)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: Board.mainList,
                                                          profiles: Board.profiles)
        let accounts = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith-snap-theme")!))
        return ThemeListHost().environment(app).environment(accounts).environment(convos)
    }
}

private struct ThemeListHost: View {
    @State private var filter: ChatsFilter = .all
    @State private var search = ""
    @State private var archived = false
    @FocusState private var focused: Bool
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirming: String?
    @State private var bulk = false
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        ChatsListScreen(user: Board.user, filter: $filter, searchText: $search, searchArchived: $archived,
                        searchFocused: $focused, selecting: $selecting, selection: $selection,
                        confirmingDelete: $confirming, confirmingBulkDelete: $bulk, renaming: $renaming,
                        renameDraft: $draft, open: { _ in }, now: Board.now)
    }
}
