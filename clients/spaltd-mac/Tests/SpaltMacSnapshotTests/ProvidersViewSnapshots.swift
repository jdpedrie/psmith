import Testing
import SwiftUI
@testable import SpaltMac
import SpaltKit
import SnapshotHarness

/// Snapshots for the providers settings surfaces — the detail column of
/// SettingsView when the providers category is active. Sub-views
/// (`AddProviderForm`, `EditProviderForm`, `ModelEditForm`,
/// `DiscoverModelsInline`, `ProviderDefaultSettingsTab`) are private to
/// `ProvidersView.swift`, so we reach them by driving
/// `ProvidersDetail` through `model.detailMode`. That's faithful to the
/// production code path — the same routing the live shell uses — and
/// captures each form's initial render state with the same bindings the
/// real view receives.
///
/// Sizes: every form is captured at `default` (1100x720) and `minColumn`
/// (540x600). The minColumn case is the floor enforced by SettingsView's
/// HSplitView third-column `minWidth: 540`. Forms must render cleanly at
/// that width without clipping their leading edge — the
/// ModelEditForm + GeometryReader + ScrollView fix was the regression we
/// originally fell into here.
@MainActor
struct ProvidersViewSnapshots {

    // MARK: - Test environment

    /// Wraps `ProvidersDetail` (the public detail-column surface) in the
    /// same environments SettingsView injects. Direct rendering — no
    /// HSplitView — so the form's frame is the exact column size, isolating
    /// any clipping bug to the form itself.
    private func providersDetail(
        model: ProvidersViewModel
    ) -> some View {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        return SpaltMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            ProvidersDetail(model: model)
        }
    }

    // MARK: - Detail viewing (header + tabs + enabled models)

    /// Default `.viewing` mode — provider header, segmented tab bar,
    /// enabled-models list with badges.
    @Test
    func providersDetailViewing() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .viewing
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    /// Same `.viewing` mode but for an OpenAI-compatible provider — driver
    /// extension on the model meta strip differs (no thinking icon on the
    /// llama row).
    @Test
    func providersDetailViewingOpenAICompatible() {
        let model = SnapshotStubs.makeProvidersModel(
            selectedID: "provider-groq",
            detailMode: .viewing
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // MARK: - Add provider form

    /// AddProviderForm in template-list state — selection nil, templates
    /// loaded, scrollable grid + Custom tile pinned at top.
    @Test
    func addProviderTemplateList() {
        let model = SnapshotStubs.makeProvidersModel(
            providers: [],
            enabledModels: [],
            selectedID: nil,
            detailMode: .adding
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    /// AddProviderForm with templates still loading — verifies the spinner
    /// state below the Custom tile.
    @Test
    func addProviderTemplateLoading() {
        let model = SnapshotStubs.makeProvidersModel(
            providers: [],
            enabledModels: [],
            selectedID: nil,
            detailMode: .adding,
            templates: [],
            templatesLoaded: false
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // Skipped: "AddProviderForm template selected" + "AddProviderForm
    // custom" require the form's private `selection` @State to be set,
    // which only user interaction can drive. The form exposes no
    // initializer for pre-set selection. Captured by L1 behavior tests
    // instead.

    // MARK: - Edit provider form

    /// EditProviderForm pre-populated with an Anthropic provider — label
    /// field seeded, no base-URL row (driver type is anthropic, not
    /// openai-compatible).
    @Test
    func editProviderAnthropic() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .editing
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    /// EditProviderForm for an OpenAI-compatible provider — adds the Base
    /// URL and Catalog rows. Catches column-clipping in the wider variant.
    @Test
    func editProviderOpenAICompatible() {
        let model = SnapshotStubs.makeProvidersModel(
            selectedID: "provider-groq",
            detailMode: .editing
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // MARK: - Provider default-settings tab

    /// `.settings` tab on the provider detail pane, draft seeded from the
    /// provider's defaultSettings (nil → empty CallSettingsForm rendered
    /// with all "(inherit)" placeholders).
    @Test
    func providerDefaultSettingsEmpty() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .settings
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    /// `.settings` tab with the provider carrying a populated
    /// defaultSettings — verifies the CallSettingsForm shows actual values
    /// rather than "(inherit)" placeholders.
    @Test
    func providerDefaultSettingsPopulated() {
        let provider = SpaltUserModelProvider(
            id: "provider-anthropic",
            type: "anthropic",
            label: "Anthropic",
            createdAt: SnapshotFixtures.referenceDate,
            updatedAt: SnapshotFixtures.referenceDate,
            defaultSettings: SnapshotFixtures.populatedAnthropicCallSettings()
        )
        var providers = SnapshotFixtures.providers()
        providers[0] = provider
        let model = SnapshotStubs.makeProvidersModel(
            providers: providers,
            detailMode: .settings
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // MARK: - Discover models

    /// `.discovering` tab — DiscoverModelsInline initial state. The view's
    /// .task fires `model.discoverModels(...)` against the null host, which
    /// errors immediately; isLoading flips back to false and the list shows
    /// the "No models found" empty state. Documents that path; we accept
    /// the loading/empty state as the captured snapshot since populating
    /// `discovered` directly would require reaching the form's @State.
    @Test
    func discoverModelsLoading() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .discovering
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // Skipped: "DiscoverModelsInline with search" + "+ Add custom model"
    // popover — search text is @State inside the form (no entry point);
    // popovers don't render in offscreen NSHostingView captures. Both
    // covered by L1 behavior tests.

    // MARK: - Add custom model (ModelEditForm — adding mode)

    /// `.addingManualModel` — ModelEditForm with all fields blank /
    /// placeholders rendered. CRITICAL: minColumn snapshot exists to catch
    /// the leading-edge clipping bug that originally motivated this whole
    /// L2 testing initiative.
    @Test
    func modelEditAdding() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .addingManualModel
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // MARK: - Edit model (ModelEditForm — editing mode)

    /// `.editingModel(modelID)` for an existing model — the form is
    /// pre-populated with all the model's fields. The same column-clipping
    /// concern applies; minColumn is in the size sweep.
    @Test
    func modelEditEditing() {
        let model = SnapshotStubs.makeProvidersModel(
            detailMode: .editingModel("claude-opus-4-7")
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    /// Editing a Google model — shows the google driver's CallSettings
    /// extension block (safety settings, response mime type, etc.).
    @Test
    func modelEditEditingGoogle() {
        let model = SnapshotStubs.makeProvidersModel(
            selectedID: "provider-google",
            detailMode: .editingModel("gemini-2.5-pro")
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }

    // MARK: - Models list with badges

    /// Default viewing mode but with a Google provider selected — the
    /// gemini-2.5-pro row shows the largest variety of capability badges
    /// (vision + thinking + tools + cache + multi-modality icons), tightly
    /// packed. Catches regressions in ModelMetaStrip.
    @Test
    func modelsListGoogleBadges() {
        let model = SnapshotStubs.makeProvidersModel(
            selectedID: "provider-google",
            detailMode: .viewing
        )
        assertViewSnapshots(providersDetail(model: model), sizes: columnSizes)
    }
}

// MARK: - SnapshotFixtures helper specific to provider default settings

extension SnapshotFixtures {
    /// CallSettings populated with the four most common knobs the user
    /// would set as a provider-level baseline. Used by the populated
    /// ProviderDefaultSettings snapshot.
    public static func populatedAnthropicCallSettings() -> SpaltCallSettings {
        var s = SpaltCallSettings()
        s.maxOutputTokens = 4_096
        s.temperature = 0.7
        s.topP = 0.95
        return s
    }
}
