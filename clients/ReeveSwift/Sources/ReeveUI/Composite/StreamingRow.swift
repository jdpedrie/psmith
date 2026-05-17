import SwiftUI
import ReeveKit

/// Live assistant bubble shown while the supervisor is streaming chunks.
/// Width-capped to match the materialised assistant `MessageRow`'s
/// footprint so when the stream resolves and the StreamingRow is
/// replaced by the real row, there's no visible width jolt.
///
/// Composition:
///  - "ASSISTANT" header + spinner.
///  - Optional `ThinkingDisclosure` when `thinkingStartedAt` is non-nil.
///  - One `ToolCallLivePill` per active tool call (always non-interactive
///    here — see `ToolCallDisclosure.swift` for the crash-safety
///    rationale).
///  - The streamed text rendered as Markdown, OR a "…" placeholder when
///    text is empty AND no thinking/tool activity is visible.
public struct StreamingRow: View {
    let text: String
    /// Reasoning text accumulated during this stream. Populated by the
    /// view-model's `.thinkingDelta` chunk handler. Empty for non-reasoning
    /// turns; non-empty triggers the click-to-expand disclosure.
    let thinkingText: String
    /// Wall-clock the first thinking delta arrived. Nil when reasoning
    /// hasn't started yet (or the model isn't reasoning at all).
    let thinkingStartedAt: Date?
    /// Wall-clock the first text delta arrived after thinking. While this
    /// is nil the badge ticks live; the moment the model flips to producing
    /// the visible answer we freeze the duration display at "Thought for
    /// X.Ys" — same UX the user will see on the materialised history row a
    /// moment later.
    let thinkingFinishedAt: Date?
    /// External binding to the disclosure's open/closed state. Lives on
    /// the ConversationViewModel so the value survives the StreamingRow →
    /// MessageRow swap at terminal time.
    @Binding var thinkingExpanded: Bool
    /// Tool calls captured on the active stream, in start order.
    let toolCalls: [LiveToolCall]
    /// When true, render with the compression-summary chrome (orange
    /// accent + "Compression summary" header) instead of the regular
    /// assistant bubble. Lets the live row match the materialised
    /// CompressionSummaryCard visually so the user sees the right
    /// affordance from the first chunk, not just after stream end.
    let isCompression: Bool
    @Environment(\.chatPaneWidth) private var paneWidth

    public init(
        text: String,
        thinkingText: String,
        thinkingStartedAt: Date?,
        thinkingFinishedAt: Date?,
        thinkingExpanded: Binding<Bool>,
        toolCalls: [LiveToolCall],
        isCompression: Bool = false
    ) {
        self.text = text
        self.thinkingText = thinkingText
        self.thinkingStartedAt = thinkingStartedAt
        self.thinkingFinishedAt = thinkingFinishedAt
        self._thinkingExpanded = thinkingExpanded
        self.toolCalls = toolCalls
        self.isCompression = isCompression
    }

