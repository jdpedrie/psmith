import Foundation
import Observation

/// Mode for the providers detail column. Controls whether we're showing the
/// selected provider, an Add form (creating a new one), an Edit form, a
/// model-discovery list, or the provider-level default-settings tab.
public enum ProvidersDetailMode: Hashable, Sendable {
    case viewing
    case adding
    case editing
    case discovering
    /// Provider-level default CallSettings tab. Read-only in v1 — the
    /// `UserModelProvider` proto / Update RPC don't yet carry the
    /// `default_settings` field, so the form renders disabled with a hint
    /// flagging it as coming-soon.
    case settings
    /// Editing a per-model row — wraps the per-model default settings form
    /// in a full pane (replaces the gear-icon popover). The associated
    /// value is the model id within the currently-selected provider.
    case editingModel(String)
    /// Adding a manually-described model on the currently-selected provider.
    /// Replaces the "+ Add custom model" popover with a full pane that
    /// shares its form definition with `editingModel`.
    case addingManualModel
}

/// Live state of a "Test provider" action. Stored per-provider in
/// `ProvidersViewModel.providerTestStatus`; UI reads it to render the inline
/// Test affordance (button → spinner → result chip).
public enum ProviderTestStatus: Sendable, Equatable {
    case idle
    case testing
    case success(ReeveProviderTestResult)
    case failure(String)
}

/// Composite key for per-model test state — a single provider can have many
/// enabled models, and a model id alone isn't unique across providers.
public struct ModelTestKey: Sendable, Hashable {
    public let providerID: String
    public let modelID: String
    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// Live state of a "Test model" action. Same shape as ProviderTestStatus —
/// the rendering logic in the view layer treats them analogously.
public enum ModelTestStatus: Sendable, Equatable {
    case idle
    case testing
    case success(ReeveModelTestResult)
    case failure(String)
}

/// Provider list + per-provider model orchestration. Drives the providers
/// settings category. Reusable across macOS / iOS.
@Observable
@MainActor
public final class ProvidersViewModel {
    private let client: ReeveClient

    public var providers: [ReeveUserModelProvider] = []
    public var selectedID: String?
    public var enabledModels: [ReeveUserModel] = []
    public var isLoadingProviders = false
    public var isLoadingDetail = false
    public var error: String?

    public var detailMode: ProvidersDetailMode = .viewing
    public var showDeleteConfirm = false
    public var isDeleting = false

    /// Templates fetched lazily on first Add. Cached for the life of the model
    /// so re-entering Add doesn't re-fetch.
    ///
    /// Now reused for the sidebar's "available providers" section — every
    /// preset that doesn't yet have a configured user_model_provider gets
    /// a row there. We trigger loadTemplates() on the initial load() so
    /// the sidebar can render immediately without waiting for the Add
    /// flow to fire it.
    public var templates: [ReeveProviderTemplate] = []
    public var templatesLoaded = false

    /// When non-nil, AddProviderForm skips the template picker and opens
    /// pre-filled for this preset. Set by the sidebar when the user
    /// clicks an unconfigured preset row; cleared when the form
    /// dismisses or the user clicks "Change". A nil value means the
    /// user reached the form via the "+ Add Custom" affordance — they
    /// get the bare custom-driver form, no preset selection.
    public var pendingAddPreset: ReeveProviderTemplate?

    /// Transient per-provider test results — keyed by provider ID. Memory-only;
    /// reset across app launches and overwritten on each re-test.
    public var providerTestStatus: [String: ProviderTestStatus] = [:]

    /// Transient per-model test results — keyed by (providerID, modelID).
    /// Same lifecycle as `providerTestStatus`.
    public var modelTestStatus: [ModelTestKey: ModelTestStatus] = [:]

    public init(client: ReeveClient) { self.client = client }

