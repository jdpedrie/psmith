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
        }
    }
}
