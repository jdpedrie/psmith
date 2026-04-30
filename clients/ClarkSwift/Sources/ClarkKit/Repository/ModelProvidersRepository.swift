import Foundation
import Connect

public final class ModelProvidersRepository: Sendable {
    private let client: Clark_V1_ModelProvidersServiceClientInterface

    public init(client: Clark_V1_ModelProvidersServiceClientInterface) {
        self.client = client
    }

    public func listProviderTypes() async throws -> [ClarkProviderType] {
        let resp = await client.listProviderTypes(request: .init(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list provider types") }
        return msg.types.map(ClarkProviderType.init(from:))
    }

    public func listTemplates() async throws -> [ClarkProviderTemplate] {
        let resp = await client.listProviderTemplates(request: .init(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list provider templates") }
        return msg.templates.map(ClarkProviderTemplate.init(from:))
    }

    public func list() async throws -> [ClarkUserModelProvider] {
        let resp = await client.listUserModelProviders(request: .init(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list providers") }
        return msg.providers.map(ClarkUserModelProvider.init(from:))
    }

    public func get(id: String) async throws -> (ClarkUserModelProvider, [ClarkUserModel]) {
        var req = Clark_V1_GetUserModelProviderRequest()
        req.id = id
        let resp = await client.getUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("get provider") }
        return (ClarkUserModelProvider(from: msg.provider), msg.enabledModels.map(ClarkUserModel.init(from:)))
    }

    public func create(type: String, label: String, config: Data) async throws -> ClarkUserModelProvider {
        var req = Clark_V1_CreateUserModelProviderRequest()
        req.type   = type
        req.label  = label
        req.config = config
        let resp = await client.createUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("create provider") }
        return ClarkUserModelProvider(from: msg.provider)
    }

    public func update(id: String, label: String? = nil, config: Data? = nil) async throws -> ClarkUserModelProvider {
        var req = Clark_V1_UpdateUserModelProviderRequest()
        req.id = id
        if let l = label  { req.label  = l }
        if let c = config { req.config = c }
        let resp = await client.updateUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update provider") }
        return ClarkUserModelProvider(from: msg.provider)
    }

    public func delete(id: String) async throws {
        var req = Clark_V1_DeleteUserModelProviderRequest()
        req.id = id
        let resp = await client.deleteUserModelProvider(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ClarkError.from(err) }
    }

    public func discoverModels(providerID: String) async throws -> [ClarkDiscoveredModel] {
        var req = Clark_V1_DiscoverModelsRequest()
        req.userModelProviderID = providerID
        let resp = await client.discoverModels(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("discover models") }
        return msg.models.map(ClarkDiscoveredModel.init(from:))
    }

    public func enableModels(providerID: String, modelIDs: [String]) async throws -> [ClarkUserModel] {
        var req = Clark_V1_EnableModelsRequest()
        req.userModelProviderID = providerID
        req.modelIds = modelIDs
        let resp = await client.enableModels(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("enable models") }
        return msg.enabled.map(ClarkUserModel.init(from:))
    }

    public func disableModels(providerID: String, modelIDs: [String]) async throws {
        var req = Clark_V1_DisableModelsRequest()
        req.userModelProviderID = providerID
        req.modelIds = modelIDs
        let resp = await client.disableModels(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ClarkError.from(err) }
    }

    public func listModels(providerID: String) async throws -> [ClarkUserModel] {
        var req = Clark_V1_ListUserModelsRequest()
        req.userModelProviderID = providerID
        let resp = await client.listUserModels(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list models") }
        return msg.models.map(ClarkUserModel.init(from:))
    }

    public func toggleModelFavorite(providerID: String, modelID: String, favorite: Bool) async throws -> ClarkUserModel {
        var req = Clark_V1_ToggleUserModelFavoriteRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.favorite = favorite
        let resp = await client.toggleUserModelFavorite(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("toggle favorite") }
        return ClarkUserModel(from: msg.model)
    }

    /// Replace the provider-level default CallSettings (bottom layer of the
    /// resolution chain). Sparse — empty fields on `settings` are stored as
    /// "unset," letting upper layers contribute. Pass `ClarkCallSettings()` to
    /// effectively clear the column.
    public func updateProviderDefaultSettings(providerID: String, settings: ClarkCallSettings) async throws -> ClarkUserModelProvider {
        var req = Clark_V1_UpdateUserModelProviderRequest()
        req.id = providerID
        req.defaultSettings = settings.proto
        let resp = await client.updateUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update provider default_settings") }
        return ClarkUserModelProvider(from: msg.provider)
    }

    /// Replace the per-model default CallSettings. Same sparse semantics as
    /// `updateProviderDefaultSettings`. The model row must already be enabled
    /// on the provider — otherwise the server returns NotFound.
    public func updateModel(providerID: String, modelID: String, settings: ClarkCallSettings) async throws -> ClarkUserModel {
        var req = Clark_V1_UpdateUserModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.defaultSettings = settings.proto
        let resp = await client.updateUserModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update model") }
        return ClarkUserModel(from: msg.userModel)
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
        pricing: ClarkModelPricing?,
        modalities: [String]?,
        capabilities: ClarkModelCapabilities?,
        knowledgeCutoff: String?,
        clearKnowledgeCutoff: Bool = false,
        defaultSettings: ClarkCallSettings?
    ) async throws -> ClarkUserModel {
        var req = Clark_V1_UpdateUserModelRequest()
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
            var pr = Clark_V1_ModelPricing()
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
            var cap = Clark_V1_ModelCapabilities()
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
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update model") }
        return ClarkUserModel(from: msg.userModel)
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
        pricing: ClarkModelPricing?,
        modalities: [String],
        capabilities: ClarkModelCapabilities?,
        knowledgeCutoff: String?,
        defaultSettings: ClarkCallSettings?
    ) async throws -> ClarkUserModel {
        var req = Clark_V1_AddManualModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        req.displayName = displayName
        if let cw = contextWindow { req.contextWindow = cw }
        if let mo = maxOutputTokens { req.maxOutputTokens = mo }
        if let p = pricing {
            var pr = Clark_V1_ModelPricing()
            if let v = p.inputPerMillion      { pr.inputPerMillionTokens      = v }
            if let v = p.outputPerMillion     { pr.outputPerMillionTokens     = v }
            if let v = p.cacheReadPerMillion  { pr.cacheReadPerMillionTokens  = v }
            if let v = p.cacheWritePerMillion { pr.cacheWritePerMillionTokens = v }
            req.pricing = pr
        }
        req.modalities = modalities
        if let c = capabilities {
            var cap = Clark_V1_ModelCapabilities()
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
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("add manual model") }
        return ClarkUserModel(from: msg.userModel)
    }

    /// Verifies a provider's auth + reachability. Server returns ok=false in
    /// the response payload (not as an RPC error) for normal "your key is
    /// wrong" failures — we surface those inline. Connection-level errors
    /// (couldn't reach clarkd at all) still throw.
    public func testProvider(providerID: String) async throws -> ClarkProviderTestResult {
        var req = Clark_V1_TestUserModelProviderRequest()
        req.userModelProviderID = providerID
        let resp = await client.testUserModelProvider(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("test provider") }
        return ClarkProviderTestResult(from: msg)
    }

    /// Sends a tiny prompt to the named model. Same packing convention as
    /// testProvider: ok=false in the body for "your auth was good but the
    /// model errored", thrown errors only for transport-level issues.
    public func testModel(providerID: String, modelID: String) async throws -> ClarkModelTestResult {
        var req = Clark_V1_TestUserModelRequest()
        req.userModelProviderID = providerID
        req.modelID = modelID
        let resp = await client.testUserModel(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("test model") }
        return ClarkModelTestResult(from: msg)
    }
}
