import Foundation
import Connect

public final class ModelProvidersRepository: Sendable {
    private let client: Reeve_V1_ModelProvidersServiceClientInterface
    private let cache: ReeveCache?

    public init(
        client: Reeve_V1_ModelProvidersServiceClientInterface,
        cache: ReeveCache? = nil
    ) {
        self.client = client
        self.cache = cache
    }

    public func listProviderTypes() async throws -> [ReeveProviderType] {
        let resp = await client.listProviderTypes(request: .init(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("list provider types") }
        return msg.types.map(ReeveProviderType.init(from:))
    }

    public func listTemplates() async throws -> [ReeveProviderTemplate] {
        let resp = await client.listProviderTemplates(request: .init(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("list provider templates") }
        return msg.templates.map(ReeveProviderTemplate.init(from:))
    }

    public func list() async throws -> [ReeveUserModelProvider] {
        let resp = await client.listUserModelProviders(request: .init(), headers: [:])
        if let msg = resp.message {
            let items = msg.providers.map(ReeveUserModelProvider.init(from:))
            if let cache {
                try? await cache.set(items, kind: CacheKind.providers, id: "all", capBytes: CachePreferences.capBytes)
            }
            return items
        }
        if let cache,
           let cached: [ReeveUserModelProvider] = await cache.get([ReeveUserModelProvider].self, kind: CacheKind.providers, id: "all") {
            return cached
        }
        throw resp.error.map(ReeveError.from) ?? .missingPayload("list providers")
    }

    public func get(id: String) async throws -> (ReeveUserModelProvider, [ReeveUserModel]) {
        var req = Reeve_V1_GetUserModelProviderRequest()
        req.id = id
        let resp = await client.getUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("get provider") }
        return (ReeveUserModelProvider(from: msg.provider), msg.enabledModels.map(ReeveUserModel.init(from:)))
    }

    public func create(type: String, label: String, config: Data) async throws -> ReeveUserModelProvider {
        var req = Reeve_V1_CreateUserModelProviderRequest()
        req.type   = type
        req.label  = label
        req.config = config
        let resp = await client.createUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("create provider") }
        return ReeveUserModelProvider(from: msg.provider)
    }

    public func update(id: String, label: String? = nil, config: Data? = nil) async throws -> ReeveUserModelProvider {
        var req = Reeve_V1_UpdateUserModelProviderRequest()
        req.id = id
        if let l = label  { req.label  = l }
        if let c = config { req.config = c }
        let resp = await client.updateUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update provider") }
        return ReeveUserModelProvider(from: msg.provider)
    }

