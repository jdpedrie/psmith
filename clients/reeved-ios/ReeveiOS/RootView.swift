import SwiftUI
import ReeveKit
import ReeveUI

/// iOS root surface. Auth gate, then `TabView` shell with two tabs:
/// **Chats** (the main workflow) and **Settings** (configuration).
///
/// Per `docs/ios-screens.md` §1.1: two tabs over single-stack-with-drawer
/// because Settings is many sub-screens; over three+ tabs because Account
/// is one screen and lives off the Chats toolbar avatar.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.authState.phase {
        case .resolving:
            // Interstitial while bootstrap() validates the on-disk
            // token. Showing LoginView here flashes for a beat before
            // we drop into the authed shell — the spinner reads as
            // intentional state instead.
            AuthInterstitialView()
        case .signedIn:
            if let user = app.authState.currentUser {
                AppShell(user: user)
            } else {
                // Defensive: phase says signed-in but we don't have a
                // user object. Fall back to interstitial; bootstrap
                // will resolve the contradiction shortly.
                AuthInterstitialView()
            }
        case .signedOut:
            LoginView()
        }
    }
}

/// Launch interstitial shown while the on-disk session is being
/// validated. Plain spinner over the system background so it reads as
/// "app is starting" rather than "stalled login form" — anything more
/// branded would risk reading as a content swap when the real surface
/// (LoginView or AppShell) renders a moment later.
private struct AuthInterstitialView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
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
            if needsOnboarding {
                OnboardingView()
                    .task { await app.providers.load() }
            } else if let convos {
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
                        let m = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
                        await m.refresh()
                        convos = m
                    }
            }
        }
    }

    /// Block the main app surface until the user has at least one
    /// configured provider AND one enabled model. Identical gate to
    /// the Mac client — keeps both platforms aligned on the
    /// "can you actually chat?" precondition.
    private var needsOnboarding: Bool {
        app.providers.providers.isEmpty || app.providers.enabledModels.isEmpty
    }
}
