import SwiftUI
import PsmithKit

/// Aggregate view-model for `ModelMetaStrip` + `ModelDetailPopover`. Lets
/// both enabled-model rows (`PsmithUserModel`) and discovery rows
/// (`PsmithDiscoveredModel`) feed the same widget without making each
/// caller inflate a full `PsmithUserModel`.
public struct ModelMetaSnapshot {
    public let displayName: String
    public let modelID: String
    /// Provider human-readable name when known; nil during discovery
    /// where the row isn't yet bound to a configured provider.
    public let providerLabel: String?
    public let contextWindow: Int32?
    public let maxOutputTokens: Int32?
    public let pricing: PsmithModelPricing?
    public let knowledgeCutoff: String?
    public let modalities: [String]
    public let capabilities: PsmithModelCapabilities?

    public init(
        displayName: String,
        modelID: String,
        providerLabel: String?,
        contextWindow: Int32?,
        maxOutputTokens: Int32?,
        pricing: PsmithModelPricing?,
        knowledgeCutoff: String?,
        modalities: [String],
        capabilities: PsmithModelCapabilities?
    ) {
        self.displayName = displayName
        self.modelID = modelID
        self.providerLabel = providerLabel
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.pricing = pricing
        self.knowledgeCutoff = knowledgeCutoff
        self.modalities = modalities
        self.capabilities = capabilities
    }
}

public extension PsmithUserModel {
    func metaSnapshot(providerLabel: String?) -> ModelMetaSnapshot {
        ModelMetaSnapshot(
            displayName: displayName, modelID: modelID,
            providerLabel: providerLabel,
            contextWindow: contextWindow, maxOutputTokens: maxOutputTokens,
            pricing: pricing, knowledgeCutoff: knowledgeCutoff,
            modalities: modalities, capabilities: capabilities
        )
    }
}

public extension PsmithDiscoveredModel {
    func metaSnapshot(providerLabel: String?) -> ModelMetaSnapshot {
        // Discovery rows don't carry knowledge cutoff / max output tokens
        // / modalities — the wire shape only includes what we need to
        // render the row + decide whether to enable.
        ModelMetaSnapshot(
            displayName: displayName, modelID: modelID,
            providerLabel: providerLabel,
            contextWindow: contextWindow, maxOutputTokens: nil,
            pricing: pricing, knowledgeCutoff: nil,
            modalities: [], capabilities: capabilities
        )
    }
}

/// Compact metadata strip for a model row: ctx · cost-bucket · cutoff ·
/// capability icons. Each chip is fixed-width-natural so they never wrap;
/// capabilities are condensed to single SF Symbols to keep the strip thin.
/// Tooltips on each chip show the full detail; tapping anywhere on the
/// strip opens a popover with the full breakdown (pricing per token
/// type, expanded capability descriptions, modalities, context limits).
public struct ModelMetaStrip: View {
    let snapshot: ModelMetaSnapshot

    @State private var showDetail = false

