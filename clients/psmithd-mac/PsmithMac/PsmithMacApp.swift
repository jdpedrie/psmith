import SwiftUI
import AppKit
import PsmithKit
import PsmithUI

/// Mac-side shared ThemeStore. Lives at module scope so AppDelegate (which
/// is driven by AppKit notifications and can't read SwiftUI environment)
/// can pull the active chrome color for `NSWindow.backgroundColor`.
@MainActor
let sharedThemeStore = ThemeStore()

/// Tracks the main window's display mode so SwiftUI views can apply
/// "responsive" layouts — e.g. headers need a 28pt top inset only when the
/// window is zoomed (macOS draws an opaque ~36pt title-bar overlay in that
/// state that hides anything underneath; normal and fullscreen don't have
/// that overlay so content can sit flush against the top).
@Observable
@MainActor
final class WindowState {
    enum Mode { case normal, zoomed, fullscreen }
    var mode: Mode = .normal

    fileprivate func update(from window: NSWindow) {
        let newMode: Mode
        if window.styleMask.contains(.fullScreen) {
            newMode = .fullscreen
        } else if let screen = window.screen ?? NSScreen.main,
                  isFrameNearVisibleMax(window.frame, screen.visibleFrame) {
            newMode = .zoomed
        } else {
            newMode = .normal
        }
        if newMode != mode { mode = newMode }
    }

    /// True if the window covers ≥90% of the screen's visible area along
    /// both axes — captures both green-click zoom and option-green maximize,
    /// with slack for fullSizeContentView frame quirks.
    private func isFrameNearVisibleMax(_ frame: NSRect, _ visible: NSRect) -> Bool {
        guard visible.width > 0, visible.height > 0 else { return false }
        return frame.width / visible.width >= 0.90
            && frame.height / visible.height >= 0.90
    }
}

/// Single shared instance because the AppDelegate (driven by AppKit
/// notifications) and SwiftUI views (consuming via @Environment) both need
/// to read/write the same observable state.
@MainActor
let sharedWindowState = WindowState()

/// NSView that, when attached to its window, hides the window's title and
/// makes the title bar transparent + full-size so content extends under the
/// traffic-light area instead of living below a dead band of chrome. Traffic
/// lights stay clickable. Uses `viewDidMoveToWindow` because at the time
/// SwiftUI calls `makeNSView` the view isn't yet in a window — a one-shot
/// `DispatchQueue.main.async` is unreliable.
private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        AppDelegate.configure(window)
        sharedWindowState.update(from: window)
    }
}

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            AppDelegate.configure(window)
            // Use the actual hosting window directly — most reliable source.
            sharedWindowState.update(from: window)
        }
    }
}

