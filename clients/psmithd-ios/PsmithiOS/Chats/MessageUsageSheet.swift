import SwiftUI
import PsmithKit
import PsmithUI

/// iOS message-usage sheet — `.medium`/`.large` detents per
/// `docs/clients/ios-reference.md` Renders the same Model / Tokens /
/// Cache / Cost breakdown the Mac shows in its popover, just stacked
/// for a phone-shaped sheet.
struct MessageUsageSheet: View {
    let message: PsmithMessage
    let model: ConversationViewModel

    var body: some View {
        Form {
            modelSection
            tokensSection
            cacheSection
            costSection
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("Model") {
            if let pid = message.providerID, let label = model.providerLabels[pid] {
                row("Provider", label)
            }
            if let mid = message.modelID {
                let display = model.availableModels
                    .first(where: { $0.modelID == mid && (message.providerID == nil || $0.providerID == message.providerID) })?
                    .displayName
                row("Model", display ?? mid)
            }
            if let cap = model.availableModels
                .first(where: { $0.modelID == message.modelID && (message.providerID == nil || $0.providerID == message.providerID) }) {
                row("Context window", cap.contextWindow.map { "\($0.formatted()) tokens" } ?? "—")
            }
        }
    }

    @ViewBuilder
    private var tokensSection: some View {
        if let usage = message.usage {
            Section("Tokens") {
                if let n = usage.inputTokens   { row("Input", n.formatted()) }
                if let n = usage.outputTokens  { row("Output", n.formatted()) }
                if let n = usage.reasoningTokens, n > 0 { row("Reasoning", n.formatted()) }
            }
        }
    }

    @ViewBuilder
    private var cacheSection: some View {
        if let usage = message.usage,
           (usage.cacheReadTokens ?? 0) > 0 || (usage.cacheWriteTokens ?? 0) > 0 {
            Section("Cache") {
                if let n = usage.cacheReadTokens, n > 0 {
                    row("Read", "\(n.formatted()) tokens")
                }
                if let n = usage.cacheWriteTokens, n > 0 {
                    row("Write", "\(n.formatted()) tokens")
                }
                if let attached = usage.explicitCacheAttached {
                    row("Explicit cache", attached ? "Attached" : "Toggle on, not attached")
                }
            }
        }
    }

    @ViewBuilder
    private var costSection: some View {
        if let usage = message.usage,
           (usage.totalCostUsd ?? 0) > 0
            || (usage.inputCostUsd ?? 0) > 0
            || (usage.outputCostUsd ?? 0) > 0
            || (usage.toolCostUsd ?? 0) > 0 {
            Section("Cost") {
                if let v = usage.inputCostUsd, v > 0      { row("Input",       priceStr(v)) }
                if let v = usage.outputCostUsd, v > 0     { row("Output",      priceStr(v)) }
                if let v = usage.cacheReadCostUsd, v > 0  { row("Cache read",  priceStr(v)) }
                if let v = usage.cacheWriteCostUsd, v > 0 { row("Cache write", priceStr(v)) }
                if let v = usage.toolCostUsd, v > 0       { row("Tools",       priceStr(v)) }
                if let v = usage.totalCostUsd, v > 0 {
                    row("Total", priceStr(v), bold: true)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(bold ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func priceStr(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.2f", v) }
        if v >= 1   { return String(format: "$%.3f", v) }
        return String(format: "$%.4f", v)
    }
}
