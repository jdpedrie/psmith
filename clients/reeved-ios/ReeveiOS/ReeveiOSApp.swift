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
    @State private var appModel = AppModel()
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
            RootView()
                .environment(appModel)
                .environment(themeStore)
                .environment(prefs)
                .environment(navigator)
                .environment(\.theme, themeStore.current)
                .environment(\.clipboard, UIKitClipboard())
                .environment(\.notifier, sharedIOSNotifier)
                .tint(themeStore.current.accent)
                .task {
                    await appModel.bootstrap()
                }
                .onChange(of: urlStore.current) { _, _ in
                    appModel = AppModel()
                    Task { await appModel.bootstrap() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhase(newPhase)
                }
                // Two-way bg-keeper bookkeeping driven by stream
                // start/end events while the scene is non-active:
                //
                //   - streams empty → release the token (whether
                //     we're foregrounded or not — `end()` is a no-op
                //     when no token is held).
                //   - streams become non-empty while backgrounded →
                //     extend NOW. This is the case the old code
                //     missed: kicking off compaction (or any new run
                //     via background adopt) while the app was already
                //     suspended produced no scene-phase transition,
                //     so the bgKeeper was never extended and iOS
                //     froze the supervisor mid-stream.
                .onChange(of: appModel.streamHub.activeConversationIDs.isEmpty) { _, isEmpty in
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
            if !appModel.streamHub.activeConversationIDs.isEmpty {
                bgKeeper.extend()
            }
        case .active:
            bgKeeper.end()
        @unknown default:
            break
        }
    }
}
