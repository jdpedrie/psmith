import SwiftUI
import MarkdownUI

/// Renders a markdown string with block-level support (headers, lists, code
/// blocks, tables). Used for both finished assistant messages and the live
/// streaming row — incomplete syntax during streaming is rendered as plain
/// text by the parser, so half-written code fences look fine until they close.
///
/// Performance: parsing markdown is the per-realization bottleneck for
/// long conversations — every time a row scrolls back into the LazyVStack
/// window, MarkdownUI re-parses from the source string. Settled message
/// bodies don't change, so the parsed `MarkdownContent` can be cached
/// process-wide via `MarkdownCache`. Use the `cacheSource:` initializer
/// to opt in (the parameter is the message id + an "edited at" stamp so
/// post-edit content invalidates naturally).
public struct MarkdownText: View {
    private enum Source {
        case raw(String)
        case cached(key: String, source: String)
    }
    private let source: Source
    @Environment(\.fontScale) private var fontScale

    public init(_ content: String) {
        self.source = .raw(content)
    }

    /// Cached variant: parsed `MarkdownContent` is memoised under `key`
    /// in `MarkdownCache.shared`, so subsequent realizations of this
    /// view (or any other MarkdownText with the same key) skip the
    /// parse entirely. Pass an id-style key that includes a freshness
    /// signal — typically `"\(message.id):\(editedAtTimestamp ?? 0)"`
    /// — so an edit invalidates the cache automatically.
    public init(_ content: String, cacheKey: String) {
        self.source = .cached(key: cacheKey, source: content)
    }

    public var body: some View {
        Markdown(parsedContent)
            .markdownTheme(.clarkChat)
            // MarkdownUI's base size is a library constant (13pt on
            // macOS) — it does NOT inherit the SwiftUI environment
            // font, so the app-wide fontScale has to be threaded in
            // explicitly. Appending an absolute FontSize here rescales
            // the whole document; the theme's em-relative styles (code
            // spans, code blocks) cascade from it. At scale 1.0 this
            // is exactly the library default, byte-identical rendering.
            .markdownTextStyle {
                // Rounded to an integral point size: fractional bases
                // (13 × 1.1 = 14.3pt) made multi-line list items
                // MEASURE shorter than they RENDER on macOS — across a
                // long bulleted answer the drift accumulated to a full
                // line and the bubble clipped the tail mid-glyph
                // (snapshot-verified at scale 1.1, narrow pane — the
                // Mac "bullets truncate" report). Integral sizes keep
                // measurement and rendering in agreement; the visual
                // cost is the scale snapping to the nearest point.
                FontSize((FontProperties.defaultSize * fontScale).rounded())
            }
            .textSelection(.enabled)
    }

    private var parsedContent: MarkdownContent {
        switch source {
        case .raw(let s):
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
            return MarkdownContent(Self.hardenLineBreaks(s))
        case .cached(let key, let s):
            return MarkdownCache.shared.parsed(forKey: key, source: s)
        }
    }

    /// Adds two trailing spaces before each newline that should render
    /// as a visible line break. Skips:
    ///   - blank-line newlines (those are already paragraph breaks)
    ///   - lines that already end with two spaces (already a hard break)
    ///   - lines inside ``` / ~~~ fenced code blocks (visible trailing
    ///     whitespace would corrupt the displayed code)
    /// Pure / nonisolated so MarkdownCache.prewarm can call it off the
    /// main thread.
    public nonisolated static func hardenLineBreaks(_ source: String) -> String {
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

/// Process-wide cache of parsed `MarkdownContent` keyed by an opaque
/// caller-supplied string. Cleared on conversation switch via `clear()`
/// (called from the iOS pane's `.task(id:)`); stays warm otherwise.
///
/// Background pre-warm: `prewarm(_:)` parses entries off the main thread
/// (MarkdownContent is value-type / Sendable) and bulk-inserts on
/// MainActor. Caller passes (key, source) tuples typically derived from
/// `(message.id + edited_at, displayContent ?? content)`.
@MainActor
public final class MarkdownCache {
    public static let shared = MarkdownCache()

    private var store: [String: MarkdownContent] = [:]

    private init() {}

    /// Returns the cached parsed content for `key`, or parses + stores
    /// + returns if absent. Called from MarkdownText's body on the
    /// cached-source path.
    public func parsed(forKey key: String, source: String) -> MarkdownContent {
        if let cached = store[key] { return cached }
        let content = MarkdownContent(MarkdownText.hardenLineBreaks(source))
        store[key] = content
        return content
    }

    /// Drop a single entry (e.g., after EditMessage commits new content).
    public func invalidate(_ key: String) {
        store.removeValue(forKey: key)
    }

    /// Reset everything. Call on conversation switch so memory doesn't
    /// accumulate forever across sessions.
    public func clear() {
        store.removeAll()
    }

    /// Pre-parse a batch of (key, source) pairs off the main thread and
    /// install them. Skips entries that are already cached, so a
    /// subsequent `load()` after a terminal event only does the new
    /// assistant turn's parse work. Best-effort — failures are silent
    /// (the foreground render path will still parse on demand).
    public func prewarm(_ entries: [(key: String, source: String)]) {
        // Filter the entries we still need before paying the cost of
        // shipping them to a background task.
        let missing = entries.filter { store[$0.key] == nil }
        if missing.isEmpty { return }
        Task.detached(priority: .userInitiated) {
            // MarkdownContent is a Sendable value type; parsing is pure.
            let parsed = missing.map { entry -> (String, MarkdownContent) in
                (entry.key, MarkdownContent(MarkdownText.hardenLineBreaks(entry.source)))
            }
            await MainActor.run {
                for (k, c) in parsed where MarkdownCache.shared.store[k] == nil {
                    MarkdownCache.shared.store[k] = c
                }
            }
        }
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
            // Code lines don't wrap — a wide line would otherwise
            // stretch the whole message (and, via the chat pane's
            // maxWidth: .infinity rows, the entire conversation)
            // beyond the viewport. Give the code its OWN horizontal
            // scroller so wide code stays readable AND contained: the
            // outer chat pane stays exactly viewport-wide and never
            // pans sideways. `.scrollClipDisabled(false)` keeps the
            // overflow inside the rounded background.
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .padding(10)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
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
        .table { configuration in
            // Same containment strategy as codeBlock: tables are the
            // other block class whose minimum width is content-driven
            // (MarkdownUI lays them out as a Grid — the column minima
            // can exceed the chat pane, and a mid-transition layout
            // pass with a loose width proposal renders the grid at its
            // ideal width, flush past both screen edges). A horizontal
            // scroller gives wide tables their natural width inside a
            // viewport-bounded strip: readable cells, and the chat
            // pane can never be dragged sideways.
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
            }
            .markdownMargin(top: .em(0.5), bottom: .em(0.5))
        }
}
