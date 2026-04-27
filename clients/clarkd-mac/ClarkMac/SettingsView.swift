import SwiftUI
import ClarkKit

/// Dedicated settings page. Three columns:
///   1. Categories sidebar (Providers / Profiles), styled like the chats list.
///   2. Items list — header (back button | title + count | round glass create
///      button) above the list of providers / profiles.
///   3. Detail — header (item name + type | Edit + Delete) above a full-width
///      tab bar (Enabled Models / Discover Models for providers).
struct SettingsView: View {
    @Bindable var providersModel: ProvidersViewModel
    @Bindable var profilesModel: ProfilesViewModel
    let onBack: () -> Void

    @State private var category: SettingsCategory = .providers

    var body: some View {
        HSplitView {
            categoriesColumn
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            middleColumn
                .frame(minWidth: 260, idealWidth: 320)
            detailColumn
                .frame(minWidth: 420)
        }
        .frame(minWidth: 940, minHeight: 520)
    }

    // MARK: - Column 1: categories sidebar

    private var categoriesColumn: some View {
        List(SettingsCategory.allCases, selection: Binding(
            get: { Optional(category) },
            set: { if let new = $0 { category = new } }
        )) { c in
            Label(c.label, systemImage: c.systemImage)
                .tag(Optional(c))
        }
        .listStyle(.sidebar)
    }

    // MARK: - Column 2: items list

    @ViewBuilder
    private var middleColumn: some View {
        switch category {
        case .providers:
            ProvidersMiddleColumn(model: providersModel, onBack: onBack)
        case .profiles:
            ProfilesMiddleColumn(model: profilesModel, onBack: onBack)
        }
    }

    // MARK: - Column 3: detail

    @ViewBuilder
    private var detailColumn: some View {
        switch category {
        case .providers:
            ProvidersDetail(model: providersModel)
        case .profiles:
            ProfilesDetail(model: profilesModel)
        }
    }
}

// MARK: - Middle-column header (shared)

/// Header row used at the top of the items list column. Back button left,
/// title + count center, round blue glass create button right. No banded
/// background — the buttons themselves carry the Liquid Glass character.
struct SettingsListHeader: View {
    let title: String
    let count: Int
    let countNoun: String
    let onBack: () -> Void
    let onCreate: () -> Void
    let createDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            GlassCircleButton(systemImage: "chevron.left", action: onBack, help: "Back")

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(count) \(countNoun)\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            GlassCircleButton(
                systemImage: "plus",
                action: onCreate,
                help: "Create",
                tint: .accentColor,
                disabled: createDisabled
            )
        }
        .padding(.horizontal, 10)
        .frame(height: paneHeaderHeight)
    }
}

/// Compact icon-only Liquid Glass circle button — used in pane headers
/// for actions like back, edit, delete, create. All buttons share the same
/// 24×24 footprint so headers read as a row of consistent affordances.
struct GlassCircleButton: View {
    let systemImage: String
    let action: () -> Void
    let help: String
    var tint: Color? = nil
    var disabled: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .glassEffect(
                    tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(),
                    in: .circle
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
