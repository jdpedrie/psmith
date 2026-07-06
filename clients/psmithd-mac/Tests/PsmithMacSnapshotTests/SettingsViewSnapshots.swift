import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// Snapshots for the three-column settings shell. The shell hosts the
/// providers + profiles management surfaces — this file covers the
/// outer chrome only (categories sidebar, middle column, detail column);
/// the panes themselves are exercised in detail by
/// `ProvidersViewSnapshots` and `ProfilesViewSnapshots`.
///
/// Sizes: rendered at `default` (the WindowGroup defaultSize) and
/// `minWindow` (1080x520) — the AppKit-enforced floor. minWindow is the
/// case the original column-clipping bug surfaced at and is the whole
/// point of testing the shell.
@MainActor
struct SettingsViewSnapshots {

    // MARK: - Providers category

    /// Empty providers state — center pane shows the "no providers" empty
    /// message and the create button stays enabled in the header.
    @Test
    func providersEmpty() {
        let providers = SnapshotStubs.makeProvidersModel(
            providers: [],
            enabledModels: [],
            selectedID: nil
        )
        let profiles = SnapshotStubs.makeProfilesModel()
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            SettingsView(
                providersModel: providers,
                profilesModel: profiles,
                onBack: {}
            )
        }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    /// Providers populated — full three-column layout with provider list,
    /// selected provider header, tab bar, and enabled models list.
    @Test
    func providersPopulated() {
        let providers = SnapshotStubs.makeProvidersModel()
        let profiles = SnapshotStubs.makeProfilesModel()
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            SettingsView(
                providersModel: providers,
                profilesModel: profiles,
                onBack: {}
            )
        }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    // MARK: - Profiles category

    /// Profiles category with the smoke profile selected — verifies the
    /// shell flips middle + detail columns to the profiles surfaces and
    /// ProfileViewer renders its read-only body inside the detail column.
    @Test
    func profilesCategory() {
        let profiles = SnapshotStubs.makeProfilesModel(
            profiles: [SnapshotFixtures.profile()],
            detailMode: .viewing
        )
        let providers = SnapshotStubs.makeProvidersModel()
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            // Initial category lands on `.providers` — flip to profiles by
            // wrapping in a small view that sets it on appear. Going via the
            // public surface (state inside SettingsView is private) means we
            // wrap the whole shell with an init that sets it.
            SettingsViewWithCategory(
                providersModel: providers,
                profilesModel: profiles,
                category: .profiles
            )
        }
        assertViewSnapshots(view, sizes: defaultSizes)
    }
}

/// Workaround wrapper — `SettingsView` keeps the category as a `@State`
/// internally and defaults to `.providers`. We can't reach into that state
/// from the test target, but we can render the category-specific surfaces
/// directly via the shell's column primitives. This wrapper reproduces the
/// HSplitView layout one-to-one so the snapshot still exercises real
/// production shell code: ProfilesMiddleColumn + ProfilesDetail, hosted in
/// the same column min/max widths the production HSplitView uses.
@MainActor
struct SettingsViewWithCategory: View {
    @Bindable var providersModel: ProvidersViewModel
    @Bindable var profilesModel: ProfilesViewModel
    let category: SettingsCategory

    var body: some View {
        HSplitView {
            categoriesColumn
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
            middleColumn
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            detailColumn
                .frame(minWidth: 540)
        }
        .frame(minWidth: 1040, minHeight: 520)
    }

    private var categoriesColumn: some View {
        List(SettingsCategory.allCases, selection: .constant(Optional(category))) { c in
            Label(c.label, systemImage: c.systemImage)
                .tag(Optional(c))
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch category {
        case .providers:
            ProvidersMiddleColumn(model: providersModel, onBack: {})
        case .profiles:
            ProfilesMiddleColumn(model: profilesModel, onBack: {})
        case .appearance:
            // Appearance column is exercised by AppearanceSettingsView
            // snapshots; the snapshot of the providers/profiles surface
            // doesn't need to render it. Empty placeholder keeps the
            // switch exhaustive.
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch category {
        case .providers:
            ProvidersDetail(model: providersModel)
        case .profiles:
            ProfilesDetail(model: profilesModel)
        case .appearance:
            EmptyView()
        }
    }
}
