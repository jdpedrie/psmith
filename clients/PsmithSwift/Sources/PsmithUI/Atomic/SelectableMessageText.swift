#if os(macOS)
import SwiftUI
import AppKit

/// AppKit-backed, read-only rendering of a message body for text
/// selection. SwiftUI's `textSelection(.enabled)` on macOS selects
/// within one `Text` at a time, and a MarkdownUI document is one
/// `Text` per paragraph, list item, and code block — a drag that
/// crosses a paragraph boundary stops at it, and a drag that starts
/// in the gap between blocks selects nothing. That is the "can't
/// select consistently" report. An `NSTextView` holds the whole body
/// as one attributed string, so any range selects, double- and
/// triple-click work, and ⌘A / ⌘C route to the standard Edit menu.
///
/// Sized to its content for the proposed width (`sizeThatFits`), so
/// it sits in the bubble exactly where the MarkdownUI body was. Mac
/// only; iOS reaches selection through `MarkdownDocumentView`.
///
/// Selection mode ends when the text view gives up key focus (a click
/// in the composer or elsewhere) or on Escape: `onExit` fires and the
/// owner puts the markdown rendering back.
public struct SelectableMessageText: NSViewRepresentable {
    /// Lets the owner reach the live text view — `dragToSelectText`
    /// extends the selection from a drag that began on the markdown
    /// rendering the text view replaced.
    public final class Handle {
        public weak var textView: NSTextView?
        public init() {}
    }

    let markdown: String
    let handle: Handle?
    let onExit: (() -> Void)?
    @Environment(\.fontScale) private var fontScale

    public init(markdown: String, handle: Handle? = nil, onExit: (() -> Void)? = nil) {
        self.markdown = markdown
        self.handle = handle
        self.onExit = onExit
    }

    public final class Coordinator {
        /// (markdown, base size) of the string currently installed, so
        /// unrelated row updates (hover state, toasts) don't rebuild
        /// the text and drop the user's selection.
        var installedKey: String = ""
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: `usedRect(for:)` gives an exact content height for
        // a proposed width, where the TextKit 2 path only approximates
        // until layout settles.
        let view = SelectableNSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        install(into: view, coordinator: context.coordinator)
        view.onExit = onExit
        handle?.textView = view
        // Key focus on entry so ⌘A / ⌘C and Escape act on this text at
        // once, without a click first. The view is not in a window
        // yet; it takes focus when it joins one.
        view.takeFocus()
        return view
    }

    public func updateNSView(_ view: NSTextView, context: Context) {
        install(into: view, coordinator: context.coordinator)
        (view as? SelectableNSTextView)?.onExit = onExit
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    private var baseSize: CGFloat {
        (NSFont.systemFontSize * fontScale).rounded()
    }

    private func install(into view: NSTextView, coordinator: Coordinator) {
        let key = "\(baseSize)|\(markdown.count)|\(markdown.hashValue)"
        guard key != coordinator.installedKey else { return }
        coordinator.installedKey = key
        view.textStorage?.setAttributedString(
            MarkdownAttributedRenderer(baseSize: baseSize).render(markdown)
        )
    }
}

/// Text view that reports the end of selection mode: losing key focus
/// (the user clicked into the composer or another message) or Escape.
final class SelectableNSTextView: NSTextView {
    var onExit: (() -> Void)?

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

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onExit?() }
        return resigned
    }

    /// A read-only text view does not interpret key-downs, so Escape
    /// is taken here rather than left to reach `cancelOperation:` by
    /// way of the window.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onExit?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onExit?()
    }
}

/// Drag anywhere on a message body to select. The first movement
/// enters selection mode (the owner swaps in a `SelectableMessageText`
/// bound to `handle`), and every movement after that maps the mouse
/// to the text view and extends the selection from where the drag
/// began; mouse-up hands the text view key focus so ⌘C copies. This
/// is what makes a drag across paragraphs select across them: the
/// SwiftUI rendering underneath is one `Text` per block, so its own
/// selection stops at every paragraph boundary, and the owner turns
/// it off (`markdownTextSelectable`) so it does not take the mouse
/// first.
///
/// Apply it to the container the body lives in, with the text view
/// filling that container from its top-left corner: the gesture's
/// points are in the container's space, and they are used as points in
/// the text view's.
public struct DragToSelectText: ViewModifier {
    let handle: SelectableMessageText.Handle
    let enter: () -> Void
    @State private var entered = false

