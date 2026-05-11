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
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        HStack(alignment: .top, spacing: 8) {
            bubble
                .frame(maxWidth: isCompression ? .infinity : cap, alignment: .leading)
            if !isCompression {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isCompression {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.orange)
                    Text("Compression summary")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                } else {
                    Text("ASSISTANT")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.mini)
            }
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
                MarkdownText(text)
                    .font(isCompression ? .callout : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isCompression ? 12 : 10)
        .background(
            isCompression
                ? AnyShapeStyle(.regularMaterial)
                : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .background(
            isCompression ? Color.orange.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isCompression
                        ? Color.orange.opacity(0.35)
                        : Color.primary.opacity(0.06),
                    lineWidth: isCompression ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
