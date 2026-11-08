import Testing
import SwiftUI
import AppKit
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// The composer's text view under the conditions the running app puts
/// it in and a static snapshot does not: it starts empty and is typed
/// into, and the pane reaches its real width after the first layout.
/// Hosted in an offscreen window, driven through the text view's own
/// input entry point, asserted on frames.
///
/// Regression for the 2026-09-27 report: the field wrapped at about
/// 100pt inside a full-width composer and never grew, because sizing
/// probes had left the live text container at a stale width.
@MainActor
struct ComposerTextViewTests {
    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let model: ConversationViewModel
        let textView: ComposerNSTextView

        var scroll: NSScrollView { textView.enclosingScrollView! }
        var containerWidth: CGFloat { textView.textContainer!.size.width }
        var lineHeight: CGFloat {
            textView.layoutManager!.defaultLineHeight(for: textView.font!)
        }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            settle()
        }

        func resize(to size: CGSize) {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            settle()
        }

        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = find(type, in: sub) { return match }
        }
        return nil
    }

    private func hostConversation(size: CGSize) throws -> Hosted {
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [SnapshotFixtures.systemMessage(), SnapshotFixtures.userMessage()]
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
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let textView = try #require(find(ComposerNSTextView.self, in: host))
        return Hosted(window: window, host: host, model: model, textView: textView)
    }

    @Test
    func startsOneLineTallAndFullWidth() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        #expect(hosted.scroll.frame.height == ceil(hosted.lineHeight))
        // The composer spans the reading column less its card's 16 and 10
        // of padding, nowhere near a collapsed width.
        #expect(hosted.scroll.frame.width == MK.column - 26)
        #expect(hosted.textView.frame.width == hosted.scroll.contentSize.width)
        #expect(hosted.containerWidth == hosted.textView.frame.width)
    }

    @Test
    func growsWhileTypingThenCapsAndScrolls() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        let line = ceil(hosted.lineHeight)

        hosted.type("one\ntwo\nthree")
        #expect(hosted.model.draft == "one\ntwo\nthree")
        #expect(hosted.scroll.frame.height == line * 3)

        // A trailing newline opens a line of its own at once.
        hosted.type("\n")
        #expect(hosted.scroll.frame.height == line * 4)

        hosted.type(String(repeating: "more\n", count: 14))
        #expect(hosted.scroll.frame.height == line * 10)
        // Past the cap the text view is taller than its scroll view:
        // the rest is reachable by scrolling.
        #expect(hosted.textView.frame.height > hosted.scroll.frame.height)
    }

    @Test
    func wrapsAtThePaneWidthAfterTheWindowGrows() throws {
        let hosted = try hostConversation(size: CGSize(width: 180, height: 500))
        defer { hosted.window.orderOut(nil) }
        hosted.resize(to: CGSize(width: 1100, height: 720))

        #expect(hosted.scroll.frame.width == MK.column - 26)
        #expect(hosted.textView.frame.width == hosted.scroll.contentSize.width)
        #expect(hosted.containerWidth == hosted.textView.frame.width)

        // A line long enough to wrap: the composer is as tall as the
        // text the view really lays out, so nothing hides below it.
        hosted.type(String(repeating: "word ", count: 60))
        #expect(hosted.textView.frame.height == hosted.scroll.frame.height)
        #expect(hosted.scroll.frame.height > ceil(hosted.lineHeight))
        #expect(hosted.scroll.frame.height < ceil(hosted.lineHeight) * 8)
    }

    @Test
    func wrapsAtThePaneWidthAfterTheWindowShrinks() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        hosted.type(String(repeating: "word ", count: 60))
        let wide = hosted.scroll.frame.height
        hosted.resize(to: CGSize(width: 560, height: 720))

        #expect(hosted.containerWidth == hosted.textView.frame.width)
        #expect(hosted.textView.frame.width == hosted.scroll.contentSize.width)
        // Narrower pane, more wrapped lines, taller composer.
        #expect(hosted.scroll.frame.height > wide)
        #expect(hosted.textView.frame.height == hosted.scroll.frame.height)
    }

    @Test
    func clearingTheDraftShrinksBackToOneLine() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        hosted.type("one\ntwo\nthree\nfour")
        #expect(hosted.scroll.frame.height == ceil(hosted.lineHeight) * 4)
        // What send does: the model empties the draft from outside.
        hosted.model.draft = ""
        hosted.settle()
        #expect(hosted.textView.string.isEmpty)
        #expect(hosted.scroll.frame.height == ceil(hosted.lineHeight))
    }

    @Test
    func takesKeyFocusWhenTheConversationOpens() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        #expect(hosted.window.firstResponder === hosted.textView)
    }

    @Test
    func keepsKeyFocusThroughASend() throws {
        let hosted = try hostConversation(size: CGSize(width: 1100, height: 720))
        defer { hosted.window.orderOut(nil) }
        hosted.type("first message")
        // What send does while the request is in flight, then after.
        hosted.model.draft = ""
        hosted.model.sending = true
        hosted.settle()
        #expect(!hosted.textView.isEditable)
        #expect(hosted.window.firstResponder === hosted.textView)
        hosted.model.sending = false
        hosted.settle()
        #expect(hosted.textView.isEditable)
        #expect(hosted.window.firstResponder === hosted.textView)
        hosted.type("second message")
        #expect(hosted.model.draft == "second message")
    }
}
