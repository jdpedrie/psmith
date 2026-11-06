import SwiftUI
import AppKit
import PsmithUI

/// The composer's text entry: an AppKit text view that grows with the
/// draft up to `maxLines`, then scrolls. SwiftUI's vertical-axis
/// `TextField` stops growing at its line limit but never scrolls on
/// macOS, so a long draft's tail and the insertion point went out of
/// view with no way to reach them (user-reported). Owning the text view
/// also puts the key handling where AppKit expects it: Return sends,
/// Shift-Return (also Option- and Control-Return) inserts a newline at
/// the caret (the field-based composer appended one at the end of the
/// draft), and ⌘V with a file or image on the pasteboard attaches it
/// instead of pasting.
///
/// Sized by `sizeThatFits`: the text's height at the proposed width,
/// clamped to one line at least and `maxLines` at most; past the cap
/// the enclosing scroll view scrolls and keeps the caret visible as
/// AppKit does.
///
/// Measurement never touches the live text view. SwiftUI calls
/// `sizeThatFits` with probe proposals (unspecified, zero) as well as
/// the final width, and the first version laid the live container out
/// at each of them: the container kept the last probe's width, the
/// text wrapped at that stale width (about 100pt in the real window)
/// inside a full-width view, and the height measured at another width
/// never matched, so the field looked narrow and never grew. The
/// coordinator owns a separate TextKit stack for measuring; the live
/// container only ever tracks its text view's width.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    /// Bumped by the owner each time the composer should take key
    /// focus (the pane appeared, the conversation switched). A request
    /// is honored once: a level-triggered flag would pull focus back
    /// on every update, out of a message the user is selecting text
    /// in.
    var focusRequest: Int
    var maxLines: Int
    var onSubmit: () -> Void
    /// Called on ⌘V before the text view pastes. Return true when the
    /// pasteboard held an attachment that was taken, so no text paste
    /// follows.
    var onPasteAttachment: () -> Bool
    @Environment(\.fontScale) private var fontScale

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var handledFocusRequest = 0

        private let measureStorage = NSTextStorage()
        private let measureLayout = NSLayoutManager()
        private let measureContainer = NSTextContainer(size: .zero)

        init(parent: ComposerTextView) {
            self.parent = parent
            super.init()
            measureContainer.lineFragmentPadding = 0
            measureLayout.addTextContainer(measureContainer)
            measureStorage.addLayoutManager(measureLayout)
        }

        /// Height of `text` wrapped at `width`, including the empty
        /// line a trailing newline opens, and the height of one line.
        func measure(_ text: String, font: NSFont, width: CGFloat) -> (text: CGFloat, line: CGFloat) {
            measureContainer.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
            measureStorage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            measureLayout.ensureLayout(for: measureContainer)
            return (
                measureLayout.usedRect(for: measureContainer).height,
                measureLayout.defaultLineHeight(for: font)
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string {
                parent.text = view.string
            }
            // The draft's height may have changed: have SwiftUI ask
            // `sizeThatFits` again.
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Overlay scrollers never take width from the text, so wrapping
        // measured in `sizeThatFits` matches what is drawn.
        scroll.scrollerStyle = .overlay

        // TextKit 1, matching the coordinator's measuring stack, so
        // what `sizeThatFits` measures is what this view lays out.
        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textColor = .labelColor
        view.font = font
        // The field editor the old TextField used had these off; keep
        // the composer from curling quotes in pasted code.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        apply(to: view, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        apply(to: view, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        // An unspecified or unbounded width is a probe for the ideal
        // size; any finite width is taken as given.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let measured = context.coordinator.measure(text, font: font, width: width)
        let height = min(max(measured.text, measured.line), measured.line * CGFloat(maxLines))
        return CGSize(width: width, height: ceil(height))
    }

    private var font: NSFont {
        .systemFont(ofSize: baseSize(for: .body) * fontScale)
    }

    private func apply(to view: ComposerNSTextView, coordinator: Coordinator) {
        if view.string != text {
            view.string = text
        }
        if view.font != font {
            view.font = font
        }
        view.isEditable = isEnabled
        view.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        view.onSubmit = onSubmit
        view.onPasteAttachment = onPasteAttachment
        if focusRequest != coordinator.handledFocusRequest {
            coordinator.handledFocusRequest = focusRequest
            view.takeFocus()
        }
    }
}

/// Text view with the composer's key bindings. Return (and the keypad's
/// Enter) submits; Shift-Return, Option-Return, and Control-Return
/// insert a newline at the caret.
///
/// AppKit resolves Shift-Return to the same `insertNewline:` command as
/// plain Return, so that command decides by the modifiers of the key
/// event being handled. Option-Return arrives as
/// `insertNewlineIgnoringFieldEditor:` and Control-Return as
/// `insertLineBreak:`; all three insert a real "\n" rather than
/// AppKit's U+2028 line separator, which would otherwise travel to the
/// model inside the draft.
final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteAttachment: (() -> Bool)?

    /// The key-down being interpreted, for commands that need its
    /// modifiers. Only set for the duration of `keyDown`.
    private var keyEvent: NSEvent?

    /// A focus request that arrived before the view was in a window.
    private var wantsFocusWhenInWindow = false

    /// Take key focus now, or as soon as the view joins a window.
    func takeFocus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            wantsFocusWhenInWindow = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocusWhenInWindow, let window {
            wantsFocusWhenInWindow = false
            window.makeFirstResponder(self)
        }
    }

    /// No drag types of its own: files dropped on the composer belong
    /// to the SwiftUI drop destination around it. AppKit re-registers
    /// a text view's types whenever `isEditable` changes, which sending
    /// does on every message, so this is the property it re-reads
    /// rather than a one-time unregister.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    override func keyDown(with event: NSEvent) {
        keyEvent = event
        defer { keyEvent = nil }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let modifiers = keyEvent?.modifierFlags ?? NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) {
            insertText("\n", replacementRange: selectedRange())
        } else {
            onSubmit?()
        }
    }

    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        if onPasteAttachment?() == true { return }
        super.paste(sender)
    }
}