    public func load() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }
        do {
            providers = try await client.modelProviders.list()
            error = nil
            if selectedID == nil, let first = providers.first {
                await selectProvider(first.id)
            }
        } catch {
            self.error = ReeveError.display(error)
        }
        // Templates power both the Add flow AND the sidebar's
        // "available providers" section. Fetch eagerly on first load
        // so the sidebar isn't waiting on a click. Cached for the
        // lifetime of the view-model.
        if !templatesLoaded {
            await loadTemplates()
        }
    }

    /// Returns the subset of templates that don't have a configured
    /// provider yet. Comparison is by preset_id (for openai-compatible
    /// presets) or by driver type (for native drivers — anthropic,
    /// google). The sidebar shows these as greyed-out rows the user can
    /// click to start the Add flow with the preset preselected.
    public var unconfiguredTemplates: [ReeveProviderTemplate] {
        let configuredPresetIDs = Set(providers.compactMap { $0.presetID })
        let configuredNativeTypes = Set(providers.filter { $0.presetID == nil }.map { $0.type })
        return templates.filter { t in
            if let pid = t.presetID, !pid.isEmpty {
                return !configuredPresetIDs.contains(pid)
            }
            // Native-driver template (anthropic, google) — match by
            // driver_type. Only consider it unconfigured when no
            // existing provider with that driver type AND no preset_id
            // is on file.
            return !configuredNativeTypes.contains(t.driverType)
        }
    }

    /// Sidebar entry-point for clicking an unconfigured preset row.
    /// Opens AddProviderForm pre-filled with the preset's defaults.
    public func startAddingWithPreset(_ template: ReeveProviderTemplate) {
        pendingAddPreset = template
        detailMode = .adding
    }

    /// Sidebar entry-point for the "+ Add Custom" affordance. Opens
    /// AddProviderForm with no preset preselected — the user picks the
    /// driver type and supplies a base URL manually.
    public func startAddingCustom() {
        pendingAddPreset = nil
        detailMode = .adding
    }

    public func selectProvider(_ id: String) async {
        selectedID = id
        detailMode = .viewing
        enabledModels = []
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let (_, models) = try await client.modelProviders.get(id: id)
            enabledModels = models.sorted { $0.displayName < $1.displayName }
            error = nil
        } catch {
            self.error = ReeveError.display(error)
        }
    }

    public func deleteSelected() async {
        guard let id = selectedID else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await client.modelProviders.delete(id: id)
            providers.removeAll { $0.id == id }
            selectedID = nil
            enabledModels = []
            detailMode = .viewing
            if let first = providers.first { await selectProvider(first.id) }
        } catch {
            self.error = ReeveError.display(error)
        }
    }

    public func disableModel(_ modelID: String) async {
        guard let providerID = selectedID else { return }
        do {
            try await client.modelProviders.disableModels(providerID: providerID, modelIDs: [modelID])
            enabledModels.removeAll { $0.modelID == modelID }
        } catch {
            self.error = ReeveError.display(error)
        }
    }

    /// Optimistic local toggle of a user model's `favorite` flag — UI updates
    /// instantly, rolls back on error. Mirrors `ProfilesViewModel.toggleFavorite`.
    /// Server is the source of truth.
    public func toggleModelFavorite(modelID: String) async {
        guard let providerID = selectedID else { return }
        guard let idx = enabledModels.firstIndex(where: { $0.modelID == modelID }) else { return }
        let original = enabledModels[idx]
        let newValue = !original.favorite
        enabledModels[idx] = ReeveUserModel(
            providerID: original.providerID,
            modelID: original.modelID,
            displayName: original.displayName,
            contextWindow: original.contextWindow,
            maxOutputTokens: original.maxOutputTokens,
            pricing: original.pricing,
            knowledgeCutoff: original.knowledgeCutoff,
            modalities: original.modalities,
            capabilities: original.capabilities,
            favorite: newValue,
            defaultSettings: original.defaultSettings
        )
        do {
            _ = try await client.modelProviders.toggleModelFavorite(providerID: providerID, modelID: modelID, favorite: newValue)
        } catch {
            enabledModels[idx] = original
            self.error = ReeveError.display(error)
        }
    }

    public func loadTemplates() async {
        guard !templatesLoaded else { return }
        do {
            templates = try await client.modelProviders.listTemplates()
            templatesLoaded = true
        } catch {
            self.error = ReeveError.display(error)
        }
    }

    public func createProvider(type: String, label: String, config: Data) async throws -> ReeveUserModelProvider {
        let provider = try await client.modelProviders.create(type: type, label: label, config: config)
        providers.append(provider)
        return provider
    }

    public func updateProvider(id: String, label: String, config: Data) async throws {
        let updated = try await client.modelProviders.update(id: id, label: label, config: config)
        if let idx = providers.firstIndex(where: { $0.id == id }) {
            providers[idx] = updated
        }
    }

    /// Partial-update variant: pass `nil` for `config` to leave the
    /// stored credentials blob alone (used by the iOS edit form
    /// which pre-fills `base_url` but doesn't expose the existing
    /// `api_key`; the user explicitly opts in to replacing the key).
    public func updateProviderPartial(id: String, label: String?, config: Data?) async throws {
        let updated = try await client.modelProviders.update(id: id, label: label, config: config)
        if let idx = providers.firstIndex(where: { $0.id == id }) {
            providers[idx] = updated
        }
    }

    /// Replaces the provider-level default CallSettings via UpdateUserModelProvider
    /// (only the `default_settings` field is sent — label/config left alone).
    /// Updates the in-memory provider list on success so subsequent reads reflect
    /// the new value without a round-trip to GET.
    public func updateProviderDefaultSettings(providerID: String, settings: ReeveCallSettings) async throws {
        let updated = try await client.modelProviders.updateProviderDefaultSettings(providerID: providerID, settings: settings)
        if let idx = providers.firstIndex(where: { $0.id == providerID }) {
            providers[idx] = updated
        }
    }

    /// Replaces a single user model's default CallSettings via UpdateUserModel.
    /// Updates the in-memory enabledModels list on success.
    public func updateModelDefaultSettings(providerID: String, modelID: String, settings: ReeveCallSettings) async throws {
        let updated = try await client.modelProviders.updateModel(providerID: providerID, modelID: modelID, settings: settings)
        if let idx = enabledModels.firstIndex(where: { $0.modelID == modelID }) {
            enabledModels[idx] = updated
        }
    }

    /// Full edit of every metadata field on an enabled model row. Every
    /// argument is overwrite-when-present / leave-when-nil. `modalities`
    /// uses the proto's update_modalities flag — pass non-nil to replace.
    @discardableResult
    public func updateModelFull(
        providerID: String,
        modelID: String,
        displayName: String?,
        contextWindow: Int32?,
        clearContextWindow: Bool = false,
        maxOutputTokens: Int32?,
        clearMaxOutputTokens: Bool = false,
        pricing: ReeveModelPricing?,
        modalities: [String]?,
        capabilities: ReeveModelCapabilities?,
        knowledgeCutoff: String?,
        clearKnowledgeCutoff: Bool = false,
        defaultSettings: ReeveCallSettings?
    ) async throws -> ReeveUserModel {
        let updated = try await client.modelProviders.updateModelFull(
            providerID: providerID,
            modelID: modelID,
            displayName: displayName,
            contextWindow: contextWindow,
            clearContextWindow: clearContextWindow,
            maxOutputTokens: maxOutputTokens,
            clearMaxOutputTokens: clearMaxOutputTokens,
            pricing: pricing,
            modalities: modalities,
            capabilities: capabilities,
            knowledgeCutoff: knowledgeCutoff,
            clearKnowledgeCutoff: clearKnowledgeCutoff,
            defaultSettings: defaultSettings
        )
        if let idx = enabledModels.firstIndex(where: { $0.modelID == modelID }) {
            enabledModels[idx] = updated
            enabledModels.sort { $0.displayName < $1.displayName }
        }
        return updated
    }

    public func discoverModels(providerID: String) async throws -> [ReeveDiscoveredModel] {
        try await client.modelProviders.discoverModels(providerID: providerID)
    }

    @discardableResult
    public func enableModels(providerID: String, modelIDs: [String]) async throws -> [ReeveUserModel] {
        let enabled = try await client.modelProviders.enableModels(providerID: providerID, modelIDs: modelIDs)
        let existing = Set(enabledModels.map(\.modelID))
        let fresh = enabled.filter { !existing.contains($0.modelID) }
        enabledModels.append(contentsOf: fresh)
        enabledModels.sort { $0.displayName < $1.displayName }
        return enabled
    }

    /// Adds a manually-described model on the named provider — for models
    /// outside the catalog and outside driver discovery. Inserts the freshly
    /// enabled row into `enabledModels` (sorted) on success.
    @discardableResult
    public func addManualModel(
        providerID: String,
        modelID: String,
        displayName: String,
        contextWindow: Int32?,
        maxOutputTokens: Int32?,
        pricing: ReeveModelPricing?,
        modalities: [String],
        capabilities: ReeveModelCapabilities?,
        knowledgeCutoff: String?,
        defaultSettings: ReeveCallSettings?
    ) async throws -> ReeveUserModel {
        let model = try await client.modelProviders.addManualModel(
            providerID: providerID,
            modelID: modelID,
            displayName: displayName,
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            pricing: pricing,
            modalities: modalities,
            capabilities: capabilities,
            knowledgeCutoff: knowledgeCutoff,
            defaultSettings: defaultSettings
        )
        // Only add when this is the currently-selected provider; otherwise the
        // caller will refresh through selectProvider on its own.
        if selectedID == providerID {
            enabledModels.removeAll { $0.modelID == model.modelID }
            enabledModels.append(model)
            enabledModels.sort { $0.displayName < $1.displayName }
        }
        return model
    }

    // MARK: - Test actions

    /// Triggers a "Test provider" action. Re-callable; the latest result
    /// overwrites any prior result so users can re-test after fixing config.
    /// Transport errors land in `.failure`; per-payload `ok=false` results
    /// land in `.success(result)` with `result.ok == false` so the chip
    /// renders the inline error message rather than the alert banner.
    public func testProvider(_ providerID: String) async {
        providerTestStatus[providerID] = .testing
        do {
            let result = try await client.modelProviders.testProvider(providerID: providerID)
            providerTestStatus[providerID] = .success(result)
        } catch {
            providerTestStatus[providerID] = .failure(ReeveError.display(error))
        }
    }

    /// Triggers a "Test model" action against a specific enabled model.
    /// Same packing convention as `testProvider`.
    public func testModel(providerID: String, modelID: String) async {
        let key = ModelTestKey(providerID: providerID, modelID: modelID)
        modelTestStatus[key] = .testing
        do {
            let result = try await client.modelProviders.testModel(providerID: providerID, modelID: modelID)
            modelTestStatus[key] = .success(result)
        } catch {
            modelTestStatus[key] = .failure(ReeveError.display(error))
        }
    }
}
