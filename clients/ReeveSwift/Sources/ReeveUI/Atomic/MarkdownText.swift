import SwiftUI
import MarkdownUI

/// Renders a markdown string with block-level support (headers, lists, code
/// blocks, tables). Used for both finished assistant messages and the live
/// streaming row — incomplete syntax during streaming is rendered as plain
/// text by the parser, so half-written code fences look fine until they close.
public struct MarkdownText: View {
    private let content: String

    public init(_ content: String) {
        self.content = content
    }

    public var body: some View {
        // Convert single `\n` to `  \n` (markdown trailing-space hard
        // break) outside fenced code blocks, instead of relying on
        // `markdownSoftBreakMode(.lineBreak)`. The softBreakMode path
        // has a MarkdownUI bug (2.4.1 confirmed): after a soft break it
        // sets a "skip next whitespace" flag that the renderer only
        // clears on the next *text* inline. If the next inline is a
        // strong/emphasis (e.g. a line that opens with `**Header:**`),
        // the flag carries past it and strips the leading space on the
        // text that follows — so `**Header:** value` renders as
        // `**Header:**value`. Trailing-space hard breaks produce
        // `.lineBreak` AST nodes directly, which bypass the buggy
        // soft-break path.
        Markdown(Self.hardenLineBreaks(content))
            .markdownTheme(.clarkChat)
            .textSelection(.enabled)
            // Without this, MarkdownUI's bullet-list layout inconsistently
            // truncates long items with an ellipsis on iOS — especially
            // mid-stream, when the parent's width is briefly resolving.
            // `.fixedSize(horizontal: false, vertical: true)` pins width
            // to the parent and lets the text grow vertically, which
            // matches "wrap, don't truncate" semantics.
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Adds two trailing spaces before each newline that should render
    /// as a visible line break. Skips:
    ///   - blank-line newlines (those are already paragraph breaks)
    ///   - lines that already end with two spaces (already a hard break)
    ///   - lines inside ``` / ~~~ fenced code blocks (visible trailing
    ///     whitespace would corrupt the displayed code)
    static func hardenLineBreaks(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var out = ""
        var inFence = false
        for (i, line) in lines.enumerated() {
            out += line
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            }
            // Skip the trailing position — `split(omittingEmptySubsequences: false)`
            // surfaces a phantom empty element after a trailing newline.
            if i < lines.count - 1 {
                let next = lines[i + 1]
                let isBlankBoundary = line.isEmpty || next.isEmpty
                let alreadyHard = line.hasSuffix("  ")
                if inFence || isBlankBoundary || alreadyHard {
                    out += "\n"
                } else {
                    out += "  \n"
                }
            }
        }
        return out
    }
}

extension MarkdownUI.Theme {
    /// Tighter spacing than the default `.basic` so chat bubbles don't feel
    /// airy. Code blocks get a subtle background tint to read against the
    /// bubble's own background.
    @MainActor
    static let clarkChat: MarkdownUI.Theme = MarkdownUI.Theme()
        .text {
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.secondary.opacity(0.18))
        }
        .codeBlock { configuration in
            configuration.label
                .padding(10)
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.88))
                }
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: .em(0.5), bottom: .em(0.5))
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary).frame(width: 3)
                configuration.label
                    .padding(.leading, 8)
                    .foregroundStyle(.secondary)
            }
        }
}