    public func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        if !entered {
                            entered = true
                            enter()
                        }
                        // Nil until the swap has put the text view on
                        // screen; the next movement picks it up.
                        if let textView = handle.textView {
                            TextSelectionDrag.select(in: textView, from: value.startLocation, to: value.location)
                        }
                    }
                    .onEnded { value in
                        entered = false
                        if let textView = handle.textView {
                            TextSelectionDrag.select(in: textView, from: value.startLocation, to: value.location)
                            textView.window?.makeFirstResponder(textView)
                        }
                    }
            )
    }
}

public extension View {
    /// See `DragToSelectText`.
    func dragToSelectText(handle: SelectableMessageText.Handle, enter: @escaping () -> Void) -> some View {
        modifier(DragToSelectText(handle: handle, enter: enter))
    }
}

public enum TextSelectionDrag {
    /// Selects the characters between two points given in `textView`'s
    /// own coordinates (origin top-left), each mapped to its nearest
    /// insertion point; points past the text land on its end.
    public static func select(in textView: NSTextView, from start: CGPoint, to end: CGPoint) {
        let i = textView.characterIndexForInsertion(at: start)
        let j = textView.characterIndexForInsertion(at: end)
        textView.setSelectedRange(NSRange(location: min(i, j), length: abs(i - j)))
    }
}

/// Markdown → `NSAttributedString` for the selectable body. Foundation's
/// parser (`.full` syntax) supplies block structure as presentation
/// intents but no paragraph separators or styling; this walks the runs
/// and emits one paragraph per block with fonts, hanging indents, and
/// list markers, close to the transcript's MarkdownUI theme.
public struct MarkdownAttributedRenderer {
    let baseSize: CGFloat

    public init(baseSize: CGFloat) {
        self.baseSize = baseSize
    }

    private var bodyFont: NSFont { .systemFont(ofSize: baseSize) }
    private var codeFont: NSFont {
        .monospacedSystemFont(ofSize: (baseSize * 0.92).rounded(), weight: .regular)
    }

    public func render(_ markdown: String) -> NSAttributedString {
        // Same hard-break treatment as MarkdownText: a single newline
        // in the source is a visible line break in the transcript.
        let source = MarkdownText.hardenLineBreaks(markdown)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(
                string: markdown,
                attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
            )
        }

        let out = NSMutableAttributedString()
        var lastBlockID: Int? = nil
        var lastListItemID: Int? = nil
        var lastRowID: Int? = nil

        for run in parsed.runs {
            let components = Self.innermostFirst(run.presentationIntent?.components ?? [])
            let block = components.first
            let blockID = block?.identity
            let listItemIDs = components.compactMap { component -> Int? in
                if case .listItem = component.kind { return component.identity }
                return nil
            }
            let rowID = components.first(where: {
                switch $0.kind {
                case .tableRow, .tableHeaderRow: return true
                default: return false
                }
            })?.identity

            var text = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]
            var font = bodyFont
            var color = NSColor.labelColor

            var isCodeBlock = false
            var isTableCell = false
            var isHeaderRow = false
            var blockquoteDepth = 0
            var headerLevel = 0
            for component in components {
                switch component.kind {
                case .codeBlock: isCodeBlock = true
                case .tableCell: isTableCell = true
                case .tableHeaderRow: isHeaderRow = true
                case .blockQuote: blockquoteDepth += 1
                case .header(let level): headerLevel = level
                default: break
                }
            }

