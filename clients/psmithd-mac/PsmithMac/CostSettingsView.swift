import SwiftUI
import PsmithKit

/// Per-provider cost rollup for the Mac. One row per configured
/// provider with the running USD total; the header carries the grand
/// total so "how much have I spent?" has an answer without scanning.
/// Reads cost_events server-side (populated forward from 2026-05;
/// per-turn costs also live on messages for the in-conversation chip).
struct CostSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [PsmithProviderCost] = []
    @State private var grandTotal: Double = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var range: CostRangeOption = .month
    @State private var customSince: Date = Date().addingTimeInterval(-30 * 86_400)
    @State private var customUntil: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cost")
                            .scaledFont(.title2, weight: .semibold)
                        Spacer()
                        if !loading || !rows.isEmpty {
                            Text(formatUSD(grandTotal))
                                .scaledFont(.title3, weight: .medium, monospacedDigit: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Spend recorded per assistant turn (including compression and speech synthesis). Free-tier and subscription models don't contribute.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                sectionCard("Range") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Range", selection: $range) {
                            ForEach(CostRangeOption.allCases) { opt in
                                Text(opt.label).tag(opt)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if range == .custom {
                            HStack(spacing: 16) {
                                DatePicker("From", selection: $customSince, in: ...customUntil, displayedComponents: [.date])
                                DatePicker("To", selection: $customUntil, in: customSince..., displayedComponents: [.date])
                            }
                        }
                        Text(rangeFooter)
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .scaledFont(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                sectionCard("By provider") {
                    if rows.isEmpty && !loading {
                        Text("No cost events in this window yet.")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.providerLabel)
                                        Text(subtitle(for: row))
                                            .scaledFont(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(formatUSD(row.totalCostUsd))
                                        .monospacedDigit()
                                }
                                .padding(.vertical, 6)
                                if row.id != rows.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await reload() }
        .onChange(of: range) { _, _ in Task { await reload() } }
        .onChange(of: customSince) { _, _ in if range == .custom { Task { await reload() } } }
        .onChange(of: customUntil) { _, _ in if range == .custom { Task { await reload() } } }
    }

    private var rangeFooter: String {
        switch range {
        case .day:   return "Trailing 24 hours."
        case .week:  return "Trailing 7 days."
        case .month: return "Trailing 30 days."
        case .year:  return "Trailing 365 days."
        case .custom:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            return "\(fmt.string(from: customSince)) – \(fmt.string(from: customUntil))."
        }
    }

    private var currentWindow: (since: Date?, until: Date?) {
        let now = Date()
        switch range {
        case .day:   return (now.addingTimeInterval(-86_400), nil)
        case .week:  return (now.addingTimeInterval(-7 * 86_400), nil)
        case .month: return (now.addingTimeInterval(-30 * 86_400), nil)
        case .year:  return (now.addingTimeInterval(-365 * 86_400), nil)
        case .custom:
            // Promote Until to the end-of-day boundary so a single-day
            // selection still includes that day under exclusive-until.
            let cal = Calendar.current
            let untilEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customUntil)) ?? customUntil
            return (cal.startOfDay(for: customSince), untilEnd)
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let w = currentWindow
            let result = try await app.client.modelProviders.listProviderCosts(since: w.since, until: w.until)
            rows = result.providers
            grandTotal = result.grandTotal
            errorText = nil
        } catch {
            if PsmithError.isCancellation(error) { return }
            errorText = PsmithError.display(error)
        }
    }

    private func subtitle(for row: PsmithProviderCost) -> String {
        let typeLabel: String
        switch row.providerType {
        case "anthropic": typeLabel = "Anthropic"
        case "openai-compatible": typeLabel = "OpenAI-compatible"
        case "google": typeLabel = "Google"
        default: typeLabel = row.providerType
        }
        if row.eventCount == 0 {
            return "\(typeLabel) · no events in this window"
        }
        return "\(typeLabel) · \(row.eventCount) \(row.eventCount == 1 ? "turn" : "turns")"
    }

    /// Always 4 decimals — matches the in-conversation cost chip so the
    /// rollup never reads as a different unit.
    private func formatUSD(_ amount: Double) -> String {
        String(format: "$%.4f", amount)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Trailing-window presets plus Custom — rolling windows (now minus N
/// days) rather than calendar-aligned, matching the iOS screen.
enum CostRangeOption: String, CaseIterable, Identifiable, Hashable {
    case day, week, month, year, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day:    return "Day"
        case .week:   return "Week"
        case .month:  return "Month"
        case .year:   return "Year"
        case .custom: return "Custom"
        }
    }
}