/// Also configures every window the app creates from the AppDelegate,
/// which catches the main window before the SwiftUI background view's
/// `viewDidMoveToWindow` has fired.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Re-entrancy guard for the snap-up `setFrame` call. `setFrame` posts
    /// `didResizeNotification`, which our observers handle by calling back
    /// into `configure(_:)` — without this flag the snap would recurse
    /// thousands of levels deep until the stack guard page faulted. We only
    /// need to snap once at launch / first window mount; subsequent observer
    /// fires can rely on `contentMinSize` (already set) to keep the window
    /// above the floor.
    @MainActor static var isSnapping = false
    /// Tracks which windows have already been snapped this session so we
    /// don't fight the user's manual resizes mid-session — the snap exists
    /// solely to override state-restored frames that come back below the
    /// minimum.
    @MainActor static var snappedWindows: Set<ObjectIdentifier> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconSync.apply(themeID: sharedThemeStore.current.id)
        Self.configureAndTrackAllWindows()
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    Self.configureAndTrackAllWindows()
                }
                // Green-button zoom triggers a multi-step resize animation;
                // poll a few times so we land on the final frame regardless
                // of which intermediate state the notification captured.
                for delay in [0.1, 0.35, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated {
                            Self.configureAndTrackAllWindows()
                        }
                    }
                }
            }
        }
    }

    /// Configures chrome on every window the app owns and updates the
    /// shared WindowState from the *largest* visible window — the helper
    /// windows SwiftUI creates (e.g. for popovers/menus) report tiny
    /// frames and would mislead the responsive-layout decision.
    @MainActor
    static func configureAndTrackAllWindows() {
        var largest: NSWindow?
        var largestArea: CGFloat = -1
        for window in NSApp.windows where isAppWindow(window) {
            configure(window)
            let area = window.frame.width * window.frame.height
            if window.isVisible, area > largestArea {
                largest = window
                largestArea = area
            }
        }
        if let main = largest {
            sharedWindowState.update(from: main)
        }
    }

    /// The app's own content windows. Menus, tooltips, popovers and
    /// sheets are NSWindows too, and the notifications this pass runs
    /// from fire for them: given the main window's 1080×520 floor they
    /// grew to window size, mostly off screen.
    /// The Settings window keeps standard chrome and its own size.
    @MainActor
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.canBecomeMain
            && !(window.identifier?.rawValue.contains("Settings") ?? false)
    }

    @MainActor
    static func configure(_ window: NSWindow) {
        guard isAppWindow(window) else { return }
        // Don't reset `window.title` or `titleVisibility` here — those are
        // managed by SwiftUI's `.navigationTitle` modifier on each pane.
        // Resetting them on every focus/move notification (this method is
        // re-invoked from many NSWindow notifications) wipes the visible
        // title until SwiftUI happens to re-render.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        // The main window is drawn dark, like Settings: its boards and
        // its controls are the dark variants. Themes keep their hue.
        window.appearance = NSAppearance(named: .darkAqua)
        // An empty unified toolbar: no items, but macOS centers the
        // traffic lights in a 52pt band (x 19, 42, 65; y 19), which is
        // where every column's header puts its contents.
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "psmith.main")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(sharedThemeStore.current.chrome)
        // AppKit-level minimum: SwiftUI's `.frame(minWidth:minHeight:)` on
        // the WindowGroup root doesn't reliably reach NSWindow. The floor is
        // the boards' smallest window, where the list, a 470pt reading pane
        // and the inspector still fit.
        let minSize = MK.windowFloor
        window.contentMinSize = minSize

        // One-shot snap-up: state restoration can hand us a frame below
        // `minSize` before contentMinSize takes effect. We bump the frame
        // up exactly once per window — subsequent observer fires (from
        // user resizes, zoom, etc.) skip the snap, which is critical
        // because `setFrame` posts `didResizeNotification` and our
        // observers loop back into this method. The `isSnapping` flag
        // catches any reentrancy that slips past the per-window guard.
        let id = ObjectIdentifier(window)
        guard !isSnapping, !snappedWindows.contains(id) else { return }
        snappedWindows.insert(id)
        var frame = window.frame
        if frame.size.width < minSize.width { frame.size.width = minSize.width }
        if frame.size.height < minSize.height { frame.size.height = minSize.height }
        if frame != window.frame {
            isSnapping = true
            window.setFrame(frame, display: true)
            isSnapping = false
        }
    }
}

