import SwiftUI
import MarkdownUI

/// Size budget for markdown rendered inline in a transcript.
///
/// A transcript row that hands MarkdownUI an unbounded document builds
/// the whole document's view tree in a single layout pass on the main
/// thread. Past a few tens of kilobytes that pass never finishes at
/// interactive timescales — SwiftUI's pending-update bookkeeping goes
/// quadratic in the number of views and the app hard-locks (reproduced
/// at 180KB: 100% CPU indefinitely, transcript never appears). The
/// compaction continuation loop makes such documents routine — a
/// multi-leg summary of a long context can exceed 100KB — so every
/// transcript markdown site renders through this budget:
///
///   - `head(_:limit:)` — the inline preview cut, for settled rows.
///     Full content stays reachable through `MarkdownDocumentView`.
///   - `tailClamped(_:limit:)` — the live-stream cut. A stream flush
///     re-renders the accumulated text every tick; only the visible
///     tail matters mid-stream, and the settled row re-renders the
///     full body through `head` at terminal.
///   - `chunks(_:target:)` — paragraph-boundary split that lets the
///     full-document viewer render any size progressively through a
///     LazyVStack instead of as one monolithic layout pass.
///
/// All cuts land on line boundaries and re-balance fenced code blocks
/// (a cut inside a fence would corrupt everything after it).
public enum MarkdownBudget {
    /// Characters of markdown a transcript row may lay out inline.
    public static let inlineLimit = 8_000
    /// Per-chunk target for the full-document viewer.
    public static let chunkTarget = 4_000

    /// Fence bookkeeping for a cut: which marker (``` or ~~~) is open,
    /// if any, at a given point in the document.
    private static func openFenceMarker<S: Sequence>(over lines: S) -> String?
    where S.Element: StringProtocol {
        var open: String? = nil
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                open = open == nil ? String(trimmed.prefix(3)) : nil
            }
        }
        return open
    }

    /// Inline preview: the leading lines of `source` up to ~`limit`
    /// characters, with any fence left open at the cut closed. Returns
    /// nil when the whole document fits the budget (render it as-is).
    /// A single line longer than the budget (minified output, one giant
    /// paragraph) is hard-cut at `limit` characters — a mid-line cut
    /// can't unbalance a fence, and preview fidelity doesn't matter at
    /// that point; only boundedness does.
    public static func head(_ source: String, limit: Int = inlineLimit) -> String? {
        guard source.count > limit else { return nil }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var out = ""
        var taken = 0
        for (i, line) in lines.enumerated() {
            let addition = line.count + (i > 0 ? 1 : 0)
            if taken + addition > limit, i > 0 { break }
            if i > 0 { out += "\n" }
            out += line
            taken += addition
        }
        if out.count > limit {
            out = String(out.prefix(limit))
        }
        if let marker = openFenceMarker(over: out.split(separator: "\n", omittingEmptySubsequences: false)) {
            out += "\n\(marker)"
        }
        return out
    }

    /// Live-stream clamp: `source` unchanged while it fits the budget,
    /// else an ellipsis line plus the trailing ~`limit` characters cut
    /// at a line boundary, with a fence reopened when the cut lands
    /// inside one. Callers re-render the full text at terminal. Same
    /// monster-line fallback as `head`, from the suffix side.
    public static func tailClamped(_ source: String, limit: Int = inlineLimit) -> String {
        guard source.count > limit else { return source }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var taken = 0
        var start = lines.count
        while start > 0 {
            let line = lines[start - 1]
            let addition = line.count + (start < lines.count ? 1 : 0)
            if taken + addition > limit, start < lines.count { break }
            taken += addition
            start -= 1
        }
        var out = lines[start...].joined(separator: "\n")
        if out.count > limit {
            out = String(out.suffix(limit))
        }
        if let marker = openFenceMarker(over: lines[..<start]) {
            out = "\(marker)\n" + out
        }
        return "…\n\n" + out
    }

    /// Paragraph-boundary split for progressive rendering. Chunks are
    /// concatenation-faithful: `chunks(s).joined() == s` — each chunk
    /// carries its own trailing newlines, so the viewer loses nothing.
    /// A boundary is a blank line outside any code fence, taken once
    /// the current chunk has reached `target` characters — fences and
    /// tables (which contain no blank lines) are never split. A single
    /// line longer than twice the target (no newlines to cut at) is
    /// hard-split into `target`-sized pieces so no chunk is unbounded.
    public static func chunks(_ source: String, target: Int = chunkTarget) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String] = []
        var current = ""
        var openFence: String? = nil
        for (i, line) in lines.enumerated() {
            let terminator = i < lines.count - 1 ? "\n" : ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                openFence = openFence == nil ? String(trimmed.prefix(3)) : nil
            }
            if line.count > target * 2 {
                // Monster line: flush, then emit it in bounded pieces.
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var rest = Substring(line)
                while rest.count > target {
                    result.append(String(rest.prefix(target)))
                    rest = rest.dropFirst(target)
                }
                current = String(rest) + terminator
                continue
            }
            current += String(line) + terminator
            if current.count >= target, openFence == nil, trimmed.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty || result.isEmpty {
            result.append(current)
        }
        return result
    }
}

