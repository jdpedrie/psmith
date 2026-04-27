import SwiftUI
import ClarkKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.authState.isAuthenticated, let user = app.authState.currentUser {
            HomeView(user: user)
                .environment(ConversationsModel(client: app.client))
        } else {
            LoginView()
        }
    }
}
