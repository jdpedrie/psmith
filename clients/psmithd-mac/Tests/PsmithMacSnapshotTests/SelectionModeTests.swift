import Testing
import SwiftUI
import AppKit
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// Text selection in the transcript, driven the way the user drives
/// it: real mouse and key events delivered to an offscreen window
/// hosting the conversation.
@MainActor
struct SelectionModeTests {
    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let model: ConversationViewModel

        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// The selection text view: the transcript's only read-only one.
        var selectionView: NSTextView? {
            Self.find(in: host) { !$0.isEditable }
        }

        var composer: NSTextView? {
            Self.find(in: host) { $0.isEditable }
        }

        static func find(in view: NSView, where matches: (NSTextView) -> Bool) -> NSTextView? {
            if let text = view as? NSTextView, matches(text) { return text }
            for sub in view.subviews {
                if let match = find(in: sub, where: matches) { return match }
            }
            return nil
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )!
            window.sendEvent(event)
        }

        /// A drag between two points given from the window's top-left.
        func drag(from start: CGPoint, to end: CGPoint) {
            let height = window.contentView!.bounds.height
            func flipped(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: height - p.y) }
            mouse(.leftMouseDown, at: flipped(start))
            settle(0.05)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                mouse(.leftMouseDragged, at: flipped(p))
                settle(0.05)
            }
            mouse(.leftMouseUp, at: flipped(end))
            settle()
        }
    }

    private func hostConversation() -> Hosted {
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [
                SnapshotFixtures.userMessage(content: "render the plan"),
                SnapshotFixtures.assistantMessage(content: SelectableMessageTextSnapshots.sample),
            ]
        )
        let env = SnapshotEnvironment.standard(
            conversations: [model.conversation],
            selectedID: model.conversation.id
        )
        let root = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            NavigationStack {
                ConversationBody(model: model, liveConversation: model.conversation)
            }
        }
        let size = CGSize(width: 1100, height: 720)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let hosted = Hosted(window: window, host: host, model: model)
        hosted.settle(0.4)
        return hosted
    }

    @Test
    func aDragAcrossParagraphsSelectsAcrossThem() throws {
        let hosted = hostConversation()
        defer { hosted.window.orderOut(nil) }
        #expect(hosted.model.selectingTextMessageID == nil)

        // From the opening paragraph down into the numbered list.
        hosted.drag(from: CGPoint(x: 200, y: 182), to: CGPoint(x: 420, y: 275))

        #expect(hosted.model.selectingTextMessageID == "msg-assistant-1")
        let view = try #require(hosted.selectionView)
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        #expect(range.length > 40)
        // More than one block: the selection crosses paragraph breaks.
        #expect(selected.split(separator: "\n").count >= 3)
        // Key focus, so ⌘C copies without another click.
        #expect(hosted.window.firstResponder === view)
    }

    @Test
    func escapeLeavesSelectionMode() throws {
        let hosted = hostConversation()
        defer { hosted.window.orderOut(nil) }
        hosted.model.selectingTextMessageID = "msg-assistant-1"
        hosted.settle()
        let view = try #require(hosted.selectionView)
        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        view.keyDown(with: escape)
        hosted.settle()
        #expect(hosted.model.selectingTextMessageID == nil)
        #expect(hosted.selectionView == nil)
    }

    @Test
    func clickingIntoTheComposerLeavesSelectionMode() throws {
        let hosted = hostConversation()
        defer { hosted.window.orderOut(nil) }
        hosted.model.selectingTextMessageID = "msg-assistant-1"
        hosted.settle()
        let view = try #require(hosted.selectionView)
        #expect(hosted.window.firstResponder === view)
        let composer = try #require(hosted.composer)
        hosted.window.makeFirstResponder(composer)
        hosted.settle()
        #expect(hosted.model.selectingTextMessageID == nil)
    }

    @Test
    func typingInTheComposerDoesNotPullFocusOutOfASelection() throws {
        // The composer takes focus when asked, once. It must not take
        // it back whenever it updates, or selecting in a message would
        // end the moment anything in the pane changed.
        let hosted = hostConversation()
        defer { hosted.window.orderOut(nil) }
        hosted.model.selectingTextMessageID = "msg-assistant-1"
        hosted.settle()
        let view = try #require(hosted.selectionView)
        hosted.model.draft = "set from outside while selecting"
        hosted.settle()
        #expect(hosted.window.firstResponder === view)
        #expect(hosted.model.selectingTextMessageID == "msg-assistant-1")
    }
}
