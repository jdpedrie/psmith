import SwiftUI
import AppKit
import ClarkKit

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

/// Belt-and-braces: also configure every window the app creates from the
/// AppDelegate. This catches the main window even if the SwiftUI background
/// view's `viewDidMoveToWindow` hasn't fired yet.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        for window in NSApp.windows {
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

    @MainActor
    static func configure(_ window: NSWindow) {
        // Don't reset `window.title` or `titleVisibility` here — those are
        // managed by SwiftUI's `.navigationTitle` modifier on each pane.
        // Resetting them on every focus/move notification (this method is
        // re-invoked from many NSWindow notifications) wipes the visible
        // title until SwiftUI happens to re-render.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        // Match the title-bar fill to the content background so the area
        // above the headers reads as one uniform dark surface in normal,
        // maximized, and fullscreen states.
        window.backgroundColor = NSColor(white: 0.13, alpha: 1.0)
    }
}

@main
struct ClarkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    init() {
        // SwiftPM-built executables aren't a proper .app bundle on their own;
        // when the host hasn't promoted us to a regular dock-bearing app,
        // force the policy and pull the window to the front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("") {
            RootView()
                .environment(appModel)
                .environment(sharedWindowState)
                .environment(sharedNavigator)
                .frame(minWidth: 940, minHeight: 560)
                .background(WindowChrome())
                .navigationTitle("")
                .task { await appModel.bootstrap() }
        }
        .commands {
            // Replace the standard "Settings…" menu item under the app menu
            // so ⌘, jumps the existing window into settings mode instead of
            // spawning a separate settings scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    sharedNavigator.mode = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
