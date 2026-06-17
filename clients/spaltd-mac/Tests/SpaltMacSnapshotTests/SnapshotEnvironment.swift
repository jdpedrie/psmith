import Foundation
import SwiftUI
@testable import SpaltMac
@_exported import SpaltKit
@_exported import SnapshotHarness

/// Test-target helper that injects every `@Environment` SpaltMac views
/// require — `AppModel` (SpaltKit, public), `ConversationsModel`
/// (SpaltKit, public), `Navigator` (SpaltMac-internal, accessed via
/// `@testable import`), and `WindowState` (SpaltMac-internal). The
/// harness target can't reach these last two so the wiring lives here.
@MainActor
struct SpaltMacEnvironment<Content: View>: View {
    let app: AppModel
    let convos: ConversationsModel
    let navigator: Navigator
    let windowState: WindowState
    let content: Content

    init(
        app: AppModel,
        convos: ConversationsModel,
        navigator: Navigator,
        windowState: WindowState,
        @ViewBuilder content: () -> Content
    ) {
        self.app = app
        self.convos = convos
        self.navigator = navigator
        self.windowState = windowState
        self.content = content()
    }

    var body: some View {
        content
            .environment(app)
            .environment(convos)
            .environment(navigator)
            .environment(windowState)
            .preferredColorScheme(.dark)
    }
}

@MainActor
enum SnapshotEnvironment {
    /// Convenience builder — picks defaults for the standard "ready to
    /// chat" snapshot scene: one provider with one model, one
    /// non-parent profile, four conversations, no selection.
    static func standard(
        conversations: [SpaltConversation] = SnapshotFixtures.conversations(),
        profiles: [SpaltProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        listMode: ConversationListMode = .allChats,
        listOrder: SpaltConversationOrder = .recentlyUsed,
        searchQuery: String = "",
        navMode: AppMode = .chats,
        composing: Bool = false,
        windowMode: WindowState.Mode = .normal
    ) -> (app: AppModel, convos: ConversationsModel, navigator: Navigator, windowState: WindowState) {
        let app = SnapshotStubs.makeAppModel(profiles: profiles)
        let convos = SnapshotStubs.makeConversationsModel(
            client: app.client,
            conversations: conversations,
            profiles: profiles,
            selectedID: selectedID,
            listMode: listMode,
            listOrder: listOrder,
            searchQuery: searchQuery
        )
        let navigator = Navigator()
        navigator.mode = navMode
        navigator.composingNewConversation = composing
        let windowState = WindowState()
        windowState.mode = windowMode
        return (app, convos, navigator, windowState)
    }
}
