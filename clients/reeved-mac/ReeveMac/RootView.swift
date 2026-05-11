import SwiftUI
import ReeveKit

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
        switch app.authState.phase {
        case .resolving:
            // Interstitial while bootstrap() validates the on-disk
            // token. Same fix the iOS RootView applies — avoid the
            // flash of LoginView before we drop into HomeView for a
            // user with a valid stored session.
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedIn:
            if let user = app.authState.currentUser {
                authed(user: user)
            } else {
                // Defensive: phase reports signed-in without a user
                // object. Bootstrap will reconcile shortly.
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .signedOut:
            LoginView()
        }
    }

    @ViewBuilder
    private func authed(user: ReeveUser) -> some View {
        if let convos {
            HomeView(user: user)
                .environment(convos)
        } else {
            Color.clear
                .task { convos = ConversationsModel(client: app.client) }
        }
    }
}
