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
    @Environment(WindowState.self) private var windowState
    @Environment(Navigator.self) private var navigator

    /// macOS draws an opaque ~36pt title-bar overlay only when the window is
    /// zoomed — normal and fullscreen leave the title-bar area transparent.
    /// Reserve a strip in the right two columns when zoomed so headers stay
    /// visible; in the other modes content sits flush against the top.
    /// macOS draws an opaque title-bar overlay only when the window is
    /// zoomed — normal and fullscreen leave that band transparent. Reserve
    /// just enough space to clear the overlay when zoomed; in the other
    /// modes the headers sit flush against the top.
    private var topInset: CGFloat {
        windowState.mode == .zoomed ? 36 : 0
    }

    var body: some View {
        // Column minWidths sum below the window's 1080pt minimum
        // (180 + 220 + 540 = 940pt) so HSplitView can honor each column's
        // floor with headroom. The detail floor is set high enough to
        // accommodate the model edit form's wide segmented pickers
        // (Service tier / Response format) — narrower values caused the
        // form's intrinsic content to overflow into the previous column.
        HSplitView {
            categoriesColumn
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
            insetWrap(middleColumn)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            insetWrap(detailColumn)
                .frame(minWidth: 540)
        }
        .frame(minWidth: 1040, minHeight: 520)
        .onAppear { consumePendingProfileSelection() }
        .onChange(of: navigator.pendingProfileSelection) { _, _ in
            consumePendingProfileSelection()
        }
    }

    /// If a ProfileCard's gear button asked us to drill into a specific
    /// profile, switch to the Profiles category and select it. The signal
    /// is cleared after consumption so re-entering settings later doesn't
    /// re-trigger the jump.
    private func consumePendingProfileSelection() {
        guard let id = navigator.pendingProfileSelection else { return }
        category = .profiles
        profilesModel.select(id)
        navigator.pendingProfileSelection = nil
    }

    /// Stacks an opaque Spacer above the column when the window is zoomed,
    /// so the column's header clears macOS's opaque title-bar overlay.
    /// `padding`/`safeAreaInset` haven't been reliably reaching the inner
    /// VStack in this layout, so we use an explicit wrapper VStack.
    @ViewBuilder
    private func insetWrap<Content: View>(_ content: Content) -> some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                Color.clear.frame(height: topInset)
            }
            content
        }
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
/// for actions like back, edit, delete, create. The ZStack with Color.clear
/// forces every instance to the same 26×26 footprint regardless of which
/// SF Symbol it carries (chevron.left, plus, pencil, trash all have
/// different intrinsic widths). The glass effect lives on the button itself
/// so .buttonStyle(.plain) gets a clean rectangular hit target.
struct GlassCircleButton: View {
    let systemImage: String
    let action: () -> Void
    let help: String
    var tint: Color? = nil
    var disabled: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(),
            in: .circle
        )
        .disabled(disabled)
        .help(help)
    }
}
