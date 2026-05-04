import SwiftUI
import ReeveKit

/// iOS root surface. Auth gate, then `TabView` shell with two tabs:
/// **Chats** (the main workflow) and **Settings** (configuration).
///
/// Per `docs/ios-screens.md` §1.1: two tabs over single-stack-with-drawer
/// because Settings is many sub-screens; over three+ tabs because Account
/// is one screen and lives off the Chats toolbar avatar.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.authState.isAuthenticated, let user = app.authState.currentUser {
            AppShell(user: user)
        } else {
            LoginView()
        }
    }
}

// MARK: - Authenticated shell (TabView)

private struct AppShell: View {
    let user: ReeveUser
    @Environment(AppModel.self) private var app

    /// Owns the conversations + profile list for the active session.
    /// Held via `@State` so it survives tab switches and re-renders;
    /// recreated only when AppModel itself is rebuilt (server URL
    /// change → re-init at the App level).
    @State private var convos: ConversationsModel?

    var body: some View {
        Group {
            if let convos {
                // No tab bar — every pixel of vertical space matters
                // for the conversation surface. Settings access lives
                // in the account avatar menu (top-leading), which
                // presents SettingsRoot as a sheet. iOSNavigator no
                // longer carries a selectedTab.
                ChatsRoot(user: user)
                    .environment(convos)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        let m = ConversationsModel(client: app.client)
                        await m.refresh()
                        convos = m
                    }
            }
        }
    }
}
