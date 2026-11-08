import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// The Settings window driven with real clicks in an offscreen window.
/// Rows are found by the boards' geometry: a 98pt header, then the list
/// column's 4pt inset, a 29pt section label and rows 41pt tall with a
/// subtitle (28pt without).
@Suite(.serialized)
@MainActor
struct SettingsShellTests {
    private struct Mounted {
        let window: NSWindow
        let navigator: Navigator
        let providers: ProvidersViewModel
    }

    private func mount(_ pane: SettingsCategory) async -> Mounted {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        env.navigator.settingsCategory = pane
        let providers = SnapshotStubs.makeProvidersModel()
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            SettingsView(
                providersModel: providers,
                profilesModel: SnapshotStubs.makeProfilesModel(),
                mcpServersModel: SnapshotStubs.makeMCPServersModel()
            )
        }
        // Reports itself key, as the frontmost window would, without
        // taking focus from whatever the user has open.
        let window = KeyedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1052, height: 672),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        await pump(1)
        return Mounted(window: window, navigator: env.navigator, providers: providers)
    }

    private func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Self.spin()
            await Task.yield()
        }
    }

    nonisolated private static func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// A click at a point given from the window's top-left.
    private func click(_ window: NSWindow, x: CGFloat, y: CGFloat) async {
        let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!)
            await pump(0.05)
        }
        await pump(0.4)
    }

    private static let listTop: CGFloat = 98 + 4 + 29

    @Test
    func clickingAnIntegrationShowsIt() async {
        let m = await mount(.integrations)
        defer { m.window.orderOut(nil) }
        #expect(m.navigator.settingsIntegration == .langfuse)
        // Rows with a subtitle are 41pt; Speech is the third.
        await click(m.window, x: 100, y: Self.listTop + 41 * 2 + 20)
        #expect(m.navigator.settingsIntegration == .speech)
    }

    @Test
    func clickingAPaneTabSwitchesPanes() async {
        let m = await mount(.general)
        defer { m.window.orderOut(nil) }
        // Nine 74pt tabs, 2pt apart, centered; Usage is the eighth.
        let row = CGFloat(9 * 74 + 8 * 2)
        let x = (1052 - row) / 2 + 7 * 76 + 37
        await click(m.window, x: x, y: 38 + 25)
        #expect(m.navigator.settingsCategory == .usage)
    }

    @Test
    func addProviderOpensTheAddPage() async {
        let m = await mount(.models)
        defer { m.window.orderOut(nil) }
        // One-line rows are 28pt; Add provider… follows the providers.
        let rows = CGFloat(m.providers.providers.count)
        await click(m.window, x: 100, y: Self.listTop + 28 * rows + 14)
        #expect(m.providers.detailMode == .adding)
    }
}
