import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// The main window driven with real mouse and key events in an offscreen
/// window, at the boards' geometry (the "Main window" canvas page): the
/// list is 290 wide, every header 52 tall.
@Suite(.serialized)
@MainActor
struct MainWindowTests {
    private func mount(selected: String? = "c-scroll", setup: (inout BoardProbe.Scene) -> Void = { _ in }) async -> BoardProbe.Scene {
        var s = BoardProbe.scene(size: CGSize(width: 1280, height: 800), selected: selected)
        setup(&s)
        s.rig.mount(BoardProbe.Window(convos: s.convos, model: selected == nil ? nil : s.model))
        await pump(0.3)
        // As the app does once a window is on screen: transparent title
        // bar, the empty toolbar. Without it the title bar takes clicks.
        AppDelegate.configure(s.rig.window)
        await pump(1)
        return s
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

    /// A click at a point given from the window's top-left, through
    /// NSApp as a real one goes, so NSApp.currentEvent carries it.
    private func click(_ window: NSWindow, x: CGFloat, y: CGFloat, count: Int = 1) async {
        let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: n, pressure: type == .leftMouseUp ? 0 : 1
                )!)
                await pump(0.03)
            }
        }
        await pump(0.4)
    }

    private func key(_ window: NSWindow, _ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) async {
        // A shortcut goes through the window's key equivalents, as NSApp
        // sends it to its key window, which in a test is another window.
        if !modifiers.isEmpty {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            _ = window.performKeyEquivalent(with: e)
            await pump(0.4)
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            )!)
            await pump(0.03)
        }
        await pump(0.4)
    }

    // Rows: the list's header (52), search (26) and chips (8 + 22) with 8
    // under each, then "Pinned" (8 + 13 + 4) and rows 46 tall.
    private static let firstRowTop: CGFloat = 52 + 26 + 8 + 22 + 8 + 25

    @Test
    func theHideButtonHidesTheListAndTheHeadersShowButtonBringsItBack() async {
        let s = await mount()
        defer { s.rig.window.orderOut(nil) }
        // Hide: 28pt buttons at the list header's right, 10 in, 2 apart.
        await click(s.rig.window, x: 290 - 10 - 28 - 2 - 14, y: 26)
        #expect(!s.rig.navigator.listShown)
        await pump(0.4)
        // Show: in the reading pane's header, clear of the traffic lights.
        await click(s.rig.window, x: 10 + 72 + 8 + 14, y: 26)
        #expect(s.rig.navigator.listShown)
    }

    @Test
    func clickingARowSelectsItAndTheArrowKeysMoveTheSelection() async {
        let s = await mount()
        defer { s.rig.window.orderOut(nil) }
        // "Weekly planning", the pinned row, is the first.
        await click(s.rig.window, x: 120, y: Self.firstRowTop + 23)
        #expect(s.convos.selectedID == "c-weekly")
        await key(s.rig.window, 125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        #expect(s.convos.selectedID == "c-scroll")
        await key(s.rig.window, 126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        #expect(s.convos.selectedID == "c-weekly")
    }

    @Test
    func theInspectorButtonAndOptionCommandIToggleTheInspector() async {
        let s = await mount()
        defer { s.rig.window.orderOut(nil) }
        // The toggle: the reading pane header's last control, 12 in.
        await click(s.rig.window, x: 1280 - 12 - 14, y: 26)
        #expect(s.rig.navigator.inspectorShown)
        await key(s.rig.window, 34, "i", modifiers: [.command, .option])
        #expect(!s.rig.navigator.inspectorShown)
    }

    @Test
    func compressFromTheInspectorTakesTheComposersPlaceAndEscapeLeavesIt() async {
        let s = await mount { $0.rig.navigator.inspectorShown = true; $0.rig.navigator.inspectorTab = .context }
        defer { s.rig.window.orderOut(nil) }
        // The size card's button: 16 below the inspector header, the
        // card's 12 of padding, a 15.5 title row, 22 of bar and labels,
        // then 12 above the button.
        await click(s.rig.window, x: 1280 - 160, y: 53 + 16 + 12 + 15.5 + 22 + 14 + 12 + 13)
        #expect(s.model.showingCompactView)
        await key(s.rig.window, 53, "\u{1b}")
        #expect(!s.model.showingCompactView)
    }

    @Test
    func doubleClickingARowRenamesItInPlaceAndEscapeCancels() async {
        let s = await mount()
        defer { s.rig.window.orderOut(nil) }
        await click(s.rig.window, x: 120, y: Self.firstRowTop + 23, count: 2)
        #expect(titleFields(s.rig.window) == ["Weekly planning"])
        #expect(s.rig.window.firstResponder is NSTextView, "the title field has the keyboard")
        await key(s.rig.window, 53, "\u{1b}")
        #expect(titleFields(s.rig.window).isEmpty)
    }

    /// Text fields other than the list's search, by their text.
    private func titleFields(_ window: NSWindow) -> [String] {
        LiveProbe.Rig.find(window.contentView!, where: { $0 is NSTextField })
            .map { ($0 as! NSTextField).stringValue }
            .filter { !$0.isEmpty }
    }
}
