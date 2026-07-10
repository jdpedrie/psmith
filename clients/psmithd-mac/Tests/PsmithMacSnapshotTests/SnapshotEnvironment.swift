import Foundation
import SwiftUI
@testable import PsmithMac
@_exported import PsmithKit
@_exported import SnapshotHarness

/// Test-target helper that injects every `@Environment` PsmithMac views
/// require — `AppModel` (PsmithKit, public), `ConversationsModel`
/// (PsmithKit, public), `Navigator` (PsmithMac-internal, accessed via
/// `@testable import`), and `WindowState` (PsmithMac-internal). The
/// harness target can't reach these last two so the wiring lives here.
@MainActor
struct PsmithMacEnvironment<Content: View>: View {
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
            // Views that surface the account switcher (HomeView,
            // RootView, LoginView) read AccountManager. A fresh
            // instance renders the zero-account state, which is what
            // deterministic snapshots want.
            .environment(AccountManager())
            .preferredColorScheme(.dark)
    }
}

@MainActor
enum SnapshotEnvironment {
    /// Convenience builder — picks defaults for the standard "ready to
    /// chat" snapshot scene: one provider with one model, one
    /// non-parent profile, four conversations, no selection.
    static func standard(
        conversations: [PsmithConversation] = SnapshotFixtures.conversations(),
        profiles: [PsmithProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        listMode: ConversationListMode = .allChats,
        listOrder: PsmithConversationOrder = .recentlyUsed,
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