    public func delete(id: String) async throws {
        var req = Reeve_V1_DeleteUserModelProviderRequest()
        req.id = id
        let resp = await client.deleteUserModelProvider(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    public func discoverModels(providerID: String) async throws -> [ReeveDiscoveredModel] {
        var req = Reeve_V1_DiscoverModelsRequest()
        req.userModelProviderID = providerID
        let resp = await client.discoverModels(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("discover models") }
        return msg.models.map(ReeveDiscoveredModel.init(from:))
    }

    public func enableModels(providerID: String, modelIDs: [String]) async throws -> [ReeveUserModel] {
        var req = Reeve_V1_EnableModelsRequest()
        req.userModelProviderID = providerID
        req.modelIds = modelIDs
        let resp = await client.enableModels(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("enable models") }
        return msg.enabled.map(ReeveUserModel.init(from:))
    }

    public func disableModels(providerID: String, modelIDs: [String]) async throws {
        var req = Reeve_V1_DisableModelsRequest()
        req.userModelProviderID = providerID
        req.modelIds = modelIDs
        let resp = await client.disableModels(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    public func listModels(providerID: String) async throws -> [ReeveUserModel] {
        var req = Reeve_V1_ListUserModelsRequest()
        req.userModelProviderID = providerID
        let resp = await client.listUserModels(request: req, headers: [:])
        if let msg = resp.message {
            let items = msg.models.map(ReeveUserModel.init(from:))
            if let cache {
                try? await cache.set(items, kind: CacheKind.availableModels, id: providerID, capBytes: CachePreferences.capBytes)
            }
            return items
        }
        if let cache,
           let cached: [ReeveUserModel] = await cache.get([ReeveUserModel].self, kind: CacheKind.availableModels, id: providerID) {
            return cached
        }
        throw resp.error.map(ReeveError.from) ?? .missingPayload("list models")
    }

    public func toggleModelFavorite(providerID: String, modelID: String, favorite: Bool) async throws -> ReeveUserModel {
        var req = Reeve_V1_ToggleUserModelFavoriteRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.favorite = favorite
        let resp = await client.toggleUserModelFavorite(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("toggle favorite") }
        return ReeveUserModel(from: msg.model)
    }

    /// Replace the provider-level default CallSettings (bottom layer of the
    /// resolution chain). Sparse — empty fields on `settings` are stored as
    /// "unset," letting upper layers contribute. Pass `ReeveCallSettings()` to
    /// effectively clear the column.
    public func updateProviderDefaultSettings(providerID: String, settings: ReeveCallSettings) async throws -> ReeveUserModelProvider {
        var req = Reeve_V1_UpdateUserModelProviderRequest()
        req.id = providerID
        req.defaultSettings = settings.proto
        let resp = await client.updateUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update provider default_settings") }
        return ReeveUserModelProvider(from: msg.provider)
    }

    /// Replace the per-model default CallSettings. Same sparse semantics as
    /// `updateProviderDefaultSettings`. The model row must already be enabled
    /// on the provider — otherwise the server returns NotFound.
    public func updateModel(providerID: String, modelID: String, settings: ReeveCallSettings) async throws -> ReeveUserModel {
        var req = Reeve_V1_UpdateUserModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.defaultSettings = settings.proto
        let resp = await client.updateUserModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update model") }
        return ReeveUserModel(from: msg.userModel)
    }

    /// Full edit: every field present overrides, every nil leaves the column
    /// alone. `modelID` is the row key and is never updatable. `modalities`
    /// honors the proto's `update_modalities` flag — pass non-nil to replace
    /// (empty array clears), nil to leave unchanged.
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
        var req = Reeve_V1_UpdateUserModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        if let dn = displayName { req.displayName = dn }
        // Server contract: an UNSET optional field means "leave the column
        // alone." To clear a column to NULL we set the explicit clear flag.
        // (Earlier `req.clearFoo()` calls UN-set the field, which the server
        // correctly read as "no change" — silently no-op on user "clear"
        // intent.)
        if let cw = contextWindow {
            req.contextWindow = cw
        } else if clearContextWindow {
            req.clearContextWindow_p = true
        }
        if let mo = maxOutputTokens {
            req.maxOutputTokens = mo
        } else if clearMaxOutputTokens {
            req.clearMaxOutputTokens_p = true
        }
        if let p = pricing {
            var pr = Reeve_V1_ModelPricing()
            if let v = p.inputPerMillion      { pr.inputPerMillionTokens      = v }
            if let v = p.outputPerMillion     { pr.outputPerMillionTokens     = v }
            if let v = p.cacheReadPerMillion  { pr.cacheReadPerMillionTokens  = v }
            if let v = p.cacheWritePerMillion { pr.cacheWritePerMillionTokens = v }
            req.pricing = pr
        }
        if let m = modalities {
            req.updateModalities = true
            req.modalities = m
        }
        if let c = capabilities {
            var cap = Reeve_V1_ModelCapabilities()
            cap.streaming     = c.streaming
            cap.thinking      = c.thinking
            cap.toolUse       = c.toolUse
            cap.vision        = c.vision
            cap.promptCaching = c.promptCaching
            req.capabilities = cap
        }
        if let kc = knowledgeCutoff {
            req.knowledgeCutoff = kc
        } else if clearKnowledgeCutoff {
            req.clearKnowledgeCutoff_p = true
        }
        if let s = defaultSettings { req.defaultSettings = s.proto }
        let resp = await client.updateUserModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update model") }
        return ReeveUserModel(from: msg.userModel)
    }

    /// Add a manually-described model to a provider — the equivalent of
    /// EnableModels but for models that aren't in the catalog and aren't
    /// surfaced by driver discovery (private fine-tunes, custom endpoints
    /// serving non-listed models, renamed-but-real models).
    ///
    /// `metadata_source` on the resulting row is `manual`. The server rejects
    /// duplicates with AlreadyExists; pre-flight via `listModels` if the UI
    /// wants to differentiate "add" vs "edit".
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
        var req = Reeve_V1_AddManualModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.displayName = displayName
        if let cw = contextWindow { req.contextWindow = cw }
        if let mo = maxOutputTokens { req.maxOutputTokens = mo }
        if let p = pricing {
            var pr = Reeve_V1_ModelPricing()
            if let v = p.inputPerMillion      { pr.inputPerMillionTokens      = v }
            if let v = p.outputPerMillion     { pr.outputPerMillionTokens     = v }
            if let v = p.cacheReadPerMillion  { pr.cacheReadPerMillionTokens  = v }
            if let v = p.cacheWritePerMillion { pr.cacheWritePerMillionTokens = v }
            req.pricing = pr
        }
        req.modalities = modalities
        if let c = capabilities {
            var cap = Reeve_V1_ModelCapabilities()
            cap.streaming     = c.streaming
            cap.thinking      = c.thinking
            cap.toolUse       = c.toolUse
            cap.vision        = c.vision
            cap.promptCaching = c.promptCaching
            req.capabilities = cap
        }
        if let kc = knowledgeCutoff, !kc.isEmpty { req.knowledgeCutoff = kc }
        if let ds = defaultSettings { req.defaultSettings = ds.proto }

        let resp = await client.addManualModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("add manual model") }
        return ReeveUserModel(from: msg.userModel)
    }

    /// Verifies a provider's auth + reachability. Server returns ok=false in
    /// the response payload (not as an RPC error) for normal "your key is
    /// wrong" failures — we surface those inline. Connection-level errors
    /// (couldn't reach reeved at all) still throw.
    public func testProvider(providerID: String) async throws -> ReeveProviderTestResult {
        var req = Reeve_V1_TestUserModelProviderRequest()
        req.userModelProviderID = providerID
        let resp = await client.testUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("test provider") }
        return ReeveProviderTestResult(from: msg)
    }