            // Block boundary: separate from the previous block. Cells
            // in the same table row join with a divider instead.
            let startsBlock = blockID != lastBlockID
            if startsBlock, out.length > 0 {
                if isTableCell, rowID == lastRowID {
                    out.append(NSAttributedString(
                        string: "  |  ",
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]
                    ))
                } else {
                    out.append(NSAttributedString(string: "\n"))
                }
            }
            lastBlockID = blockID
            lastRowID = rowID

            // Hanging indent: one step per list level plus one per
            // quote level; the marker sits in the step before the text.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = baseSize * 0.15
            paragraph.paragraphSpacing = listItemIDs.isEmpty ? baseSize * 0.6 : baseSize * 0.25
            if isCodeBlock {
                // Code lines are paragraphs of their own; keep them
                // tight, and let the block's last line carry the gap.
                paragraph.paragraphSpacing = 0
            }
            let step = baseSize * 1.5
            let depth = CGFloat(listItemIDs.count + blockquoteDepth)
            paragraph.headIndent = step * depth
            paragraph.firstLineHeadIndent = step * depth
            if let itemID = listItemIDs.first, startsBlock, itemID != lastListItemID {
                // A marker only on the item's first block.
                let marker = Self.ordinal(components: components).map { "\($0)." } ?? "•"
                paragraph.firstLineHeadIndent = step * (depth - 1)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: step * depth)]
                text = marker + "\t" + text
            }
            if startsBlock { lastListItemID = listItemIDs.first }

            if headerLevel > 0 {
                // Same steps as the chat theme's heading styles.
                let scale: CGFloat = headerLevel == 1 ? 1.5 : (headerLevel == 2 ? 1.3 : (headerLevel == 3 ? 1.15 : 1))
                font = .systemFont(ofSize: (baseSize * scale).rounded(), weight: .semibold)
            }
            if isCodeBlock {
                font = codeFont
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                // A code block's text carries its own newlines; drop
                // the trailing one so the block ends flush.
                if text.hasSuffix("\n") { text.removeLast() }
            }
            if blockquoteDepth > 0 {
                color = .secondaryLabelColor
            }
            if isHeaderRow {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if case .thematicBreak = block?.kind {
                text = "———"
                color = .secondaryLabelColor
            }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if inline.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                if inline.contains(.code) {
                    font = codeFont
                    attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if inline.contains(.lineBreak) {
                    text = "\n"
                }
                if inline.contains(.softBreak) {
                    text = " "
                }
            }
            if let link = run.link {
                attributes[.link] = link
                color = .linkColor
            }

            attributes[.font] = font
            attributes[.foregroundColor] = color
            attributes[.paragraphStyle] = paragraph
            if isCodeBlock {
                // Background per line of code, not on the newlines: a
                // newline that carries a background paints to the
                // right edge and the block ends up ragged.
                var separator = attributes
                separator[.backgroundColor] = nil
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (i, line) in lines.enumerated() {
                    if i > 0 { out.append(NSAttributedString(string: "\n", attributes: separator)) }
                    out.append(NSAttributedString(string: String(line), attributes: attributes))
                }
            } else {
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return out
    }

    /// Foundation orders intent components from the innermost block
    /// outward; normalize in case a parse ever lists them the other
    /// way, keyed on where the paragraph-level component sits.
    private static func innermostFirst(_ components: [PresentationIntent.IntentType]) -> [PresentationIntent.IntentType] {
        func isBlockLevel(_ kind: PresentationIntent.Kind) -> Bool {
            switch kind {
            case .paragraph, .header, .codeBlock, .thematicBreak, .tableCell: return true
            default: return false
            }
        }
        if let last = components.last, components.count > 1,
           isBlockLevel(last.kind), !isBlockLevel(components[0].kind) {
            return components.reversed()
        }
        return components
    }

    /// The ordinal for an item of a numbered list, nil for a bulleted
    /// one: the innermost list item's own list decides.
    private static func ordinal(components: [PresentationIntent.IntentType]) -> Int? {
        var ordinal: Int? = nil
        for component in components {
            switch component.kind {
            case .listItem(let value):
                if ordinal == nil { ordinal = value }
            case .orderedList:
                if ordinal != nil { return ordinal }
            case .unorderedList:
                if ordinal != nil { return nil }
            default:
                break
            }
        }
        return nil
    }
}
#endif
