import Testing
import AppKit
@testable import PsmithMac

/// The window chrome pass (`AppDelegate.configure`) runs from app-wide
/// window notifications. It must touch only the app's main windows:
/// menus, tooltips and popovers are windows too, and the main window's
/// 1080×520 minimum blew them up to window size, mostly off screen.
@Suite(.serialized)
@MainActor
struct WindowChromeTests {
    private func mainWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        return w
    }

    @Test
    func aPopoverKeepsItsOwnSize() throws {
        let host = mainWindow()
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 20))
        host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.contentView!.addSubview(anchor)
        host.orderFront(nil)
        defer { host.orderOut(nil) }

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let popover = NSPopover()
        popover.contentViewController = content
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let popWindow = try #require(content.view.window)
        let before = popWindow.frame.size

        AppDelegate.configureAndTrackAllWindows()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(popWindow.frame.size == before)
        #expect(popWindow.frame.width < 400)
        #expect(popWindow.contentMinSize.width < 400)
    }

    @Test
    func aBorderlessPanelKeepsItsOwnSize() {
        // Tooltip and menu windows are borderless panels.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }

        AppDelegate.configureAndTrackAllWindows()

        #expect(panel.frame.size == NSSize(width: 160, height: 24))
    }

    @Test
    func theMainWindowGetsItsFloorAndChrome() {
        let w = mainWindow()
        w.orderFront(nil)
        defer { w.orderOut(nil) }

        AppDelegate.configureAndTrackAllWindows()

        #expect(w.titlebarAppearsTransparent)
        #expect(w.contentMinSize.width == 1080)
        #expect(w.frame.width >= 1080)
    }
}
