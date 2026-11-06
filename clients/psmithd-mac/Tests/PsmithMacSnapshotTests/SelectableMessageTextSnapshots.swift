import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// `SelectableMessageText` — the AppKit text view a message bubble
/// swaps in for selection mode. Hosted directly (the row's mode flag
/// is private state); pins the attributed rendering of every block
/// class the transcript produces, so a Foundation markdown-parser
/// change or a styling regression shows up as a diff.
@MainActor
struct SelectableMessageTextSnapshots {
    static let sample = """
    ## Rendering plan

    A paragraph with **bold**, *italic*, `inline code`, and a [link](https://example.com) that wraps onto a second line at this width so the paragraph style has to hold.

    - First bullet with **bold lead** and enough words to wrap onto the next line under a hanging indent
    - Second bullet
      - Nested bullet under the second

    1. Numbered first
    2. Numbered second, which also runs long enough to wrap so the number column keeps its alignment

    > A quoted line that reads in the secondary color.

    ```swift
    let code = "inside a fence"
    print(code)
    ```

    | Column | Value |
    |---|---|
    | alpha | one |
    | beta | two |

    Closing paragraph.
    """

    @Test
    func rendersEveryBlockClass() {
        assertViewSnapshot(
            SelectableMessageText(markdown: Self.sample)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Label colors follow the dark appearance the harness
                // pins; without a window background the capture is
                // white text on a white bitmap.
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 700, height: 620)
        )
    }

    @Test
    func rendererKeepsBlockStructure() {
        let text = MarkdownAttributedRenderer(baseSize: 13)
            .render("Intro\n\n- one\n- two\n\n1. first\n2. second\n\n```\ncode\n```\n\nOutro")
            .string
        // One paragraph per block, markers separated from their text
        // by the tab the hanging indent is built on, no separator
        // before the first block and none after the last.
        #expect(text == "Intro\n•\tone\n•\ttwo\n1.\tfirst\n2.\tsecond\ncode\nOutro")
    }

    @Test
    func rendererMarksOnlyTheFirstBlockOfAnItem() {
        let text = MarkdownAttributedRenderer(baseSize: 13)
            .render("- lead\n\n  continuation\n- next")
            .string
        #expect(text == "•\tlead\ncontinuation\n•\tnext")
    }
}

/// `TextSelectionDrag` — the point to character-range mapping behind
/// drag-to-select, in the text view's own coordinates.
@MainActor
struct TextSelectionDragTests {
    private func host(_ text: String) -> (NSWindow, NSTextView) {
        let view = NSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 13)
        view.string = text
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return (window, view)
    }

    /// Point just inside the leading edge of character `index`.
    private func point(of index: Int, in view: NSTextView) -> CGPoint {
        let layout = view.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
        return CGPoint(x: rect.minX + 0.5, y: rect.midY)
    }

    @Test
    func selectsBetweenPointsOnOneLine() {
        let (window, view) = host("Hello world, hello.")
        defer { window.orderOut(nil) }
        TextSelectionDrag.select(in: view, from: point(of: 0, in: view), to: point(of: 11, in: view))
        #expect(view.selectedRange() == NSRange(location: 0, length: 11))
    }

    @Test
    func selectsAcrossLinesInEitherDirection() {
        let (window, view) = host("First line\nSecond line here\nThird")
        defer { window.orderOut(nil) }
        let onFirst = point(of: 6, in: view)
        let onSecond = point(of: 18, in: view)
        TextSelectionDrag.select(in: view, from: onFirst, to: onSecond)
        #expect(view.selectedRange() == NSRange(location: 6, length: 12))
        // A drag upward selects the same range.
        TextSelectionDrag.select(in: view, from: onSecond, to: onFirst)
        #expect(view.selectedRange() == NSRange(location: 6, length: 12))
    }

    @Test
    func pointsPastTheTextLandOnItsEnd() {
        let (window, view) = host("Short")
        defer { window.orderOut(nil) }
        let start = point(of: 0, in: view)
        TextSelectionDrag.select(in: view, from: start, to: CGPoint(x: start.x + 250, y: start.y + 100))
        #expect(view.selectedRange() == NSRange(location: 0, length: 5))
    }
}
