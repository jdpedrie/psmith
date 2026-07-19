import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// Snapshots for the profiles settings surfaces — the detail column of
/// SettingsView when the profiles category is active. The form sub-views
/// (`ProfileForm`, `ProfileViewer`, `PluginsSection`) are private to
/// `ProfilesView.swift`, so we drive them through `ProfilesDetail` by
/// flipping `model.detailMode`. Same approach as the providers snapshots:
/// production routing, no test-only initializers needed.
///
/// Sizes: `default` + `minColumn` (540pt). The minColumn pass is the one
/// that originally caught ProfileForm's leading-edge clipping and is the
/// reason the test plan was written.
@MainActor
struct ProfilesViewSnapshots {

    // MARK: - Test environment

    /// Wraps `ProfilesDetail` in the standard `PsmithMacEnvironment`. Direct
    /// rendering — no HSplitView — so the form's frame matches the column
    /// size exactly.
    private func profilesDetail(
        model: ProfilesViewModel
    ) -> some View {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        return PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            ProfilesDetail(model: model)
        }
    }

    // MARK: - ProfileViewer (read-only viewer)

    /// Fully-populated profile — all sections render (description, system
    /// message, default model, compression, auto-titling).
    @Test
    func profileViewerPopulated() {
        let chain = SnapshotFixtures.profileChain()
        var rich = chain[1] // Coding profile
        // Replace with a richer variant that has every section non-empty.
        rich = PsmithProfile(
            id: rich.id,
            name: rich.name,
            description: rich.description,
            parentOnly: false,
            favorite: true,
            parentProfileID: rich.parentProfileID,
            systemMessage: "You are an opinionated, code-first engineer who answers in tight, direct prose.",
            defaultUserMessage: "Tell me about the project we're working on.",
            compressionGuide: "Preserve filenames and key invariants verbatim.",
            compressionMode: .replace,
            compressionProviderID: "provider-anthropic",
            compressionModelID: "claude-haiku-4-7",
            defaultSettings: PsmithProfileDefaults(
                defaultProviderID: "provider-anthropic",
                defaultModelID: "claude-opus-4-7"
            ),
            titleProviderID: nil,
            titleModelID: nil,
            titleGuide: "Prefer terse, technical phrasing.",
            titleProviderKind: PsmithTitleProviderKind.appleFoundation,
            createdAt: SnapshotFixtures.referenceDate,
            updatedAt: SnapshotFixtures.referenceDate
        )
        let profiles = [chain[0], rich, chain[2]]
        let model = SnapshotStubs.makeProfilesModel(
            profiles: profiles,
            selectedID: rich.id,
            detailMode: .viewing
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    /// Fully-inherited profile — every section is nil, the viewer renders
    /// only the "inherits everything from …" line.
    @Test
    func profileViewerInheritOnly() {
        let parent = SnapshotFixtures.profile(
            id: "profile-parent",
            name: "Shared Defaults",
            description: "Inheritable settings only.",
            parentOnly: true
        )
        let child = PsmithProfile(
            id: "profile-empty",
            name: "Empty",
            description: "",
            parentOnly: false,
            favorite: false,
            parentProfileID: parent.id,
            systemMessage: nil,
            defaultUserMessage: nil,
            compressionGuide: nil,
            compressionMode: nil,
            compressionProviderID: nil,
            compressionModelID: nil,
            defaultSettings: nil,
            titleProviderID: nil,
            titleModelID: nil,
            titleGuide: nil,
            titleProviderKind: nil,
            createdAt: SnapshotFixtures.referenceDate,
            updatedAt: SnapshotFixtures.referenceDate
        )
        let model = SnapshotStubs.makeProfilesModel(
            profiles: [parent, child],
            selectedID: child.id,
            detailMode: .viewing
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    // MARK: - ProfileForm — adding

    /// ProfileForm in `.adding` mode — every field starts empty, parent
    /// picker shows existing profiles, plugins section is hidden (it only
    /// renders when editing an existing profile because it needs an id).
    /// CRITICAL: minColumn snapshot guards against the leading-edge
    /// clipping bug that motivated the L2 test plan.
    @Test
    func profileFormAdding() {
        let model = SnapshotStubs.makeProfilesModel(
            profiles: SnapshotFixtures.profileChain(),
            selectedID: nil,
            detailMode: .adding
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    // MARK: - ProfileForm — editing existing

    /// ProfileForm in `.editing` mode pre-populated with a chain leaf —
    /// the General tab: basic identity fields + the prompt editors.
    @Test
    func profileFormEditing() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: chain[1].id, // "Coding"
            detailMode: .editing
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    /// Model tab — default model picker + the embedded CallSettingsForm.
    /// CRITICAL: minColumn snapshot — the wide CallSettingsForm pickers
    /// were the original column-clipping regression site.
    @Test
    func profileFormModelTab() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: chain[1].id,
            detailMode: .editing,
            formTab: .model
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    /// Automation tab — compression + auto-titling sections.
    @Test
    func profileFormAutomationTab() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: chain[1].id,
            detailMode: .editing,
            formTab: .automation
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    /// ProfileForm.editing with a profile that has one plugin attached —
    /// PluginsSection renders the row with the plugin's config form.
    /// loaded=true is reached after the .task fires its (network-failing)
    /// load and finally calls seedDraft + sets loaded.
    @Test
    func profileFormEditingWithPlugin() {
        let chain = SnapshotFixtures.profileChain()
        let leaf = chain[1]
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: leaf.id,
            detailMode: .editing,
            profilePlugins: [leaf.id: [SnapshotFixtures.attachedPlugin()]],
            formTab: .plugins
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    /// ProfileForm.editing with no plugins attached — PluginsSection shows
    /// the "No plugins. Inherits from parent profile." empty copy.
    @Test
    func profileFormEditingPluginsEmpty() {
        let chain = SnapshotFixtures.profileChain()
        let leaf = chain[1]
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: leaf.id,
            detailMode: .editing,
            profilePlugins: [leaf.id: []]
        )
        assertViewSnapshots(profilesDetail(model: model), sizes: columnSizes)
    }

    // Skipped: "PluginsSection dirty Save state" — the dirty indicator
    // requires the user to mutate the @State `draft` array (add/remove a
    // plugin) so it differs from `model.profilePlugins[profileID]`. No
    // entry point from the test target, captured by L1 behavior tests.

    // MARK: - ProfilePickerRow

    /// ProfilePickerRow with the chain fixture loaded — multiple cards
    /// scroll horizontally, the parent-chain row renders under each card.
    /// Picks the leaf as the selected profile so the highlight ring is
    /// captured.
    @Test
    func profilePickerRowWithChain() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: chain.last?.id
        )
        let env = SnapshotEnvironment.standard(navMode: .settings)
        @State var selected: String? = chain.last?.id
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            // Plain wrapper — supplies the binding the picker needs.
            ProfilePickerRowSnapshotWrapper(
                model: model,
                selectedID: selected,
                allowParentOnly: true,
                includeNoneOption: false
            )
        }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// ProfilePickerRow in parent-picker mode — `.includeNoneOption = true`
    /// adds the dashed "Standalone" sentinel, `allowParentOnly = true` lets
    /// the parent-only template surface in the row.
    @Test
    func profilePickerRowParentMode() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: nil
        )
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            ProfilePickerRowSnapshotWrapper(
                model: model,
                selectedID: nil,
                allowParentOnly: true,
                includeNoneOption: true
            )
        }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    // MARK: - ProfileCardPicker / ProfileCard scroller

    /// Direct snapshot of the ProfileCard horizontal scroller — multiple
    /// cards with one selected. Mirrors how ProfilePickerRow renders cards
    /// but isolates the card chrome (highlight, parent chain, badges).
    @Test
    func profileCardPickerSelected() {
        let chain = SnapshotFixtures.profileChain()
        let model = SnapshotStubs.makeProfilesModel(
            profiles: chain,
            selectedID: chain[1].id // "Coding" — middle card highlighted
        )
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            ProfilePickerRowSnapshotWrapper(
                model: model,
                selectedID: chain[1].id,
                allowParentOnly: false,
                includeNoneOption: false
            )
        }
        assertViewSnapshots(view, sizes: columnSizes)
    }
}

/// Tiny wrapper that owns the `selectedID: String?` binding ProfilePickerRow
/// requires. Kept alongside the snapshot tests because no production view
/// needs this exact shape — the forms each own their own binding state.
@MainActor
struct ProfilePickerRowSnapshotWrapper: View {
    @Bindable var model: ProfilesViewModel
    @State var selectedID: String?
    let allowParentOnly: Bool
    let includeNoneOption: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfilePickerRow(
                model: model,
                selectedID: $selectedID,
                includeNoneOption: includeNoneOption,
                allowParentOnly: allowParentOnly,
                onOpenSettings: { _ in }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
