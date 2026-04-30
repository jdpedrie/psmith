import Foundation
import Connect

public final class ProfilesRepository: Sendable {
    private let client: Clark_V1_ProfilesServiceClientInterface

    public init(client: Clark_V1_ProfilesServiceClientInterface) {
        self.client = client
    }

    public func list() async throws -> [ClarkProfile] {
        let resp = await client.listProfiles(request: Clark_V1_ListProfilesRequest(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list profiles") }
        return msg.profiles.map(ClarkProfile.init(from:))
    }

    public func get(id: String, resolve: Bool = false) async throws -> (ClarkProfile, ClarkProfile?) {
        var req = Clark_V1_GetProfileRequest()
        req.id = id
        req.resolve = resolve
        let resp = await client.getProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("get profile") }
        let profile = ClarkProfile(from: msg.profile)
        let resolved = msg.hasResolved ? ClarkProfile(from: msg.resolved) : nil
        return (profile, resolved)
    }

    public func create(_ patch: ClarkProfilePatch) async throws -> ClarkProfile {
        var req = Clark_V1_CreateProfileRequest()
        req.name = patch.name ?? ""
        if let v = patch.parentProfileID       { req.parentProfileID = v }
        if let v = patch.systemMessage         { req.systemMessage = v }
        if let v = patch.defaultUserMessage    { req.defaultUserMessage = v }
        if let v = patch.compressionGuide      { req.compressionGuide = v }
        if let v = patch.compressionMode       { req.compressionMode = pbCompressionMode(v) }
        if let v = patch.compressionProviderID { req.compressionProviderID = v }
        if let v = patch.compressionModelID    { req.compressionModelID = v }
        if let v = patch.titleProviderID       { req.titleProviderID = v }
        if let v = patch.titleModelID          { req.titleModelID = v }
        if let v = patch.titleGuide            { req.titleGuide = v }
        if let v = patch.titleProviderKind     { req.titleProviderKind = v }
        if let d = patch.defaultSettings       { req.defaultSettings = pbDefaults(d) }
        if let v = patch.description           { req.description_p = v }
        if let v = patch.parentOnly            { req.parentOnly = v }
        if let v = patch.favorite              { req.favorite = v }
        let resp = await client.createProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("create profile") }
        return ClarkProfile(from: msg.profile)
    }

    /// `clearFields` lists protobuf field names whose value should be reset to inherit from the parent.
    /// Valid: `system_message`, `default_user_message`, `compression_guide`, `compression_mode`,
    /// `compression_provider_id`, `compression_model_id`, `default_settings`, `title_provider_id`,
    /// `title_model_id`, `title_guide`, `title_provider_kind`, `parent_profile_id`.
    public func update(id: String, patch: ClarkProfilePatch, clearFields: [String] = []) async throws -> ClarkProfile {
        var req = Clark_V1_UpdateProfileRequest()
        req.id = id
        if let v = patch.name                  { req.name = v }
        if let v = patch.systemMessage         { req.systemMessage = v }
        if let v = patch.defaultUserMessage    { req.defaultUserMessage = v }
        if let v = patch.compressionGuide      { req.compressionGuide = v }
        if let v = patch.compressionMode       { req.compressionMode = pbCompressionMode(v) }
        if let v = patch.compressionProviderID { req.compressionProviderID = v }
        if let v = patch.compressionModelID    { req.compressionModelID = v }
        if let v = patch.titleProviderID       { req.titleProviderID = v }
        if let v = patch.titleModelID          { req.titleModelID = v }
        if let v = patch.titleGuide            { req.titleGuide = v }
        if let v = patch.titleProviderKind     { req.titleProviderKind = v }
        if let d = patch.defaultSettings       { req.defaultSettings = pbDefaults(d) }
        if let v = patch.description           { req.description_p = v }
        if let v = patch.parentOnly            { req.parentOnly = v }
        if let v = patch.favorite              { req.favorite = v }
        req.clearFields_p = clearFields
        let resp = await client.updateProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update profile") }
        return ClarkProfile(from: msg.profile)
    }

