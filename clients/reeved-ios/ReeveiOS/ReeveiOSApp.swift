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
    /// Shared TTS player — one instance for the app's lifetime so
    /// "tap row B while A is speaking → A stops" works without each
    /// view owning its own synth.
    @State private var speaker = Speaker()
    /// Shared dictation engine. One instance app-wide so press-and-hold
    /// inside one conversation doesn't compete with another conversation
    /// already recording (impossible today but trivial guarantee).
    @State private var transcriber = Transcriber()
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
                .environment(\.speaker, speaker)
                .environment(\.transcriber, transcriber)
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
                // If every stream finishes while we're backgrounded,
                // release the token early so iOS reclaims the grace
                // for itself.
                .onChange(of: appModel.streamHub.activeConversationIDs.isEmpty) { _, isEmpty in
                    if isEmpty { bgKeeper.end() }
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
