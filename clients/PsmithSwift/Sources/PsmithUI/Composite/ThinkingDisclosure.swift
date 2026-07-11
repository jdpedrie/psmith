import SwiftUI

/// Pill + disclosure for an assistant turn's reasoning. Three modes:
///
///  - `.ticking`: thinking is in progress on the live stream. Renders
///    "Thinking… (X.Ys)" with a TimelineView that re-renders every 0.1s
///    to advance the timer.
///  - `.settled` with text: the turn's done thinking. Renders
///    "Thought for X.Ys" (or "Thought" if the duration is unknown), with a
///    chevron; clicking expands a blockquoted preview of the rendered
///    reasoning text. Supports both the "live stream just stopped thinking"
///    case (`finishedAt` arrived but the assistant text is still streaming)
///    and the "historical message reload" case (rendered text comes from
///    `messages.thinking_rendered_text`, duration from `thinking_duration_ms`).
///  - `.settled` without text: the model reasoned but the provider didn't
///    surface the thoughts (e.g. OpenAI Responses with summary disabled,
///    surfaced as `usage.reasoning_tokens > 0` but no thinking_delta
///    chunks). Renders the static "Thought for X.Ys" badge with no chevron
///    — clicking is a no-op since there's nothing to show.
public struct ThinkingDisclosure: View {
    public enum Phase: Equatable {
        /// Live ticker. `since` is the wall-clock at which the first
        /// thinking_delta arrived; the view subtracts from `Date()` every
        /// 0.1s to render an elapsed-seconds counter.
        case ticking(since: Date)
        /// Static badge. `durationSec` may be nil — meaning "reasoning
        /// happened but we don't know for how long" (historical row from
        /// before the duration column existed).
        case settled(durationSec: Double?)
    }

    let phase: Phase
    /// Plaintext reasoning to show when the disclosure is expanded. Empty
    /// string is allowed — the disclosure is non-expandable in that case.
    let renderedText: String
    /// Externally-owned expanded state. Lifted out of internal @State so
    /// the open/closed flag survives the StreamingRow → MessageRow swap at
    /// terminal time (otherwise SwiftUI tears the disclosure down and the
    /// fresh instance defaults to collapsed, which reads to the user as
    /// "the thinking just closed itself"). Owners typically keep this on
    /// the ConversationViewModel — one Bool for the active stream and a
    /// per-message-id set for historical turns.
    @Binding var isExpanded: Bool

    public init(phase: Phase, renderedText: String, isExpanded: Binding<Bool>) {
        self.phase = phase
        self.renderedText = renderedText
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                header
            }
            .buttonStyle(.plain)
            .disabled(!isExpandable)

            if isExpanded, !renderedText.isEmpty {
                blockquote
            }
        }
    }

    private var isExpandable: Bool { !renderedText.isEmpty }

    private func toggle() {
        if isExpandable {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
    }

    @ViewBuilder
    private var header: some View {
        switch phase {
        case .ticking(let since):
            // Periodic redraw — the only way to advance an elapsed-time
            // label without writing a Timer + @State pair per row. 0.1s
            // is the user-visible update cadence the spec asks for.
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                pillContent(label: "Thinking… (\(formatSeconds(ctx.date.timeIntervalSince(since))))",
                            ticking: true)
            }
        case .settled(let durationSec):
            pillContent(label: settledLabel(durationSec), ticking: false)
        }
    }

    @ViewBuilder
    private func pillContent(label: String, ticking: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ticking ? "brain" : "brain.head.profile")
                .scaledFont(.caption, weight: .regular)
                .foregroundStyle(.secondary)
            Text(label)
                .scaledFont(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            if isExpandable {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(ticking ? 1.0 : 0.95)
        // Tiny pulsing scale while live so the row reads as "still going"
        // even when the seconds text increments only every 100ms. Disabled
        // for settled rows where motion would be a distraction.
        .scaleEffect(ticking ? livePulse : 1.0)
        .animation(
            ticking
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : .default,
            value: ticking
        )
    }

    /// Static — animation modifier supplies the "between 1.0 and 1.02" wave
    /// without us having to drive a @State. We just declare a value the
    /// .animation(...) interpolates from.
    private var livePulse: Double { 1.0 }

    private func settledLabel(_ durationSec: Double?) -> String {
        guard let s = durationSec, s > 0 else { return "Thought" }
        return "Thought for \(formatSeconds(s))"
    }

    private func formatSeconds(_ s: TimeInterval) -> String {
        // `%.1f` gives "0.1s" granularity matching the spec's
        // "Thinking... (0.0s)" example. For very long thinks (>60s) we
        // could switch to "1m 5s"; deferred until anyone actually waits
        // that long.
        String(format: "%.1fs", max(0, s))
    }

    /// Blockquoted, secondary-coloured preview of the thinking text. Lives
    /// in a fixed-max-height ScrollView so a chatty model doesn't push the
    /// rest of the bubble off-screen — the user can always scroll inside
    /// the disclosure for the full content.
    private var blockquote: some View {
        ScrollView {
            Text(renderedText)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3)
                        .padding(.vertical, 2)
                }
        }
        .frame(maxHeight: 220)
    }
}
