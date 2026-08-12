import PsmithKit
import SwiftUI

/// Results of a model capability probe.
///
/// The screen has one job beyond listing outcomes: make clear that a probe can
/// only ever switch a capability on. Someone reading "Vision: unsupported" next
/// to a checked Vision box needs to understand that nothing was taken away and
/// that the decision is theirs, or the honest thing (reporting a disagreement
/// we refuse to act on) reads as a bug.
public struct CapabilityProbeView: View {
    private let status: CapabilityProbeStatus
    private let onProbe: (_ apply: Bool) -> Void

    @Environment(\.theme) private var theme

    public init(status: CapabilityProbeStatus, onProbe: @escaping (_ apply: Bool) -> Void) {
        self.status = status
        self.onProbe = onProbe
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch status {
            case .idle:
                Text("Runs a handful of tiny requests to see what this model actually supports. Costs a few tokens.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .probing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Probing…").scaledFont(.caption).foregroundStyle(.secondary)
                }
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let probe):
                results(probe)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Capabilities")
                .scaledFont(.callout, weight: .semibold)
            Spacer(minLength: 8)
            Button("Probe") { onProbe(false) }
                .buttonStyle(.borderless)
                .scaledFont(.caption)
                .disabled(status == .probing)
        }
    }

    @ViewBuilder
    private func results(_ probe: PsmithCapabilityProbe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(probe.results) { r in
                row(r)
            }

            if !probe.enabled.isEmpty {
                // A dry run reports what it WOULD turn on, so this same line
                // reads correctly before and after applying.
                Label(
                    "Would enable: " + probe.enabled.joined(separator: ", "),
                    systemImage: "plus.circle"
                )
                .scaledFont(.caption)
                .foregroundStyle(.secondary)

                Button("Apply") { onProbe(true) }
                    .buttonStyle(.borderless)
                    .scaledFont(.caption)
            } else {
                Text("Nothing new to enable.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if !probe.contradicted.isEmpty {
                // Deliberately worded as information, not an error. The probe
                // will not clear these and the user may know better than it
                // does; a refusal can come from the probe's own prompt.
                Text("This model refused: " + probe.contradicted.joined(separator: ", ")
                    + ". Left switched on — clear it yourself if that is wrong.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ r: PsmithCapabilityProbeResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(r.outcome))
                .foregroundStyle(tint(r.outcome))
                .scaledFont(.caption)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.displayName)
                    .scaledFont(.caption, weight: .medium)
                if !r.detail.isEmpty {
                    Text(r.detail)
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if r.latencyMs > 0 {
                Text("\(r.latencyMs)ms")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func icon(_ o: PsmithProbeOutcome) -> String {
        switch o {
        case .supported: return "checkmark.circle.fill"
        case .unsupported: return "slash.circle"
        case .inconclusive: return "questionmark.circle"
        case .skipped: return "minus.circle"
        }
    }

    /// Only a demonstrated capability gets the accent. Everything else is
    /// secondary, including refusals: an inconclusive probe is the common case
    /// and painting it red would make a normal result look broken.
    private func tint(_ o: PsmithProbeOutcome) -> Color {
        switch o {
        case .supported: return theme.accent
        default: return .secondary
        }
    }
}
