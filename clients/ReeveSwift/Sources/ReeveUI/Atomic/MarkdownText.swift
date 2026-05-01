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
        Markdown(content)
            .markdownTheme(.clarkChat)
            .textSelection(.enabled)
    }
}

extension Theme {
    /// Tighter spacing than the default `.basic` so chat bubbles don't feel
    /// airy. Code blocks get a subtle background tint to read against the
    /// bubble's own background.
    @MainActor
    static let clarkChat: Theme = Theme()
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
