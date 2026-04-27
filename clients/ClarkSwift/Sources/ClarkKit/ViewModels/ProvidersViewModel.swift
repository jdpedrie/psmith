import Foundation
import Observation

/// Mode for the providers detail column. Controls whether we're showing the
/// selected provider, an Add form (creating a new one), an Edit form, or a
/// model-discovery list.
public enum ProvidersDetailMode: Equatable, Sendable {
    case viewing
    case adding
    case editing
    case discovering
}

/// Provider list + per-provider model orchestration. Drives the providers
/// settings category. Reusable across macOS / iOS.
@Observable
@MainActor
public final class ProvidersViewModel {
    private let client: ClarkClient

    public var providers: [ClarkUserModelProvider] = []
    public var selectedID: String?
    public var enabledModels: [ClarkUserModel] = []
    public var isLoadingProviders = false
    public var isLoadingDetail = false
    public var error: String?

    public var detailMode: ProvidersDetailMode = .viewing
    public var showDeleteConfirm = false
    public var isDeleting = false

    /// Templates fetched lazily on first Add. Cached for the life of the model
    /// so re-entering Add doesn't re-fetch.
    public var templates: [ClarkProviderTemplate] = []
    public var templatesLoaded = false

    public init(client: ClarkClient) { self.client = client }

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
            self.error = error.localizedDescription
        }
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
            self.error = error.localizedDescription
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
            self.error = error.localizedDescription
        }
    }

    public func disableModel(_ modelID: String) async {
        guard let providerID = selectedID else { return }
        do {
            try await client.modelProviders.disableModels(providerID: providerID, modelIDs: [modelID])
            enabledModels.removeAll { $0.modelID == modelID }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func loadTemplates() async {
        guard !templatesLoaded else { return }
        do {
            templates = try await client.modelProviders.listTemplates()
            templatesLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func createProvider(type: String, label: String, config: Data) async throws -> ClarkUserModelProvider {
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

    public func discoverModels(providerID: String) async throws -> [ClarkDiscoveredModel] {
        try await client.modelProviders.discoverModels(providerID: providerID)
    }

    @discardableResult
    public func enableModels(providerID: String, modelIDs: [String]) async throws -> [ClarkUserModel] {
        let enabled = try await client.modelProviders.enableModels(providerID: providerID, modelIDs: modelIDs)
        let existing = Set(enabledModels.map(\.modelID))
        let fresh = enabled.filter { !existing.contains($0.modelID) }
        enabledModels.append(contentsOf: fresh)
        enabledModels.sort { $0.displayName < $1.displayName }
        return enabled
    }
}
