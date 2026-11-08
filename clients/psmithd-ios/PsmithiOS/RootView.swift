import SwiftUI
import PsmithKit
import PsmithUI

/// iOS root surface: the auth gate, then the chats stack. There is no tab
/// bar; Settings and adding an account push from the avatar menu.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager

    var body: some View {
        switch app.authState.phase {
        case .resolving:
            // A spinner while bootstrap() validates the stored token:
            // showing LoginView here would flash for a beat before the
            // signed-in shell lands.
            LaunchingScreen(host: app.serverURL)
        case .signedIn:
            if let user = app.authState.currentUser {
                AppShell(user: user)
            } else {
                // The phase says signed in but there's no user yet;
                // bootstrap resolves the contradiction shortly.
                LaunchingScreen(host: app.serverURL)
            }
        case .signedOut:
            // Seed the active account's host and username so signing
            // back in is just the password.
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

/// Launch interstitial (board Launching): the icon, a spinner and the host
/// being reached, on the neutral ground so it doesn't read as the list
/// arriving.
struct LaunchingScreen: View {
    let host: URL

    var body: some View {
        VStack(spacing: 0) {
            IKAppIcon()
            IKLaunchSpinner().padding(.top, 36)
            Text("Connecting to \(host.host ?? host.absoluteString)")
                .font(.system(size: 15)).ikLineHeight(21, size: 15).foregroundStyle(IK.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        // The board sets the icon at 318, 259 under the safe area.
        .padding(.top, 259)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IK.settingsGround.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}

/// The server didn't answer at launch and nothing is cached (board
/// LaunchOffline). Retry re-runs the launch load; the avatar menu and
/// "Use another account" stay usable so the user isn't stuck.
struct LaunchOfflineScreen: View {
    let user: PsmithUser
    let retry: () async -> Void
    let open: (ChatRoute) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var retrying = false

    private var host: String { app.serverURL.host ?? app.serverURL.absoluteString }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ChatsAccountMenu(user: user, open: open)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            IKLargeTitle(text: "Chats").frame(height: 44, alignment: .top)
            IKStatusBanner(text: "Server unreachable. Nothing cached on this phone yet.")
                .padding(.horizontal, 16)
                .padding(.top, 4)
            VStack(spacing: 0) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(IK.secondary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(IK.wash(0.06)))
                Text("Can't reach \(host)")
                    .font(.system(size: 20, weight: .semibold)).tracking(-0.3).foregroundStyle(IK.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                Text("Your chats show up here once the server answers. We keep trying in the background.")
                    .font(.system(size: 15)).ikLineHeight(21, size: 15).foregroundStyle(IK.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Button {
                    retrying = true
                    Task {
                        await retry()
                        retrying = false
                    }
                } label: {
                    if retrying { ProgressView().tint(.white) } else { Text("Retry") }
                }
                .ikWideButton()
                .frame(width: 220)
                .disabled(retrying)
                .padding(.top, 26)
                Button { open(.addAccount) } label: {
                    Text("Use another account")
                        .font(.system(size: 16)).foregroundStyle(theme.accentInk)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
            .padding(.top, 87)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.well.ignoresSafeArea())
    }
}

// MARK: - Authenticated shell

private struct AppShell: View {
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// Owns the conversations and profile list for the session. Recreated
    /// only when AppModel itself is rebuilt (an account switch).
    @State private var convos: ConversationsModel?

    /// Deadline for the splash. The splash only exists to stop onboarding
    /// flashing before the first provider list lands; against an
    /// unroutable host that list takes its full timeout, so after this
    /// the chats render from cache under the offline banner. Same bound
    /// as the Mac shell.
    @State private var splashExpired = false

    /// Set once a list refresh has succeeded. Until then an empty list
    /// with no server means "nothing cached", not "no conversations".
    @State private var reachedServer = false

    var body: some View {
        Group {
            // Splash until both providers and convos are ready, or the
            // deadline passes: providers are empty until the first list
            // completes, which would flash onboarding on every cold start.
            if convos == nil || (!app.providers.hasLoadedOnce && !splashExpired) {
                LaunchingScreen(host: app.serverURL)
            } else if needsOnboarding {
                OnboardingScreen()
            } else if let convos {
                ChatsRoot(user: user, launchOffline: launchOffline(convos), retry: { await load() })
                    .environment(convos)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            splashExpired = true
        }
        .task { await load() }
        // Events cover the app while it's active, but anything pushed while
        // iOS had the connection suspended is lost (the bus has no replay),
        // so re-entering the foreground reconciles by refresh. The kick
        // restores the push channel itself, which may be sitting in up to
        // 30s of reconnect backoff.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.kickEventStream()
                convos?.refreshSoon()
                // A preference changed on another device while this one was
                // in the background; there's no push for it.
                Task { await app.preferences.load() }
            }
        }
        .onChange(of: convos?.isLoading) { _, loading in
            if loading == false, convos?.loadError == nil { reachedServer = true }
        }
    }

    /// The launch load, also what LaunchOffline's Retry runs. Providers and
    /// conversations load concurrently: each is bounded by its own launch
    /// timeout, and in sequence an unreachable server cost both back to back.
    private func load() async {
        async let providersLoad: Void = loadProviders()
        if let convos {
            await convos.refresh()
        } else {
            let m = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
            // Server-push conversation events drive the list's debounced
            // refresh from here on.
            app.onConversationListChanged = { [weak m] in m?.refreshSoon() }
            // The cached page renders instantly; the refresh replaces it.
            await m.hydrateFromCache()
            convos = m
            await m.refresh()
        }
        if convos?.loadError == nil { reachedServer = true }
        await providersLoad
    }

    private func loadProviders() async {
        if !app.providers.hasLoadedOnce || !reachedServer {
            await app.providers.load()
        }
    }

    private func launchOffline(_ m: ConversationsModel) -> Bool {
        !reachedServer && m.conversations.isEmpty && m.listMode == .allChats
            && (app.connectivity.state == .offline || (m.loadError != nil && !m.isLoading))
    }

    /// The gate both clients share: at least one provider and one
    /// enabled model before the app proper.
    private var needsOnboarding: Bool {
        app.providers.needsOnboarding
    }
}