    public func delete(id: String) async throws {
        var req = Clark_V1_DeleteProfileRequest()
        req.id = id
        let resp = await client.deleteProfile(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ClarkError.from(err) }
    }

    // MARK: - Plugins

    public func listPluginTypes() async throws -> [ClarkPluginType] {
        let resp = await client.listPluginTypes(request: Clark_V1_ListPluginTypesRequest(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list plugin types") }
        return msg.pluginTypes.map(ClarkPluginType.init(from:))
    }

    public func getProfilePlugins(profileID: String) async throws -> [ClarkProfilePlugin] {
        var req = Clark_V1_GetProfilePluginsRequest()
        req.profileID = profileID
        let resp = await client.getProfilePlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("get profile plugins") }
        return msg.plugins.map(ClarkProfilePlugin.init(from:))
    }

    public func setProfilePlugins(profileID: String, plugins: [ClarkProfilePlugin]) async throws -> [ClarkProfilePlugin] {
        var req = Clark_V1_SetProfilePluginsRequest()
        req.profileID = profileID
        req.plugins = plugins.map { $0.proto }
        let resp = await client.setProfilePlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("set profile plugins") }
        return msg.plugins.map(ClarkProfilePlugin.init(from:))
    }
}

/// Optional-each-field patch shape for create/update. `nil` = don't set.
/// To clear a field on update, pass its proto name in `clearFields`.
public struct ClarkProfilePatch: Sendable {
    public var name: String?
    public var parentProfileID: String?
    public var systemMessage: String?
    public var defaultUserMessage: String?
    public var compressionGuide: String?
    public var compressionMode: ClarkCompressionMode?
    public var compressionProviderID: String?
    public var compressionModelID: String?
    public var defaultSettings: ClarkProfileDefaults?
    public var titleProviderID: String?
    public var titleModelID: String?
    public var titleGuide: String?
    /// Sentinel for non-server title generation (e.g.
    /// `ClarkTitleProviderKind.appleFoundation`). Pass `clearFields:
    /// ["title_provider_kind"]` to revert to default cloud-titled behavior.
    public var titleProviderKind: String?
    public var description: String?
    public var parentOnly: Bool?
    public var favorite: Bool?

    public init(
        name: String? = nil,
        parentProfileID: String? = nil,
        systemMessage: String? = nil,
        defaultUserMessage: String? = nil,
        compressionGuide: String? = nil,
        compressionMode: ClarkCompressionMode? = nil,
        compressionProviderID: String? = nil,
        compressionModelID: String? = nil,
        defaultSettings: ClarkProfileDefaults? = nil,
        titleProviderID: String? = nil,
        titleModelID: String? = nil,
        titleGuide: String? = nil,
        titleProviderKind: String? = nil,
        description: String? = nil,
        parentOnly: Bool? = nil,
        favorite: Bool? = nil
    ) {
        self.name = name
        self.parentProfileID = parentProfileID
        self.systemMessage = systemMessage
        self.defaultUserMessage = defaultUserMessage
        self.compressionGuide = compressionGuide
        self.compressionMode = compressionMode
        self.compressionProviderID = compressionProviderID
        self.compressionModelID = compressionModelID
        self.defaultSettings = defaultSettings
        self.titleProviderID = titleProviderID
        self.titleModelID = titleModelID
        self.titleGuide = titleGuide
        self.titleProviderKind = titleProviderKind
        self.description = description
        self.parentOnly = parentOnly
        self.favorite = favorite
    }
}

private func pbCompressionMode(_ m: ClarkCompressionMode) -> Clark_V1_CompressionMode {
    switch m {
    case .replace:     return .replace
    case .append:      return .append
    case .unspecified: return .unspecified
    }
}

private func pbDefaults(_ d: ClarkProfileDefaults) -> Clark_V1_ProfileDefaults {
    var pd = Clark_V1_ProfileDefaults()
    if let v = d.defaultProviderID         { pd.defaultProviderID = v }
    if let v = d.defaultModelID            { pd.defaultModelID = v }
    if let v = d.includeThinkingInHistory  { pd.includeThinkingInHistory = v }
    if let cs = d.callSettings, !cs.isEmpty { pd.callSettings = cs.proto }
    return pd
}
