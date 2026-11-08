import SwiftUI
import PsmithKit

/// The Usage pane (boards "Usage" and "Usage · a custom range"): the total
/// for a window, then one row per provider with a bar against the top
/// spender.
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

    @State private var sinceText = ""
    @State private var untilText = ""

    var body: some View {
        SKFormPage(width: 700) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).sk(12.5, SK.secondary).skOneLine(12.5)
                    Text(formatUSD(grandTotal))
                        .sk(34, weight: .bold)
                        .monospacedDigit()
                        .skOneLine(34)
                }
                Spacer(minLength: 0)
                SKSegmented(options: CostRangeOption.allCases.map { ($0, $0.label) }, selection: $range)
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium)).frame(width: 13)
                }
                .skButton(compact: true)
                .accessibilityLabel("Refresh")
            }
            .padding(.bottom, 18)

            if range == .custom {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("From").sk(12.5, SK.secondary)
                    TextField("From", text: $sinceText).skField(width: 110, mono: true).onSubmit(applyDates)
                    Text("to").sk(12.5, SK.secondary)
                    TextField("To", text: $untilText).skField(width: 110, mono: true).onSubmit(applyDates)
                }
                .padding(.top, -6)
                .padding(.bottom, 18)
                .onAppear {
                    sinceText = Self.isoDay.string(from: customSince)
                    untilText = Self.isoDay.string(from: customUntil)
                }
            }

            if let errorText {
                SKBanner(.error, "Couldn't load spending", message: errorText)
            }

            SKGroup("By provider") {
                if rows.isEmpty {
                    SKRawRow {
                        if loading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Text("No spending in this range yet.").sk(13, SK.secondary)
                        }
                    }
                } else {
                    let top = max(rows.map(\.totalCostUsd).max() ?? 0, 0.000_001)
                    ForEach(rows, id: \.providerID) { row in
                        SKRow(row.providerLabel, detail: subtitle(for: row)) {
                            HStack(spacing: 12) {
                                Capsule().fill(Color.white.opacity(0.07))
                                    .frame(width: 140, height: 6)
                                    .overlay(alignment: .leading) {
                                        if row.totalCostUsd > 0 {
                                            Capsule().fill(SK.accent).frame(width: max(140 * row.totalCostUsd / top, 1.4), height: 6)
                                        }
                                    }
                                Text(formatUSD(row.totalCostUsd)).sk(13, mono: true)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                    }
                }
            } trailing: {
                SKChip.synced
            } footer: {
                Text("Every assistant turn, including compression and speech synthesis. Free-tier and subscription models count as $0.")
            }
        }
        // Cancel an in-flight load when the window changes; a slow earlier
        // answer would otherwise land last under the new range's label.
        .task(id: reloadKey) { await reload() }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func applyDates() {
        if let d = Self.isoDay.date(from: sinceText) { customSince = d }
        if let d = Self.isoDay.date(from: untilText) { customUntil = d }
        if customSince > customUntil { swap(&customSince, &customUntil) }
        sinceText = Self.isoDay.string(from: customSince)
        untilText = Self.isoDay.string(from: customUntil)
    }

    private var headline: String {
        switch range {
        case .day: return "Spent in the last 24 hours"
        case .week: return "Spent in the last 7 days"
        case .month: return "Spent in the last 30 days"
        case .year: return "Spent in the last 365 days"
        case .custom:
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMM d")
            let y = DateFormatter()
            y.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
            return "Spent from \(f.string(from: customSince)) to \(y.string(from: customUntil))"
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

    private var reloadKey: String {
        range == .custom ? "custom-\(customSince.timeIntervalSince1970)-\(customUntil.timeIntervalSince1970)" : "\(range)"
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let w = currentWindow
            let result = try await app.client.modelProviders.listProviderCosts(since: w.since, until: w.until)
            guard !Task.isCancelled else { return }
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
            return "\(typeLabel) · no turns in this range"
        }
        return "\(typeLabel) · \(row.eventCount) \(row.eventCount == 1 ? "turn" : "turns")"
    }

    /// Cents, except a nonzero total under a cent, which gets decimals
    /// down to its first significant digit so it doesn't read as $0.00.
    private func formatUSD(_ amount: Double) -> String {
        guard amount > 0, amount < 0.01 else {
            return String(format: "$%.2f", amount)
        }
        let decimals = min(6, max(3, Int((-log10(amount)).rounded(.up))))
        return String(format: "$%.\(decimals)f", amount)
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
