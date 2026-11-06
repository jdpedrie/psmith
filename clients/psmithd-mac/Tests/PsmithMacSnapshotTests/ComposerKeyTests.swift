import Testing
import AppKit
@testable import PsmithMac

/// The composer's key bindings, driven with real key-down events
/// through the text view's own `keyDown` so AppKit's key-binding
/// resolution is part of what is tested: Return submits; Shift-Return,
/// Option-Return, and Control-Return insert a newline at the caret.
///
/// Regression for the 2026-09-27 report that Shift-Return submitted:
/// AppKit resolves Shift-Return to the same `insertNewline:` command
/// as Return, so the binding has to look at the event's modifiers.
@MainActor
struct ComposerKeyTests {
    private final class Host {
        let window: NSWindow
        let view: ComposerNSTextView
        var submits = 0

        init(text: String, caret: Int? = nil) {
            view = ComposerNSTextView(usingTextLayoutManager: false)
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
            view.isRichText = false
            view.string = text
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFront(nil)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
            view.onSubmit = { [unowned self] in self.submits += 1 }
        }

        func press(keyCode: UInt16 = 36, characters: String = "\r", modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
            view.keyDown(with: event)
        }

        deinit { window.orderOut(nil) }
    }

    @Test
    func returnSubmitsAndLeavesTheDraftAlone() {
        let host = Host(text: "hello")
        host.press()
        #expect(host.submits == 1)
        #expect(host.view.string == "hello")
    }

    @Test
    func keypadEnterSubmits() {
        let host = Host(text: "hello")
        host.press(keyCode: 76, characters: "\u{3}", modifiers: [.numericPad])
        #expect(host.submits == 1)
        #expect(host.view.string == "hello")
    }

    @Test
    func shiftReturnInsertsANewline() {
        let host = Host(text: "hello")
        host.press(modifiers: [.shift])
        #expect(host.submits == 0)
        #expect(host.view.string == "hello\n")
    }

    @Test
    func shiftReturnInsertsAtTheCaret() {
        let host = Host(text: "abcdef", caret: 3)
        host.press(modifiers: [.shift])
        #expect(host.submits == 0)
        #expect(host.view.string == "abc\ndef")
        #expect(host.view.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test
    func optionReturnInsertsANewline() {
        let host = Host(text: "hello")
        host.press(modifiers: [.option])
        #expect(host.submits == 0)
        #expect(host.view.string == "hello\n")
    }

    @Test
    func controlReturnInsertsANewlineNotALineSeparator() {
        let host = Host(text: "hello")
        host.press(modifiers: [.control])
        #expect(host.submits == 0)
        #expect(host.view.string == "hello\n")
    }

    @Test
    func ordinaryTypingStillTypes() {
        let host = Host(text: "")
        host.press(keyCode: 0, characters: "a")
        #expect(host.submits == 0)
        #expect(host.view.string == "a")
    }

    // MARK: Paste, focus, drops

    @Test
    func pasteIsSkippedWhenAnAttachmentWasTaken() {
        let host = Host(text: "hello")
        host.view.onPasteAttachment = { true }
        host.view.paste(nil)
        #expect(host.view.string == "hello")
    }

    @Test
    func keepsKeyFocusWhileSendingDisablesItAndTypesAgainAfter() {
        // Sending makes the composer read-only for the length of the
        // request. It must come back still focused, or every message
        // would need a click before the next one can be typed.
        let host = Host(text: "")
        host.view.isEditable = false
        #expect(host.window.firstResponder === host.view)
        host.view.isEditable = true
        #expect(host.window.firstResponder === host.view)
        host.press(keyCode: 0, characters: "a")
        #expect(host.view.string == "a")
    }

    @Test
    func registersNoDragTypesEvenAfterEditabilityChanges() {
        // AppKit re-registers a text view's drag types when isEditable
        // changes. With none of its own, a file dropped on the composer
        // reaches the SwiftUI drop destination around it.
        let host = Host(text: "")
        host.view.isEditable = false
        host.view.isEditable = true
        #expect(host.view.registeredDraggedTypes.isEmpty)
    }

    @Test
    func aFocusRequestBeforeJoiningAWindowIsHonoredOnJoining() {
        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        view.takeFocus()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        defer { window.orderOut(nil) }
        window.contentView = view
        #expect(window.firstResponder === view)
    }
}
