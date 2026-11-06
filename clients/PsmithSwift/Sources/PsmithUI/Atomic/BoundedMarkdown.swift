import SwiftUI
import MarkdownUI

/// Size budget for markdown rendered inline in a transcript.
///
/// A transcript row that hands MarkdownUI an unbounded document builds
/// the whole document's view tree in a single layout pass on the main
/// thread. Past a few tens of kilobytes that pass never finishes at
/// interactive timescales — SwiftUI's pending-update bookkeeping goes
/// quadratic in the number of views and the app hard-locks (reproduced
/// on iOS at 180KB: 100% CPU indefinitely, transcript never appears).
/// The compaction continuation loop makes such documents routine — a
/// multi-leg summary of a long context can exceed 100KB — so every
/// transcript markdown site renders through this budget:
///
///   - `chunks(_:target:)` — paragraph-boundary split. `ChunkedMarkdownText`
///     stacks one MarkdownUI document per chunk, so a body renders in
///     full while no single document exceeds `chunkTarget`. Boundaries
///     are prefix-stable, which is what lets the live stream row
///     re-render per flush at the cost of its growing tail chunk only.
///   - `head(_:limit:)` — the inline preview cut behind
///     `BoundedMarkdownText`: a deliberately short preview on the
///     compression summary card, and the safety valve past
///     `inlineLimit` on message bubbles. Full content stays reachable
///     through `MarkdownDocumentView`.
///
/// All cuts land on line boundaries and re-balance fenced code blocks
/// (a cut inside a fence would corrupt everything after it).
public enum MarkdownBudget {
    /// Characters of markdown a message bubble renders inline before
    /// falling back to a head preview plus the full-document viewer.
    /// Chunked layout cost measured linear on macOS 26 (about 12ms per
    /// KB of markdown when the row realizes; 180KB took 3s), so this
    /// is a valve against multi-second stalls on the rare giant turn
    /// near a large `max_output_tokens`, not a routine cut: ordinary
    /// long replies (the 8-30KB that the old 8,000-character budget
    /// truncated) render whole.
    public static let inlineLimit = 48_000
    /// Per-document target for chunked rendering. Past this, a chunk
    /// closes at the next safe boundary.
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
    public static func head(_ source: String, limit: Int) -> String? {
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

    /// Paragraph-boundary split for chunked rendering. Chunks are
    /// concatenation-faithful: `chunks(s).joined() == s` — each chunk
    /// carries its own trailing newlines, so nothing is lost.
    ///
    /// A chunk closes once it has reached `target` characters, at the
    /// first boundary that keeps both halves parsing the way the whole
    /// did. The preferred boundary is a blank line outside any code
    /// fence whose next block starts at column 0 — a list continuation
    /// or nested item cut from its parent would re-parse as an indented
    /// code block. A run with no blank lines (a long tight list, a
    /// hard-wrapped essay) falls back at twice the target to any
    /// column-0 line outside a fence, and at four times the target to
    /// any line outside a fence; both skip table rows, since a body row
    /// without its header re-parses as prose. Fences are never split. A
    /// single line longer than twice the target (no newlines to cut at)
    /// is hard-split into `target`-sized pieces so no chunk is unbounded.
    ///
    /// Boundaries are prefix-stable: appending text never moves a
    /// boundary already decided, so a streaming row that re-chunks its
    /// accumulated text each flush hands every settled chunk an
    /// identical string and only the tail chunk changes value.
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
            // Never cut after the final line: nothing follows it, and
            // while streaming it is the line still being written.
            guard openFence == nil, current.count >= target, i < lines.count - 1 else { continue }
            if canClose(current: current, before: i + 1, in: lines, target: target, afterBlank: trimmed.isEmpty) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty || result.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Whether a chunk of `current` may close so that line `index`
    /// opens the next one. See `chunks` for the tiers.
    private static func canClose(
        current: String,
        before index: Int,
        in lines: [Substring],
        target: Int,
        afterBlank: Bool
    ) -> Bool {
        // The line that would open the next chunk: past any further
        // blank lines when closing on a blank one.
        var j = index
        if afterBlank {
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                j += 1
            }
            guard j < lines.count else { return false }
        }
        let opener = lines[j]
        let openerIsTopLevel = !(opener.first?.isWhitespace ?? true)
        let openerIsTableRow = opener.first == "|"
        if afterBlank {
            return openerIsTopLevel
        }
        if openerIsTableRow { return false }
        if current.count >= target * 4 { return true }
        return current.count >= target * 2 && openerIsTopLevel
    }
}

/// Transcript-safe markdown body: the content split at paragraph
/// boundaries into a stack of MarkdownUI documents, so a message of any
/// size renders in full while no single document exceeds
/// `MarkdownBudget.chunkTarget`. Chunks stack with the same nil-length
/// padding MarkdownUI puts between blocks that declare no margin, so a
/// boundary is invisible.
///
/// The live stream row renders its accumulated text through this view
/// every flush. Chunk boundaries are prefix-stable, so every settled
/// chunk receives an identical `MarkdownText` value (Equatable) and
/// only the growing tail chunk re-parses.
public struct ChunkedMarkdownText: View {
    private let content: String
    private let cacheKey: String?

    /// `cacheKey` opts into `MarkdownCache` per chunk. A one-chunk body
    /// keeps the bare key so entries prewarmed under it hit; longer
    /// bodies suffix the chunk index.
    public init(_ content: String, cacheKey: String? = nil) {
        self.content = content
        self.cacheKey = cacheKey
    }

    public var body: some View {
        let parts = MarkdownBudget.chunks(content)
        if parts.count == 1 {
            chunk(parts[0], key: cacheKey)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(parts.indices, id: \.self) { i in
                    chunk(parts[i], key: cacheKey.map { "\($0):chunk\(i)" })
                        .padding(.top, i == 0 ? 0 : nil)
                }
            }
        }
    }

    @ViewBuilder
    private func chunk(_ text: String, key: String?) -> some View {
        if let key {
            MarkdownText(text, cacheKey: key)
        } else {
            MarkdownText(text)
        }
    }
}

/// Transcript message body. Content within `limit` renders in full as
/// a `ChunkedMarkdownText`; past it, a head preview plus a "Show full
/// text" affordance opening the chunked `MarkdownDocumentView`.
///
/// `limit` tunes the budget per site. Message bubbles take the default
/// (`MarkdownBudget.inlineLimit`, a valve only giant turns reach). The
/// compression summary card passes a much smaller one — a multi-screen
/// preview both reads as noise in the review flow and (as the tallest
/// row in the cold-entry window) makes the iOS transcript's content
/// estimate flap by thousands of points.
public struct BoundedMarkdownText: View {
    private let content: String
    private let cacheKey: String?
    private let documentTitle: String
    private let limit: Int
    @State private var showingFull = false

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
                ChunkedMarkdownText(preview, cacheKey: cacheKey.map { $0 + ":head" })
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
            ChunkedMarkdownText(content, cacheKey: cacheKey)
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
/// the read surface behind BoundedMarkdownText's "Show full text" and
/// the iOS action menu's "Select text"; editing stays with the standard
/// edit sheet.
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
            // The reader is the selection surface: on whichever
            // transcript presents it with per-paragraph selection off.
            .environment(\.markdownTextSelectable, true)
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
