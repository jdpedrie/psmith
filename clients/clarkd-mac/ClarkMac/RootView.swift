import SwiftUI
import ClarkKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    /// Owns the conversations view-model so it survives body re-evaluations.
    /// Constructing `ConversationsModel(client:)` inline in the body — like
    /// the previous version did — created a fresh model on every re-render,
    /// dropping its loaded conversations + profiles each time anything above
    /// us in the env chain changed (e.g. flipping theme). @State + lazy init
    /// keeps the same instance across the whole authed session.
    @State private var convos: ConversationsModel?

    var body: some View {
        if app.authState.isAuthenticated, let user = app.authState.currentUser {
            authed(user: user)
        } else {
            LoginView()
        }
    }

    @ViewBuilder
    private func authed(user: ClarkUser) -> some View {
        if let convos {
            HomeView(user: user)
                .environment(convos)
        } else {
            Color.clear
                .task { convos = ConversationsModel(client: app.client) }
        }
    }
}
