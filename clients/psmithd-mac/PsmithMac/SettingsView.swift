import SwiftUI
import PsmithKit
import PsmithUI

/// Dedicated settings page. Three columns:
///   1. Categories sidebar (Providers / Profiles), styled like the chats list.
///   2. Items list — header (back button | title + count | round glass create
///      button) above the list of providers / profiles.
///   3. Detail — header (item name + type | Edit + Delete) above a full-width
///      tab bar (Enabled Models / Discover Models for providers).
struct SettingsView: View {
    @Bindable var providersModel: ProvidersViewModel
    @Bindable var profilesModel: ProfilesViewModel
    @Bindable var mcpServersModel: MCPServersViewModel
    let onBack: () -> Void

    @Environment(AppModel.self) private var app
    @State private var category: SettingsCategory = .providers
    /// Which section of the Appearance pane is selected in the middle
    /// column. Persists across category switches so coming back to
    /// Appearance restores the user's last-viewed section.
    @State private var appearanceSection: AppearanceSection = .theme
    /// Same for Notifications.
    @State private var notificationsSection: NotificationsSection = .generationFinished
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
            // The middle items column only earns its keep for the data
            // categories (Providers / Profiles / Plugins), where it
            // lists the user's rows. App-settings panes have no item
            // list — they render two-pane, detail flush against the
            // categories sidebar.
            if !category.isAppSettings {
                insetWrap(middleColumn)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            }
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
        let topLevel = SettingsCategory.allCases.filter { !$0.isAppSettings }
        let appSettings = SettingsCategory.allCases.filter { $0.isAppSettings }
        return VStack(alignment: .leading, spacing: 2) {
            // Exit affordance lives here now — the app-settings panes
            // render two-pane and no longer carry a middle column's
            // back chevron.
            HStack(spacing: 8) {
                GlassCircleButton(systemImage: "chevron.left", action: onBack, help: "Back to chats")
                Text("Settings")
                    .scaledFont(.headline)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            ForEach(topLevel) { c in
                categoryRow(c)
            }
            // Visual hierarchy: a SETTINGS section header gathers the
            // app-level preference panes (Appearance / Notifications)
            // beneath it, so they read as "configuration of the app
            // itself" distinct from the data categories above.
            settingsSectionHeader
            ForEach(appSettings) { c in
                categoryRow(c, indented: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSectionHeader: some View {
        Text("Settings")
            .scaledFont(.caption2, weight: .semibold)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func categoryRow(_ c: SettingsCategory, indented: Bool = false) -> some View {
        let active = (category == c)
        Button {
            category = c
        } label: {
            Label(c.label, systemImage: c.systemImage)
                .labelStyle(.titleAndIcon)
                .scaledFont(.callout)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .padding(.leading, indented ? 12 : 0)
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
        case .mcpServers:
            MCPServersMiddleColumn(model: mcpServersModel, onBack: onBack)
        default:
            // App-settings categories render two-pane; this column is
            // never mounted for them (see the HSplitView condition).
            EmptyView()
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
        case .mcpServers:
            MCPServersDetail(model: mcpServersModel)
        case .appearance:
            AppearanceSettingsView(section: appearanceSection)
        case .notifications:
            NotificationsSettingsView(section: notificationsSection)
        case .langfuse:
            LangfuseSettingsView(client: app.client)
        case .embedder:
            EmbedderSettingsView(client: app.client)
        case .general:
            GeneralSettingsView()
        case .privacy:
            PrivacySettingsView()
        case .cost:
            CostSettingsView()
        case .speech:
            SpeechSettingsView(client: app.client)
        case .deviceTools:
            DeviceToolsSettingsView()
        }
    }
}



// MARK: - Embedder middle column


// MARK: - Notifications middle column


@MainActor
@ViewBuilder
private func sectionRow<S: Hashable & Identifiable>(
    _ section: S,
    selection: Binding<S>,
    theme: Theme,
    label: String,
    systemImage: String
) -> some View {
    let active = (selection.wrappedValue == section)
    Button {
        selection.wrappedValue = section
    } label: {
        Label(label, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .scaledFont(.callout)
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

// Specialised helpers — sectionRow's generic version doesn't know how
// to pull label+systemImage off a particular enum, so each
// app-settings enum gets a tiny one-line wrapper.

@MainActor
private func sectionRow(
    _ s: AppearanceSection,
    selection: Binding<AppearanceSection>,
    theme: Theme
) -> some View {
    sectionRow(s, selection: selection, theme: theme, label: s.label, systemImage: s.systemImage)
}

@MainActor
private func sectionRow(
    _ s: NotificationsSection,
    selection: Binding<NotificationsSection>,
    theme: Theme
) -> some View {
    sectionRow(s, selection: selection, theme: theme, label: s.label, systemImage: s.systemImage)
}

// MARK: - Appearance middle column


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
                    .scaledFont(.headline)
                    .lineLimit(1)
                Text("\(count) \(countNoun)\(count == 1 ? "" : "s")")
                    .scaledFont(.caption2)
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
                    .scaledFont(size: 11, weight: .semibold)
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
