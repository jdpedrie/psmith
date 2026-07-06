import SwiftUI
import PsmithKit

/// Pill UI for one tool call captured on an assistant turn. Mirrors the
/// `ThinkingDisclosure` design language so the chrome reads consistently
/// across reasoning and tool-use pills.
///
/// Two surfaces:
///
///  - `ToolCallLivePill` — non-interactive timer chip used inside the
///    `StreamingRow`. NO Button, NO chevron, NO expansion. The pill walks
///    through three phases driven by chunk arrival timestamps:
///      `.generating(since:)`  while args are streaming
///      `.executing(since:)`   while the loop dispatches the plugin
///      `.done(durationSec:hasError:)` on `tool_result` arrival
///    A `TimelineView(.periodic)` advances the elapsed-seconds label every
///    0.1s; the icon pulses gently to read as "still going". Crash-safety
///    note (macOS 26.2 SwiftUI runtime bug): keeping this surface
///    Button-free removes a click target the user might reflexively tap
///    while the stream is churning.
///
///  - `ToolCallSettledDisclosure` — Button-wrapped pill + expandable body
///    used inside `MessageRow` (materialised history). Chevron toggles a
///    blockquoted body showing pretty-printed input JSON, then the
///    output JSON (or the error string in red). Body lives inside a
///    bounded ScrollView so a chatty plugin doesn't push the rest of the
///    bubble off-screen — same treatment as ThinkingDisclosure.

public struct ToolCallLivePill: View {
    let call: LiveToolCall
    /// Optional binding to make the pill expandable on tap. When nil
    /// the pill stays Button-free (preserves the original streaming-row
    /// behaviour for callers that don't need inspect-as-it-happens).
    /// When bound, the pill renders a chevron and toggles a disclosure
    /// body showing the streamed input + output so far — the same
    /// req/resp inspection surface the settled disclosure offers, but
    /// available mid-stream for debugging.
    @Binding var isExpanded: Bool
    private let isExpansionEnabled: Bool

    public init(call: LiveToolCall) {
        self.call = call
        self._isExpanded = .constant(false)
        self.isExpansionEnabled = false
    }

    public init(call: LiveToolCall, isExpanded: Binding<Bool>) {
        self.call = call
        self._isExpanded = isExpanded
        self.isExpansionEnabled = true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pillChrome
            if isExpansionEnabled, isExpanded {
                liveDisclosureBody
            }
        }
    }

    @ViewBuilder
    private var pillChrome: some View {
        switch call.phase {
        case .generating(let since):
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                wrappedChip(ToolPillChip(
                    iconName: "wrench.and.screwdriver",
                    label: "Using \(call.name) (\(formatSeconds(ctx.date.timeIntervalSince(since))))",
                    pulsing: true,
                    chevron: chevronStyle
                ))
            }
        case .executing(let since):
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                wrappedChip(ToolPillChip(
                    iconName: "gearshape.2",
                    label: "Processing \(call.name) result (\(formatSeconds(ctx.date.timeIntervalSince(since))))",
                    pulsing: true,
                    chevron: chevronStyle
                ))
            }
        case .done(let dur, let hasError):
            wrappedChip(ToolPillChip(
                iconName: hasError ? "exclamationmark.triangle" : "checkmark",
                label: doneLabel(name: call.name, durationSec: dur, hasError: hasError),
                pulsing: false,
                chevron: chevronStyle,
                accentTint: hasError ? .orange : nil
            ))
        }
    }

    private var chevronStyle: ToolPillChip.Chevron {
        guard isExpansionEnabled else { return .none }
        return isExpanded ? .down : .right
    }

    @ViewBuilder
    private func wrappedChip<C: View>(_ chip: C) -> some View {
        if isExpansionEnabled {
            Button(action: toggle) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    }

    /// Disclosure body for the live pill — mirrors the settled
    /// disclosure's layout (Input + Output sections, blockquoted, capped
    /// height) but reads from `LiveToolCall`'s string input + optional
    /// output bytes. Sections fall back to "(streaming…)" when bytes
    /// haven't arrived yet so the user can see *something* the moment
    /// they expand mid-stream.
    @ViewBuilder
    private var liveDisclosureBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                liveSection(title: "Input", body: liveInputText)
                if let err = call.error {
                    liveSection(title: "Error", body: err, tint: .orange)
                } else {
                    liveSection(title: "Output", body: liveOutputText)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: 260)
    }

    private var liveInputText: String {
        if call.input.isEmpty { return "(streaming…)" }
        if let data = call.input.data(using: .utf8) { return prettyJSON(data) }
        return call.input
    }

    private var liveOutputText: String {
        guard let out = call.output else {
            switch call.phase {
            case .done: return "(empty)"
            default:    return "(streaming…)"
            }
        }
        return prettyJSON(out)
    }

    private func liveSection(title: String, body: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(body)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public struct ToolCallSettledDisclosure: View {
    let call: PsmithToolCall
    @Binding var isExpanded: Bool

    public init(call: PsmithToolCall, isExpanded: Binding<Bool>) {
        self.call = call
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                ToolPillChip(
                    iconName: call.error != nil ? "exclamationmark.triangle" : "checkmark",
                    label: doneLabel(
                        name: call.name,
                        durationSec: Double(call.elapsedMs) / 1000.0,
                        hasError: call.error != nil
                    ),
                    pulsing: false,
                    chevron: isExpanded ? .down : .right,
                    accentTint: call.error != nil ? .orange : nil
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                disclosureBody
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    }

    @ViewBuilder
    private var disclosureBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section(title: "Input", body: prettyJSON(call.input))
                if let err = call.error {
                    section(title: "Error", body: err, tint: .orange)
                } else {
                    section(title: "Output", body: prettyJSON(call.output))
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: 260)
    }

    private func section(title: String, body: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(body)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared chrome

private struct ToolPillChip: View {
    enum Chevron { case none, right, down }

    let iconName: String
    let label: String
    let pulsing: Bool
    var chevron: Chevron = .none
    var accentTint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.regular))
                .foregroundStyle(accentTint ?? .secondary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(accentTint ?? .secondary)
                .monospacedDigit()
                .lineLimit(1)
            switch chevron {
            case .none:
                EmptyView()
            case .right:
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            case .down:
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .opacity(pulsing ? 1.0 : 0.95)
        // Same gentle-pulse trick ThinkingDisclosure uses: declare a value
        // the .animation modifier interpolates between, no @State needed.
        .scaleEffect(pulsing ? 1.0 : 1.0)
        .animation(
            pulsing
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : .default,
            value: pulsing
        )
    }
}

// MARK: - Formatting helpers

private func doneLabel(name: String, durationSec: Double, hasError: Bool) -> String {
    if hasError {
        return "\(name) failed (\(formatSeconds(durationSec)))"
    }
    return "Used \(name) (\(formatSeconds(durationSec)))"
}

private func formatSeconds(_ s: TimeInterval) -> String {
    String(format: "%.1fs", max(0, s))
}

/// Pretty-prints raw JSON bytes for the disclosure body. Falls back to a
/// UTF-8 decode (or "(empty)") so the user sees *something* even when the
/// payload isn't well-formed JSON — never crash, never throw.
private func prettyJSON(_ data: Data) -> String {
    if data.isEmpty { return "(empty)" }
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: pretty, encoding: .utf8) {
        return text
    }
    return String(data: data, encoding: .utf8) ?? "(unreadable: \(data.count) bytes)"
}