@main
struct PsmithMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Top-level multi-account host. Holds the persisted accounts
    /// list + one AppModel per account. The active AppModel is
    /// what the rest of the app sees as `app`; switching accounts
    /// swaps which one that resolves to without reconstructing
    /// stream subscriptions or caches.
    @State private var accountManager = AccountManager()
    /// The shared ServerURLStore. Read by the LoginView for the
    /// initial host suggestion when adding the first account.
    @State private var urlStore = ServerURLStore.shared
    /// Use the shared ThemeStore (defined in Theme.swift) so AppDelegate can
    /// read the active chrome color for NSWindow.backgroundColor without
    /// having to thread the env through AppKit.
    private var themeStore: ThemeStore { sharedThemeStore }

    /// App-wide preferences (notification toggle, future toggles). The
    /// shared singleton lives in AppPreferences.swift so module-scope
    /// helpers (sharedNotifier construction in particular) can reach it.
    @State private var prefs = sharedAppPreferences
    init() {
        // SwiftPM-built executables aren't a proper .app bundle on their own;
        // when the host hasn't promoted us to a regular dock-bearing app,
        // force the policy and pull the window to the front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Device-tool handlers register once per process, before any
        // AppModel boots. Registration only seeds the registry —
        // EventKit stores + permission prompts stay lazy until the
        // model actually calls a tool. Files registers only when a
        // vault bookmark exists (re-synced by the settings pane).
        CalendarTools.register()
        RemindersTools.register()
        FilesTools.syncRegistration()
    }

    var body: some Scene {
        WindowGroup("") {
            // Compose env: AccountManager always; AppModel only
            // when an active account exists. AppShell shows
            // RootView when there's an active account, otherwise
            // LoginView (cold-start variant routing through
            // accountManager.addAccount).
            AppShell(accountManager: accountManager)
                .environment(accountManager)
                .environment(sharedWindowState)
                .environment(sharedNavigator)
                .environment(themeStore)
                .environment(prefs)
                .environment(\.theme, themeStore.current)
                .environment(\.clipboard, AppKitClipboard())
                .environment(\.notifier, sharedNotifier)
                // App-wide text scale. The fontScale env drives every
                // .scaledFont call site; the default \.font catches
                // unstyled Text (and MarkdownUI's base size, which
                // cascades its em-relative styles from it).
                .environment(\.fontScale, prefs.fontScale)
                .environment(\.font, prefs.fontScale == 1.0
                    ? nil
                    : .system(size: baseSize(for: .body) * prefs.fontScale))
                .tint(themeStore.current.accent)
                .frame(minWidth: 1080, minHeight: 600)
                .background(themeStore.current.chrome.ignoresSafeArea())
                .background(WindowChrome())
                .navigationTitle("")
                .task {
                    // Bootstrap every existing account so live runs
                    // adopt + connectivity monitors start. New
                    // accounts added after launch bootstrap
                    // themselves inside AccountManager.addAccount.
                    if let active = accountManager.active {
                        await active.bootstrap()
                    }
                    _ = sharedNotifier
                }
                .onChange(of: themeStore.current.id) { _, id in
                    AppDelegate.configureAndTrackAllWindows()
                    DockIconSync.apply(themeID: id)
                }
        }
        // Default size on first run. macOS state-restores the window's last
        // size on subsequent runs; the AppDelegate.configure NSWindow snap
        // (contentMinSize + setFrame) forces a restored window that comes
        // back below the SettingsView floor up to it; restored sessions
        // don't reliably honor the SwiftUI .frame(minWidth:) modifier.
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    sharedNavigator.startNewConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // Text-size zoom under the View menu. ⌘= is what the
            // "⌘+" keystroke produces unshifted; ⌘0 resets — the
            // browser convention.
            // Replaces the system's Show Sidebar: in our split view that
            // command revealed the empty first column instead of the list.
            CommandGroup(replacing: .sidebar) {
                Button(sharedNavigator.listShown ? "Hide Conversation List" : "Show Conversation List") {
                    withAnimation { sharedNavigator.listShown.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                Divider()
                // Manual reconcile-with-server: refreshes the sidebar
                // list and runs the open conversation's staleness
                // check. The server-push events + window-focus pull
                // make this rarely necessary; the command is the
                // always-available backstop. Routed via notification
                // because the ConversationsModel is scene-scoped
                // (RootView owns it), not app-scoped.
                Button("Reload From Server") {
                    NotificationCenter.default.post(name: .psmithReloadRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Increase Text Size") {
                    sharedAppPreferences.fontScale += AppPreferences.fontScaleStep
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Text Size") {
                    sharedAppPreferences.fontScale -= AppPreferences.fontScaleStep
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Actual Text Size") {
                    sharedAppPreferences.fontScale = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }

        // Settings in a window of its own, opened by ⌘, and the app menu
        // like every Mac app's, instead of a mode that takes over the
        // conversation window.
        Settings {
            SettingsWindowRoot()
                .environment(accountManager)
                .environment(sharedWindowState)
                .environment(sharedNavigator)
                .environment(themeStore)
                .environment(prefs)
                .environment(\.theme, themeStore.current)
                .environment(\.clipboard, AppKitClipboard())
                .environment(\.fontScale, prefs.fontScale)
                .tint(themeStore.current.accent)
        }
        .windowResizability(.contentMinSize)
    }
}

/// The Settings window's content: the active account's settings, or a
/// note when nobody is signed in.
private struct SettingsWindowRoot: View {
    @Environment(AccountManager.self) private var accountManager

    var body: some View {
        if let app = accountManager.active, app.authState.phase == .signedIn {
            SettingsView(
                providersModel: app.providers,
                profilesModel: app.profiles,
                mcpServersModel: app.mcpServers
            )
            .environment(app)
        } else {
            ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark", description: Text("Sign in to a server to change its settings."))
                .frame(width: 480, height: 320)
        }
    }
}