    /// Sends a tiny prompt to the named model. Same packing convention as
    /// testProvider: ok=false in the body for "your auth was good but the
    /// model errored", thrown errors only for transport-level issues.
    public func testModel(providerID: String, modelID: String) async throws -> ReeveModelTestResult {
        var req = Reeve_V1_TestUserModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        let resp = await client.testUserModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("test model") }
        return ReeveModelTestResult(from: msg)
    }

    /// Per-provider running cost totals for the Cost settings screen.
    /// Returns (rows, grand total). Server-computed grand total sidesteps
    /// floating-point reconciliation across clients. The optional
    /// (since, until) window is half-open: events at `since` are
    /// included; events at `until` are excluded — so consecutive
    /// non-overlapping windows compose without double-counting.
    public func listProviderCosts(
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> (providers: [ReeveProviderCost], grandTotal: Double) {
        var req = Reeve_V1_ListProviderCostsRequest()
        if let since {
            req.since = .init(date: since)
        }
        if let until {
            req.until = .init(date: until)
        }
        let resp = await client.listProviderCosts(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("list provider costs") }
        return (msg.providers.map(ReeveProviderCost.init(from:)), msg.grandTotalUsd)
    }
}

/// One row in the per-provider cost rollup. `eventCount` doubles as a
/// "have we sent through this provider yet?" signal — zero means the row
/// is included for UI completeness, not because anything was billed.
public struct ReeveProviderCost: Sendable, Hashable, Identifiable, Codable {
    public let providerID: String
    public let providerLabel: String
    public let providerType: String
    public let totalCostUsd: Double
    public let eventCount: Int64

    public var id: String { providerID }

    public init(
        providerID: String,
        providerLabel: String,
        providerType: String,
        totalCostUsd: Double,
        eventCount: Int64
    ) {
        self.providerID = providerID
        self.providerLabel = providerLabel
        self.providerType = providerType
        self.totalCostUsd = totalCostUsd
        self.eventCount = eventCount
    }

    init(from p: Reeve_V1_ProviderCost) {
        self.init(
            providerID: p.providerID,
            providerLabel: p.providerLabel,
            providerType: p.providerType,
            totalCostUsd: p.totalCostUsd,
            eventCount: p.eventCount
        )
    }
}