/// Transcript-safe markdown body. Content within `MarkdownBudget`
/// renders exactly like `MarkdownText`; oversized content renders a
/// head preview plus a "Show full text" affordance that opens the
/// chunked `MarkdownDocumentView`, so no transcript row ever hands
/// MarkdownUI an unbounded document.
public struct BoundedMarkdownText: View {
    private let content: String
    private let cacheKey: String?
    private let documentTitle: String
    private let limit: Int
    @State private var showingFull = false

    /// `limit` tunes the inline budget per site: message bubbles use
    /// the default; the compression summary card passes a much smaller
    /// one — a multi-screen preview both reads as noise in the review
    /// flow and (as the tallest row in the cold-entry window) makes
    /// LazyVStack's content estimate flap by thousands of points,
    /// which is exactly the instability the entry machinery fights.
    public init(
        _ content: String,
        cacheKey: String? = nil,
        documentTitle: String = "Full text",
        limit: Int = MarkdownBudget.inlineLimit
    ) {
        self.content = content
        self.cacheKey = cacheKey
        self.documentTitle = documentTitle
        self.limit = limit
    }

    public var body: some View {
        if let preview = MarkdownBudget.head(content, limit: limit) {
            VStack(alignment: .leading, spacing: 8) {
                markdown(preview, keySuffix: ":head")
                Button {
                    showingFull = true
                } label: {
                    Label(
                        "Show full text (\(sizeLabel))",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .scaledFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .sheet(isPresented: $showingFull) {
                MarkdownDocumentView(
                    content,
                    cacheKey: cacheKey,
                    title: documentTitle
                )
            }
        } else {
            markdown(content, keySuffix: "")
        }
    }

    @ViewBuilder
    private func markdown(_ text: String, keySuffix: String) -> some View {
        if let key = cacheKey {
            MarkdownText(text, cacheKey: key + keySuffix)
        } else {
            MarkdownText(text)
        }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(content.utf8.count),
            countStyle: .file
        )
    }
}

/// Full-document markdown viewer: the content split at paragraph
/// boundaries into a LazyVStack, so only the visible chunks pay their
/// layout cost — any size document opens at interactive speed. This is
/// the read surface behind BoundedMarkdownText's "Show full text";
/// editing stays with the standard edit sheet.
public struct MarkdownDocumentView: View {
    private let content: String
    private let cacheKey: String?
    private let title: String
    @Environment(\.dismiss) private var dismiss

    public init(_ content: String, cacheKey: String? = nil, title: String = "Full text") {
        self.content = content
        self.cacheKey = cacheKey
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let parts = MarkdownBudget.chunks(content)
                    ForEach(parts.indices, id: \.self) { i in
                        chunk(parts[i], index: i)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    @ViewBuilder
    private func chunk(_ text: String, index: Int) -> some View {
        if let key = cacheKey {
            MarkdownText(text, cacheKey: "\(key):chunk\(index)")
        } else {
            MarkdownText(text)
        }
    }
}