    public init(snapshot: ModelMetaSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        Button(action: { showDetail.toggle() }) {
            HStack(spacing: 6) {
                if let ctx = snapshot.contextWindow {
                    metaChip(ctxLabel(ctx), help: "Context window: \(ctx.formatted()) tokens — click for details")
                }
                if let bucket = costBucket(snapshot.pricing) {
                    metaChip(bucket, .orange, help: pricingTooltip)
                }
                if let cutoff = snapshot.knowledgeCutoff, !cutoff.isEmpty {
                    metaChip(cutoff, help: "Knowledge cutoff: \(cutoff)")
                }
                if let caps = snapshot.capabilities {
                    HStack(spacing: 4) {
                        if caps.thinking      { capabilityIcon("brain",                .purple, "Thinking — model exposes its chain-of-thought.") }
                        if caps.vision        { capabilityIcon("eye",                  .blue,   "Vision — accepts images as input.") }
                        if caps.toolUse       { capabilityIcon("wrench.adjustable",    .teal,   "Tool use — supports function calling.") }
                        if caps.promptCaching { capabilityIcon("tray.full",            .green,  "Prompt caching — reuses cached prefixes for cheaper repeat calls.") }
                    }
                    .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            ModelDetailPopover(snapshot: snapshot)
        }
    }

    private var pricing: PsmithModelPricing? { snapshot.pricing }

    private func ctxLabel(_ n: Int32) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M"
            : n >= 1_000 ? "\(n / 1_000)K"
            : "\(n)"
    }

    /// Builds a multi-line tooltip with input/output (and cache) per-million prices.
    private var pricingTooltip: String {
        guard let p = pricing else { return "" }
        var lines: [String] = []
        if let inp = p.inputPerMillion, inp > 0 {
            lines.append("Input: \(formatPrice(inp))/M tokens")
        }
        if let outp = p.outputPerMillion, outp > 0 {
            lines.append("Output: \(formatPrice(outp))/M tokens")
        }
        if let cr = p.cacheReadPerMillion, cr > 0 {
            lines.append("Cache read: \(formatPrice(cr))/M tokens")
        }
        if let cw = p.cacheWritePerMillion, cw > 0 {
            lines.append("Cache write: \(formatPrice(cw))/M tokens")
        }
        return lines.joined(separator: "\n")
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1   { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    private func metaChip(_ label: String, _ color: Color = .secondary, help: String) -> some View {
        Text(label)
            .scaledFont(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .help(help)
    }

    private func capabilityIcon(_ name: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: name)
            .scaledFont(.caption2)
            .foregroundStyle(color)
            .help(help)
    }
}

/// Maps a model's pricing into [$, $$, $$$, $$$$] based on output cost per
/// million tokens — output dominates real-world spend. Returns nil when
/// pricing isn't known.
public func costBucket(_ pricing: PsmithModelPricing?) -> String? {
    guard let outp = pricing?.outputPerMillion, outp > 0 else { return nil }
    switch outp {
    case ..<3:    return "$"
    case 3..<15:  return "$$"
    case 15..<50: return "$$$"
    default:      return "$$$$"
    }
}

// MARK: - Model detail popover
//
// Mirrors MessageUsagePopover's section/row idiom for visual consistency:
// uppercased small caption header per section, label-left/value-right
// rows in callout font. Surfaces every field on ModelMetaSnapshot the
// strip's chips can only hint at — full per-token pricing, context AND
// max output limits, expanded capability descriptions, modalities.

private struct ModelDetailPopover: View {
    let snapshot: ModelMetaSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Model") {
                row("Name", snapshot.displayName)
                row("ID", snapshot.modelID)
                if let label = snapshot.providerLabel {
                    row("Provider", label)
                }
            }

            // Limits — context + max output. Both rendered as raw token
            // counts (the chip uses the K/M abbreviation for compactness).
            let hasLimits = snapshot.contextWindow != nil || snapshot.maxOutputTokens != nil
            if hasLimits {
                section("Limits") {
                    if let n = snapshot.contextWindow {
                        row("Context window", "\(n.formatted()) tokens")
                    }
                    if let n = snapshot.maxOutputTokens {
                        row("Max output", "\(n.formatted()) tokens")
                    }
                }
            }

            if let p = snapshot.pricing,
               (p.inputPerMillion ?? 0) > 0 || (p.outputPerMillion ?? 0) > 0 ||
               (p.cacheReadPerMillion ?? 0) > 0 || (p.cacheWritePerMillion ?? 0) > 0 {
                section("Pricing (USD per 1M tokens)") {
                    if let v = p.inputPerMillion, v > 0       { row("Input",       priceStr(v)) }
                    if let v = p.outputPerMillion, v > 0      { row("Output",      priceStr(v)) }
                    if let v = p.cacheReadPerMillion, v > 0   { row("Cache read",  priceStr(v)) }
                    if let v = p.cacheWritePerMillion, v > 0  { row("Cache write", priceStr(v)) }
                }
            }

            if let caps = snapshot.capabilities,
               caps.thinking || caps.vision || caps.toolUse || caps.promptCaching || caps.streaming {
                section("Capabilities") {
                    if caps.streaming     { capabilityRow("waveform",             "Streaming",      "Server-sent token-by-token output.") }
                    if caps.thinking      { capabilityRow("brain",                "Thinking",       "Exposes its chain-of-thought.") }
                    if caps.vision        { capabilityRow("eye",                  "Vision",         "Accepts images as input.") }
                    if caps.toolUse       { capabilityRow("wrench.adjustable",    "Tool use",       "Function calling supported.") }
                    if caps.promptCaching { capabilityRow("tray.full",            "Prompt caching", "Reuses cached prefixes for cheaper repeat calls.") }
                }
            }

            if !snapshot.modalities.isEmpty {
                section("Modalities") {
                    row("Input/Output", snapshot.modalities.joined(separator: ", "))
                }
            }

            if let cutoff = snapshot.knowledgeCutoff, !cutoff.isEmpty {
                section("Knowledge") {
                    row("Cutoff", cutoff)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
    }

    private func priceStr(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1   { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(bold ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .scaledFont(.callout)
    }

    /// Capability row: icon + name on the left, prose explanation on
    /// the right. The explanation echoes the chip tooltip so the user
    /// has the same context here.
    @ViewBuilder
    private func capabilityRow(_ icon: String, _ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .scaledFont(.callout)
                Text(description)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}