    public var body: some View {
        if isCompression {
            compressionBubble
        } else {
            // Assistant streams render bare — no bubble chrome — to match
            // the settled assistant MessageRow. A bubble during the stream
            // that vanishes on terminal would jolt the layout; bare both
            // sides means the only visible change at terminal is the
            // spinner going away.
            bareAssistantBody
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var compressionBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.orange)
                Text("Compression summary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                ProgressView().controlSize(.mini)
            }
            innerContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Bare assistant streaming body — same shape as the settled
    /// MessageRow.assistantContent: role label + spinner + optional
    /// thinking/tool disclosures, then the streamed markdown text.
    /// No padding beyond what the parent LazyVStack already supplies,
    /// no background, no clip — so the terminal swap to the settled
    /// row is invisible.
    @ViewBuilder
    private var bareAssistantBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ASSISTANT")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            innerContent
        }
    }

    /// Shared body content under either header: thinking → tool calls →
    /// streamed text (or "…" placeholder when nothing has arrived yet).
    @ViewBuilder
    private var innerContent: some View {
        if let started = thinkingStartedAt {
            ThinkingDisclosure(
                phase: thinkingFinishedAt.map { f in
                    .settled(durationSec: f.timeIntervalSince(started))
                } ?? .ticking(since: started),
                renderedText: thinkingText,
                isExpanded: $thinkingExpanded
            )
        }
        ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, call in
            ToolCallLivePill(call: call)
        }
        if text.isEmpty {
            if thinkingStartedAt == nil, toolCalls.isEmpty {
                Text("…").foregroundStyle(.secondary)
            }
        } else {
            // Hide `<tag>...</tag>` blocks (and in-progress `<tag>…`
            // partials) from the live stream display. Without this,
            // the user watches a `<scene_header>{` ... `</scene_header>`
            // block stream in as raw JSON, then jerk into a rendered
            // component when terminal lands. With buffering, the
            // block is represented by a small `…` placeholder during
            // streaming and the real component appears in the
            // settled MessageRow at terminal — no JSON-to-component
            // jolt.
            MarkdownText(bufferComponentTags(in: text))
                .font(isCompression ? .callout : nil)
        }
    }
}

/// Replaces every component-tag block in `text` with a `…` ellipsis
/// so the streaming bubble doesn't expose raw JSON mid-stream.
///
/// Rules:
/// - Closed pair `<tag>body</tag>` → `…`
/// - Open-only partial `<tag>body…` (no close yet) → `…` + everything
///   after the open tag is hidden (it'll re-appear in subsequent
///   ticks as the close arrives).
///
/// "Tag" = `<` + a lowercase-letter+underscore identifier + `>`. The
/// strict identifier pattern excludes literal `<https://…>` autolinks
/// and most accidental angle-bracket usage. Cap of 40 chars keeps
/// runaway non-tag matches from eating large spans.
///
/// Exposed at file scope (not member-private) so unit tests in ReeveUI
/// can exercise the rule set without instantiating StreamingRow.
public func bufferComponentTags(in text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var i = text.startIndex
    while i < text.endIndex {
        guard let openLT = text[i...].firstIndex(of: "<") else {
            out += text[i...]
            break
        }
        out += text[i..<openLT]
        let afterLT = text.index(after: openLT)
        // Scan up to the next ">" for the tag name. Bail (treat `<`
        // as literal) on any non-tag-char or if we hit end-of-text
        // before the closing bracket.
        guard let gtIdx = text[afterLT...].firstIndex(of: ">"),
              isValidComponentTagName(text[afterLT..<gtIdx])
        else {
            out.append("<")
            i = afterLT
            continue
        }
        let tagName = text[afterLT..<gtIdx]
        let afterOpenTag = text.index(after: gtIdx)
        let closeTag = "</\(tagName)>"
        if let closeRange = text.range(of: closeTag, range: afterOpenTag..<text.endIndex) {
            // Complete block — placeholder, continue after close.
            out.append("…")
            i = closeRange.upperBound
        } else {
            // Open tag, no close yet — hide from here onward. Stops
            // the partial JSON from flashing through the bubble. The
            // next stream tick re-runs this with more text; once the
            // close arrives, the block becomes a `…` placeholder.
            out.append("…")
            return out
        }
    }
    return out
}

/// True when `s` is a plausible component-builder tag name:
/// lowercase ASCII letters + digits + underscore, starts with a
/// letter, ≤40 chars. Mirrors the practical shape every shipped
/// component name uses today (choice_list, scene_header, key_value,
/// etc.) without committing the client to know any specific
/// plugin's config.
private func isValidComponentTagName(_ s: Substring) -> Bool {
    guard !s.isEmpty, s.count <= 40 else { return false }
    guard let first = s.first, first.isLetter, first.isASCII, first.isLowercase else {
        return false
    }
    for c in s {
        if c == "_" { continue }
        if !c.isASCII { return false }
        if !c.isLetter && !c.isNumber { return false }
        if c.isLetter && !c.isLowercase { return false }
    }
    return true
}
