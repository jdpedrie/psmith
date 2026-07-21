import SwiftUI
import PsmithKit

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
    /// Resolver invoked per live tool call to produce a binding for
    /// its expand/collapse state — lets the ViewModel own the storage
    /// (typically a Set<String> keyed by callID) so expansion choices
    /// survive the StreamingRow → MessageRow swap at terminal time.
    /// When nil, pills render non-interactive (the original behaviour).
    let toolCallExpansionBinding: ((LiveToolCall) -> Binding<Bool>)?
    /// When true, render with the compression-summary chrome (orange
    /// accent + "Compression summary" header) instead of the regular
    /// assistant bubble. Lets the live row match the materialised
    /// CompressionSummaryCard visually so the user sees the right
    /// affordance from the first chunk, not just after stream end.
    let isCompression: Bool
    /// (tag-name, renderer-component) pairs the active pipeline exposes
    /// as streamable components. When non-empty, the streamed text is
    /// parsed into segments — closed `<tag>body</tag>` blocks render
    /// as the named component inline (no JSON-flash); in-progress
    /// partials hide until the close lands. Empty list falls back to
    /// rendering the streamed text verbatim as markdown.
    let streamingComponents: [PsmithStreamingComponentTag]
    @Environment(\.chatPaneWidth) private var paneWidth

    public init(
        text: String,
        thinkingText: String,
        thinkingStartedAt: Date?,
        thinkingFinishedAt: Date?,
        thinkingExpanded: Binding<Bool>,
        toolCalls: [LiveToolCall],
        toolCallExpansionBinding: ((LiveToolCall) -> Binding<Bool>)? = nil,
        isCompression: Bool = false,
        streamingComponents: [PsmithStreamingComponentTag] = []
    ) {
        self.text = text
        self.thinkingText = thinkingText
        self.thinkingStartedAt = thinkingStartedAt
        self.thinkingFinishedAt = thinkingFinishedAt
        self._thinkingExpanded = thinkingExpanded
        self.toolCalls = toolCalls
        self.toolCallExpansionBinding = toolCallExpansionBinding
        self.isCompression = isCompression
        self.streamingComponents = streamingComponents
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
                    .scaledFont(.caption)
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
                    .scaledFont(.caption2)
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
            if let resolver = toolCallExpansionBinding {
                ToolCallLivePill(call: call, isExpanded: resolver(call))
            } else {
                ToolCallLivePill(call: call)
            }
        }
        if text.isEmpty {
            if thinkingStartedAt == nil, toolCalls.isEmpty {
                Text("…").foregroundStyle(.secondary)
            }
        } else {
            streamingBody
        }
    }

    /// Renders the streaming text as an interleaved sequence of
    /// markdown segments and live-rendered component blocks. Complete
    /// `<tag>body</tag>` blocks (for tags in `streamingComponents`)
    /// hand the parsed JSON body to FragmentView and render the same
    /// way they will at terminal — no JSON-flash, no jolt. Open-only
    /// partials (close hasn't streamed yet) collapse to a `…`
    /// placeholder until the next stream tick fills them in.
    ///
    /// When `streamingComponents` is empty (the common pre-config
    /// case), the entire text renders as plain markdown verbatim —
    /// no surprise hiding of stray angle brackets in prose.
    @ViewBuilder
    private var streamingBody: some View {
        // Tail-clamped: every flush re-renders this body, and a long
        // run (a multi-leg compaction stream especially) accumulates
        // past the point where a full markdown re-layout per tick
        // freezes the app. Mid-stream only the tail is on screen
        // anyway; the settled row renders the full body at terminal.
        // Clamping before segment parsing also bounds the parse. A cut
        // that lands inside a component block degrades that block to
        // prose for the remainder of the stream — transient, and far
        // cheaper than the alternative.
        let segments = parseStreamingSegments(
            MarkdownBudget.tailClamped(text),
            components: streamingComponents
        )
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let s):
                    MarkdownText(s)
                        .scaledFont(isCompression ? .callout : .body)
                case .fragment(let frag):
                    FragmentView(fragments: [frag], onAction: { _ in })
                case .pendingBlock:
                    Text("…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One slice of streaming text. Drives the interleaved render
/// inside StreamingRow.
enum StreamingSegment {
    /// Plain prose between (or around) component blocks. Rendered
    /// as markdown.
    case text(String)
    /// A completed `<tag>body</tag>` block whose body parsed as JSON
    /// for a known component renderer. Rendered live via FragmentView.
    case fragment(PsmithUIFragment)
    /// An open tag with no matching close yet. Will resolve on a
    /// later stream tick; for now we show a small placeholder rather
    /// than expose the partial JSON.
    case pendingBlock
}

/// Walk `text` linearly, splitting on any opening tag listed in
/// `components`. For a matched close, emit a `.fragment`; for an
/// unmatched open (mid-stream), emit `.pendingBlock` and stop.
///
/// Exposed at package scope (internal) for unit testability — callers
/// outside PsmithUI should drive this through StreamingRow.
func parseStreamingSegments(_ text: String, components: [PsmithStreamingComponentTag]) -> [StreamingSegment] {
    // Empty pipeline → no parsing, just one prose segment.
    if components.isEmpty {
        return [.text(text)]
    }

    // Build a tag-name → renderer-component lookup for O(1) match
    // tests inside the walk.
    var byTag: [String: String] = [:]
    byTag.reserveCapacity(components.count)
    for c in components {
        byTag[c.tag] = c.component
    }

    var segments: [StreamingSegment] = []
    var pending = ""
    var i = text.startIndex

    func flushPending() {
        if !pending.isEmpty {
            segments.append(.text(pending))
            pending = ""
        }
    }

    while i < text.endIndex {
        guard let lt = text[i...].firstIndex(of: "<") else {
            pending += text[i...]
            break
        }
        // Accumulate prose up to the `<`.
        pending += text[i..<lt]
        let afterLT = text.index(after: lt)
        guard let gt = text[afterLT...].firstIndex(of: ">") else {
            // No `>` yet — the model is mid-typing the opening tag.
            // Hide the dangling `<` + whatever followed and wait for
            // more bytes.
            flushPending()
            segments.append(.pendingBlock)
            return segments
        }
        let tagName = String(text[afterLT..<gt])
        guard let component = byTag[tagName] else {
            // Not a known component tag — render the `<...>` as
            // literal markdown prose.
            pending += text[lt..<text.index(after: gt)]
            i = text.index(after: gt)
            continue
        }
        let bodyStart = text.index(after: gt)
        let closeTag = "</\(tagName)>"
        guard let closeRange = text.range(of: closeTag, range: bodyStart..<text.endIndex) else {
            // Open tag, no close yet — flush prose, mark a pending
            // block placeholder, and stop. The next tick re-parses
            // from scratch with the additional bytes.
            flushPending()
            segments.append(.pendingBlock)
            return segments
        }
        let body = String(text[bodyStart..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The block is closed. Validate the body as JSON — invalid
        // bodies (e.g., the model emitted prose inside the tags by
        // mistake) become a pending placeholder so the bubble stays
        // tidy rather than rendering a broken fragment mid-stream;
        // the settled MessageRow at terminal will preserve the raw
        // tags + body as text via the existing fallback path.
        guard let bodyData = body.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: bodyData, options: [])) != nil
        else {
            flushPending()
            segments.append(.pendingBlock)
            i = closeRange.upperBound
            continue
        }
        flushPending()
        segments.append(.fragment(
            PsmithUIFragment(component: component, props: bodyData, key: "")
        ))
        i = closeRange.upperBound
    }
    flushPending()
    return segments
}
