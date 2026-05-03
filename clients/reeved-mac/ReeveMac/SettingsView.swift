import SwiftUI
import ReeveKit

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
    @Environment(\.theme) private var theme

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

    /// Hand-rolled sidebar instead of `List(.sidebar)` — the AppKit-backed
    /// sidebar List paints its selection background from
    /// NSColor.controlAccentColor (the SYSTEM accent), which ignores
    /// SwiftUI's `.tint()`. Manual rows let the active row honor the active
    /// theme's accent.
    private var categoriesColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { c in
                categoryRow(c)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func categoryRow(_ c: SettingsCategory) -> some View {
        let active = (category == c)
        Button {
            category = c
        } label: {
            Label(c.label, systemImage: c.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Column 2: items list

    @ViewBuilder
    private var middleColumn: some View {
        switch category {
        case .providers:
            ProvidersMiddleColumn(model: providersModel, onBack: onBack)
        case .profiles:
            ProfilesMiddleColumn(model: profilesModel, onBack: onBack)
        case .plugins:
            PluginSettingsMiddleColumn(model: profilesModel, onBack: onBack)
        case .appearance:
            AppearanceMiddleColumn(onBack: onBack)
        case .general:
            GeneralMiddleColumn(onBack: onBack)
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
        case .plugins:
            PluginSettingsDetail(model: profilesModel)
        case .appearance:
            AppearanceSettingsView()
        case .general:
            GeneralSettingsView()
        }
    }
}

// MARK: - General middle column

/// Skinny placeholder column for the General category — same shape as
/// AppearanceMiddleColumn (no list to browse, just the back button +
/// section label). The actual content lives in the detail column.
private struct GeneralMiddleColumn: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlassCircleButton(systemImage: "chevron.left", action: onBack, help: "Back")
                Text("General")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: paneHeaderHeight)
            Divider()
            Spacer()
        }
    }
}

// MARK: - Appearance middle column

/// Skinny placeholder column for the Appearance category — no item list to
/// browse, just a back button + section label so the three-column grid still
/// reads correctly. The detail column carries the actual picker. No create
/// button in the header (no items to create at this scope), which is why we
/// hand-roll the header instead of reusing SettingsListHeader.
private struct AppearanceMiddleColumn: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlassCircleButton(systemImage: "chevron.left", action: onBack, help: "Back")

                VStack(alignment: .leading, spacing: 0) {
                    Text("Appearance")
                        .font(.headline)
                        .lineLimit(1)
                    Text("1 section")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: paneHeaderHeight)

            List {
                Label("Theme", systemImage: "paintpalette")
                    .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
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
    @Environment(\.theme) private var theme

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
                tint: theme.accent,
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
