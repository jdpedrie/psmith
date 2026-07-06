import SwiftUI
import PsmithKit

/// Per-provider cost rollup. One row per configured provider showing the
/// running total in USD; the navigation bar carries the grand total so the
/// user has the answer to "how much have I spent total?" without scrolling.
///
/// The screen reads from `cost_events` (server-side, populated forward from
/// 2026-05 onward — see migration 00025). Historical spend isn't backfilled;
/// per-row message costs continue to live on `messages.*` for the
/// per-conversation chip + usage popovers.
struct CostDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [PsmithProviderCost] = []
    @State private var grandTotal: Double = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var range: CostRangeOption = .month
    /// Custom-window endpoints. Initialised lazily when the user picks
    /// `.custom`; before then they shadow the previous picker's window
    /// so switching back to Custom doesn't snap to the unix epoch.
    @State private var customSince: Date = Date().addingTimeIntervalDays(-30)
    @State private var customUntil: Date = Date()

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(CostRangeOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if range == .custom {
                    DatePicker(
                        "From",
                        selection: $customSince,
                        in: ...customUntil,
                        displayedComponents: [.date]
                    )
                    DatePicker(
                        "To",
                        selection: $customUntil,
                        in: customSince...,
                        displayedComponents: [.date]
                    )
                }
            } footer: {
                Text(rangeFooter)
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if rows.isEmpty && !loading {
                    Text("No cost events in this window yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.providerLabel)
                                    .font(.body)
                                Text(subtitle(for: row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(formatUSD(row.totalCostUsd))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text("Spend is recorded per assistant turn (including compression). Free-tier and subscription models don't contribute to this total.")
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: range) { _, _ in Task { await reload() } }
        .onChange(of: customSince) { _, _ in if range == .custom { Task { await reload() } } }
        .onChange(of: customUntil) { _, _ in if range == .custom { Task { await reload() } } }
    }

    private var navTitle: String {
        if loading && rows.isEmpty {
            return "Cost"
        }
        return "Cost · \(formatUSD(grandTotal))"
    }

    private var rangeFooter: String {
        switch range {
        case .day:    return "Trailing 24 hours."
        case .week:   return "Trailing 7 days."
        case .month:  return "Trailing 30 days."
        case .year:   return "Trailing 365 days."
        case .custom:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return "\(fmt.string(from: customSince)) – \(fmt.string(from: customUntil))."
        }
    }

    /// Computes the (since, until) bounds for the current selection.
    /// `nil` ends are unbounded — only Custom and the fixed-trailing
    /// options ever produce a non-nil `since`; nothing produces an
    /// `until` cap except Custom, since the trailing windows always
    /// extend through "now."
    private var currentWindow: (since: Date?, until: Date?) {
        let now = Date()
        switch range {
        case .day:    return (now.addingTimeIntervalDays(-1),   nil)
        case .week:   return (now.addingTimeIntervalDays(-7),   nil)
        case .month:  return (now.addingTimeIntervalDays(-30),  nil)
        case .year:   return (now.addingTimeIntervalDays(-365), nil)
        case .custom:
            // Promote the Until date to the end-of-day boundary so a
            // single-day selection (since == until) still includes the
            // whole day's events under exclusive-until semantics.
            let cal = Calendar.current
            let untilEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customUntil))
                ?? customUntil
            return (cal.startOfDay(for: customSince), untilEnd)
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let w = currentWindow
            let result = try await app.client.modelProviders.listProviderCosts(
                since: w.since,
                until: w.until
            )
            rows = result.providers
            grandTotal = result.grandTotal
            errorText = nil
        } catch {
            errorText = PsmithError.display(error)
        }
    }

    private func subtitle(for row: PsmithProviderCost) -> String {
        let typeLabel = providerTypeLabel(row.providerType)
        if row.eventCount == 0 {
            return "\(typeLabel) · no events in this window"
        }
        return "\(typeLabel) · \(row.eventCount) \(row.eventCount == 1 ? "turn" : "turns")"
    }

    private func providerTypeLabel(_ raw: String) -> String {
        switch raw {
        case "anthropic": return "Anthropic"
        case "openai-compatible": return "OpenAI-compatible"
        case "google": return "Google"
        default: return raw
        }
    }

    /// Always 4 decimal places — mirrors the in-conversation cost chip so the
    /// settings rollup never reads as a different unit than the chip the user
    /// sees on each turn.
    private func formatUSD(_ amount: Double) -> String {
        String(format: "$%.4f", amount)
    }
}

/// Trailing-window presets plus Custom. Day/Week/Month/Year are rolling
/// (from "now minus N days" through "now") so the user always sees the
/// most recent budgetable period; calendar-aligned ranges (e.g. "this
/// month from the 1st") would diverge from this and aren't an obvious
/// win for at-a-glance cost reads.
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

private extension Date {
    /// Convenience: subtract N days from a Date. Avoids the
    /// `Calendar.date(byAdding:...)?` optional unwrap noise at the few
    /// call sites that just need approximate trailing windows; for those,
    /// 86400 × N is good enough.
    func addingTimeIntervalDays(_ days: Int) -> Date {
        addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
