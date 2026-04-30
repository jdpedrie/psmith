import Testing
import SwiftUI
@testable import ClarkMac
import ClarkKit
import SnapshotHarness

/// Sidebar list snapshots. Covers all three top-level modes plus the
/// "search empty / typed / no matches" sub-states. Rendered at default
/// + minColumn so a clipping bug in the mode pill row or per-row
/// trailing chevron trips the snapshot.
@MainActor
struct ConversationListViewSnapshots {

    // MARK: - All Chats mode

    @Test
    func allChatsEmpty() {
        let env = SnapshotEnvironment.standard(conversations: [])
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func allChatsSingle() {
        let env = SnapshotEnvironment.standard(
            conversations: [SnapshotFixtures.conversation(title: "Just one chat")]
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func allChatsMultiple() {
        let env = SnapshotEnvironment.standard()
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func allChatsRecentlyCreated() {
        let env = SnapshotEnvironment.standard(listOrder: .recentlyCreated)
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    // MARK: - By Profile mode

    @Test
    func byProfileSingleProfileEmpty() {
        let p = SnapshotFixtures.profile()
        let env = SnapshotEnvironment.standard(
            conversations: [],
            profiles: [p],
            listMode: .byProfile
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func byProfileSingleProfileMany() {
        let p = SnapshotFixtures.profile()
        let convos = SnapshotFixtures.conversations(profileID: p.id)
        let env = SnapshotEnvironment.standard(
            conversations: convos,
            profiles: [p],
            listMode: .byProfile
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func byProfileTwoProfiles() {
        let coding = SnapshotFixtures.profile(id: "profile-coding", name: "Coding")
        let writing = SnapshotFixtures.profile(id: "profile-writing", name: "Writing", favorite: false)
        let codingConvos = [
            SnapshotFixtures.conversation(id: "c-1", title: "API design", profileID: coding.id),
            SnapshotFixtures.conversation(id: "c-2", title: "Refactor pass", profileID: coding.id),
        ]
        let writingConvos = [
            SnapshotFixtures.conversation(id: "c-3", title: "Essay outline", profileID: writing.id),
        ]
        let env = SnapshotEnvironment.standard(
            conversations: codingConvos + writingConvos,
            profiles: [coding, writing],
            listMode: .byProfile
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    // MARK: - Search mode

    @Test
    func searchEmptyQuery() {
        let env = SnapshotEnvironment.standard(
            conversations: [],
            listMode: .search,
            searchQuery: ""
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func searchWithMatches() {
        let env = SnapshotEnvironment.standard(
            conversations: [
                SnapshotFixtures.conversation(id: "c-m1", title: "Refactor refactor"),
                SnapshotFixtures.conversation(id: "c-m2", title: "Refactor pass two"),
            ],
            listMode: .search,
            searchQuery: "refactor"
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func searchNoMatches() {
        let env = SnapshotEnvironment.standard(
            conversations: [],
            listMode: .search,
            searchQuery: "no-such-thing"
        )
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationListView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }
}
