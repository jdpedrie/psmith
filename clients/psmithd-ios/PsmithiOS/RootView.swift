import SwiftUI
import PsmithKit
import PsmithUI

/// iOS root surface. Auth gate, then `TabView` shell with two tabs:
/// **Chats** (the main workflow) and **Settings** (configuration).
///
/// Per `docs/clients/ios-reference.md`: two tabs over single-stack-with-drawer
/// because Settings is many sub-screens; over three+ tabs because Account
/// is one screen and lives off the Chats toolbar avatar.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager

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
            // Seed the form with the active account's host + username
            // so re-auth is "type your password" rather than the full
            // server+credentials walk. Falls back to a blank form when
            // we can't find the active row (defensive — shouldn't
            // happen since signedOut implies there's an active model).
            let activeAccount = accountManager.accounts.first {
                $0.id == accountManager.activeAccountID
            }
            LoginView(
                initialHost: activeAccount?.host,
                initialUsername: activeAccount?.username
            )
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
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// Owns the conversations + profile list for the active session.
    /// Held via `@State` so it survives tab switches and re-renders;
    /// recreated only when AppModel itself is rebuilt (server URL
    /// change → re-init at the App level).
    @State private var convos: ConversationsModel?

    var body: some View {
        Group {
            // Splash until BOTH providers and convos are ready.
            // Without this gate, the OnboardingView header
            // ("Welcome to Psmith") flashes on every cold start
            // because `providers.providers` is empty until the
            // first list completes — needsOnboarding then briefly
            // returns true before the load finishes.
            if !app.providers.hasLoadedOnce || convos == nil {
                AuthInterstitialView()
            } else if needsOnboarding {
                OnboardingView()
            } else if let convos {
                // No tab bar — every pixel of vertical space matters
                // for the conversation surface. Settings access lives
                // in the account avatar menu (top-leading), which
                // presents SettingsRoot as a sheet.
                ChatsRoot(user: user)
                    .environment(convos)
            }
        }
        // Kick off both fetches as soon as AppShell mounts. The
        // splash branch above covers whichever is slower. Doing this
        // here (not from inside OnboardingView's .task) is what
        // prevents the welcome-screen flash — by the time we even
        // consider rendering OnboardingView we know whether it's
        // genuinely warranted.
        .task {
            if convos == nil {
                let m = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
                // Server-push conversation events drive the list's
                // debounced refresh from here on.
                app.onConversationListChanged = { [weak m] in m?.refreshSoon() }
                // Cached page renders the list instantly; the network
                // refresh replaces it.
                await m.hydrateFromCache()
                convos = m
                await m.refresh()
            }
            if !app.providers.hasLoadedOnce {
                await app.providers.load()
            }
        }
        // Foreground pull: events cover the app while it's active,
        // but anything pushed while iOS had the connection suspended
        // is lost (the bus has no replay) — re-entering the
        // foreground reconciles by refresh. The open conversation's
        // own staleness check runs from its scene-phase handler.
        // The kick restores the PUSH channel itself: the events
        // stream died during the suspend and may be sitting in up to
        // 30s of reconnect backoff, during which every other-client
        // change would go unseen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.kickEventStream()
                convos?.refreshSoon()
            }
        }
    }

    /// Block the main app surface until the user has at least one
    /// configured provider AND one enabled model. Identical gate to
    /// the Mac client — keeps both platforms aligned on the
    /// "can you actually chat?" precondition.
    private var needsOnboarding: Bool {
        app.providers.providers.isEmpty || !app.providers.hasAnyEnabledModel
    }
}
