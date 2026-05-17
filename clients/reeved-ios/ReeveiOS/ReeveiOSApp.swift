import SwiftUI
import ReeveKit
import ReeveUI

/// iOS entry point. Mirrors `ReeveMacApp`'s shape — single
/// `WindowGroup` hosting `RootView`, with the same env-injected
/// platform glue (`Theme`, `Clipboard`) as the Mac build.
///
/// `urlStore` is held as `@State` so the App scene observes the
/// active server URL; on change we mint a fresh `AppModel` against
/// the new host. Same live-swap pattern the Mac uses, so
/// "log out → change server → sign back in" doesn't need a relaunch.
@main
struct ReeveiOSApp: App {
    @State private var accountManager = AccountManager()
    @State private var urlStore = ServerURLStore.shared
    @State private var themeStore = ThemeStore()
    @State private var prefs = sharedAppPreferences
    @State private var navigator = sharedIOSNavigator
    /// Extends background execution while StreamHub has at least one
    /// active run. See `BackgroundTaskKeeper` for the iOS contract +
    /// the explicit limits (this buys ~30s, not unlimited).
    @State private var bgKeeper = BackgroundTaskKeeper()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            iOSAppShell(accountManager: accountManager)
                .environment(accountManager)
                .environment(themeStore)
                .environment(prefs)
                .environment(navigator)
                .environment(\.theme, themeStore.current)
                .environment(\.clipboard, UIKitClipboard())
                .environment(\.notifier, sharedIOSNotifier)
                .tint(themeStore.current.accent)
                // Bootstrap is driven by `iOSAppShell`'s
                // `.task(id: activeAccountID)` so it re-fires on
                // every account switch, not just first launch.
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhase(newPhase)
                }
                // Two-way bg-keeper bookkeeping driven by stream
                // start/end events. Reads through the active
                // account's StreamHub so a switched-away account
                // doesn't influence background extension.
                .onChange(of: accountManager.active?.streamHub.activeConversationIDs.isEmpty ?? true) { _, isEmpty in
                    if isEmpty {
                        bgKeeper.end()
                    } else if scenePhase != .active {
                        bgKeeper.extend()
                    }
                }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            if let app = accountManager.active,
               !app.streamHub.activeConversationIDs.isEmpty {
                bgKeeper.extend()
            }
        case .active:
            bgKeeper.end()
        @unknown default:
            break
        }
    }
}

/// iOS root shell — picks RootView when an active account exists,
/// AccountSetupView otherwise. Mirrors the Mac AppShell.
struct iOSAppShell: View {
    @Bindable var accountManager: AccountManager

    var body: some View {
        Group {
            if let app = accountManager.active {
                RootView()
                    .environment(app)
                    .id(app.accountID ?? UUID())
            } else {
                iOSAccountSetupView()
            }
        }
        // Re-fire on every active-account swap so an account that
        // hasn't been bootstrapped yet (its AuthState is still
        // `.resolving`) gets `restoreSession` called and flips to
        // either `.signedIn` or `.signedOut`. Without this, switching
        // into a freshly-constructed AppModel leaves the user staring
        // at AuthInterstitialView forever — looking like the app has
        // hung. The bootstrap is now guarded internally to be
        // once-only per AppModel, so re-firing is cheap.
        .task(id: accountManager.activeAccountID) {
            if let active = accountManager.active {
                await active.bootstrap()
            }
        }
    }
}
