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
}
