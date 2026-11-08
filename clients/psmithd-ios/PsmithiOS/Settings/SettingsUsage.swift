import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Usage (board SettingsUsage): spend over a trailing window,
/// then per provider. Reads `cost_events`, which the server records per
/// assistant turn from 2026-05 on; older spend isn't backfilled.
struct SettingsUsage: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [PsmithProviderCost] = []
    @State private var grandTotal: Double = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var range: CostRangeOption = .month
    /// Kept across range changes so returning to Custom doesn't snap to the epoch.
    @State private var customSince: Date = Date().addingTimeInterval(-30 * 86_400)
    @State private var customUntil: Date = Date()

    var body: some View {
        SettingsUsageScreen(rows: rows, grandTotal: grandTotal, loading: loading, errorText: errorText,
                            range: $range, customSince: $customSince, customUntil: $customUntil)
            .refreshable { await reload() }
            // Keyed on the window: a change cancels the in-flight fetch, so
            // a slow answer for the old range can't land under the new one.
            .task(id: windowKey) { await reload() }
    }

    private var windowKey: String {
        range == .custom
            ? "custom:\(customSince.timeIntervalSince1970):\(customUntil.timeIntervalSince1970)"
            : range.rawValue
    }

    private var window: (since: Date?, until: Date?) {
        let now = Date()
        switch range {
        case .day: return (now.addingTimeInterval(-86_400), nil)
        case .week: return (now.addingTimeInterval(-7 * 86_400), nil)
        case .month: return (now.addingTimeInterval(-30 * 86_400), nil)
        case .year: return (now.addingTimeInterval(-365 * 86_400), nil)
        case .custom:
            // Until is exclusive, so a one-day pick (since == until) still
            // covers the whole day.
            let cal = Calendar.current
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customUntil)) ?? customUntil
            return (cal.startOfDay(for: customSince), end)
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let w = window
            let result = try await app.client.modelProviders.listProviderCosts(since: w.since, until: w.until)
            guard !Task.isCancelled else { return }
            rows = result.providers
            grandTotal = result.grandTotal
            errorText = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Never leave the old window's figures under the new title.
            rows = []
            grandTotal = 0
            errorText = PsmithError.display(error)
        }
    }
}

/// Rolling windows ending now, plus Custom.
enum CostRangeOption: String, CaseIterable, Identifiable, Hashable {
    case day, week, month, year, custom
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

struct SettingsUsageScreen: View {
    let rows: [PsmithProviderCost]
    let grandTotal: Double
    let loading: Bool
    let errorText: String?
    @Binding var range: CostRangeOption
    @Binding var customSince: Date
    @Binding var customUntil: Date

    var body: some View {
        IKSettingsPage(title: "Usage") {
            IKSSegmented(options: CostRangeOption.allCases.map { ($0, $0.label) }, selection: $range)
                .padding(.top, 4)
            if range == .custom {
                IKGroup {
                    IKSRow {
                        DatePicker("From", selection: $customSince, in: ...customUntil, displayedComponents: [.date])
                    }
                    IKSRow {
                        DatePicker("To", selection: $customUntil, in: customSince..., displayedComponents: [.date])
                    }
                }
                .padding(.top, 12)
            }

            IKSHead("Spend")
            IKGroup {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsFormat.usd(grandTotal))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(IK.text)
                    Text(turns(rows.reduce(0) { $0 + $1.eventCount }))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(IK.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            IKSFooter(rangeFooter)

            if let errorText { IKSError(text: errorText) }

            IKSHead("By provider")
            IKGroup {
                if rows.isEmpty && !loading {
                    IKSRow { Text("No cost events in this window yet.").foregroundStyle(IK.secondary) }
                } else {
                    ForEach(rows) { row in providerRow(row) }
                }
            }
            IKSFooter("Recorded per assistant turn, including compression and speech. Free-tier and subscription models don’t count. Pull down to refresh.")
        }
    }

    private func providerRow(_ row: PsmithProviderCost) -> some View {
        IKSRow(vertical: 7.25) {
            Text(String(row.providerLabel.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IK.strong)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(IK.wash(0.08)))
            VStack(alignment: .leading, spacing: 0) {
                Text(row.providerLabel)
                Text(subtitle(row)).font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SettingsFormat.usd(row.totalCostUsd))
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(row.totalCostUsd == 0 ? IK.tertiary : IK.text)
        }
    }

    private func turns(_ n: Int64) -> String { "\(n) \(n == 1 ? "turn" : "turns")" }

    private func subtitle(_ row: PsmithProviderCost) -> String {
        let type: String = switch row.providerType {
        case "anthropic": "Anthropic"
        case "openai-compatible": "OpenAI-compatible"
        case "google": "Google"
        default: row.providerType
        }
        return row.eventCount == 0 ? "\(type) · no events in this window" : "\(type) · \(turns(row.eventCount))"
    }

    private var rangeFooter: String {
        switch range {
        case .day: "Trailing 24 hours."
        case .week: "Trailing 7 days."
        case .month: "Trailing 30 days."
        case .year: "Trailing 365 days."
        case .custom:
            "\(customSince.formatted(date: .abbreviated, time: .omitted)) to \(customUntil.formatted(date: .abbreviated, time: .omitted))."
        }
    }
}
