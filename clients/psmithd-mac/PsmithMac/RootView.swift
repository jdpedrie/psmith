import AppKit
import SwiftUI
import PsmithKit
import PsmithUI

extension Notification.Name {
    /// Posted by the View ▸ Reload From Server menu command (⌘R).
    /// RootView owns the scene-scoped ConversationsModel, so the
    /// command routes here by notification.
    static let psmithReloadRequested = Notification.Name("psmith.reloadRequested")
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager

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
            // Seed the form with the active account's host + username
            // so re-auth is just "type your password". Falls back to
            // a blank form when we can't resolve the active row.
            let activeAccount = accountManager.accounts.first {
                $0.id == accountManager.activeAccountID
            }
            LoginView(
                initialHost: activeAccount?.host,
                initialUsername: activeAccount?.username
            )
        }
    }

    @ViewBuilder
    private func authed(user: PsmithUser) -> some View {
        // Splash until BOTH providers and convos are ready —
        // without this, OnboardingView flashes briefly on every
        // cold start because `providers.providers` is empty until
        // the first list completes.
        if !app.providers.hasLoadedOnce || convos == nil {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    if convos == nil {
                        let m = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
                        // Server-push conversation events drive the
                        // sidebar's debounced refresh from here on.
                        app.onConversationListChanged = { [weak m] in m?.refreshSoon() }
                        // Cached page renders the sidebar instantly;
                        // the first refresh replaces it.
                        await m.hydrateFromCache()
                        convos = m
                    }
                    if !app.providers.hasLoadedOnce {
                        await app.providers.load()
                    }
                }
        } else if needsOnboarding {
            OnboardingView()
        } else if let convos {
            HomeView(user: user)
                .environment(convos)
                // Window focus = pull refresh. Events cover the app
                // while it's frontmost, but macOS can suspend the
                // push connection while the app idles in the
                // background, and the bus has no replay — focus
                // reconciles the gap. Same handler as ⌘R.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )) { _ in
                    reconcileWithServer()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .psmithReloadRequested
                )) { _ in
                    reconcileWithServer()
                }
        }
    }

    /// Refresh the sidebar list (debounced) and run the open
    /// conversation's staleness check — the same cheap-get-then-
    /// compare path the server-push events use.
    private func reconcileWithServer() {
        guard let convos else { return }
        convos.refreshSoon()
        if let sel = convos.selectedID {
            app.streamHub.notifyConversationChanged(conversationID: sel)
        }
    }

    /// Block the main app surface until the user has at least one
    /// configured provider AND one enabled model. The Psmith Manager
    /// system profile depends on a working model for its first turn —
    /// without this gate the user lands in a chat surface with nothing
    /// to send to. Observed via @Environment, so as soon as the user
    /// completes the wizard the parent re-renders and HomeView takes
    /// over.
    private var needsOnboarding: Bool {
        app.providers.providers.isEmpty || !app.providers.hasAnyEnabledModel
    }
}
