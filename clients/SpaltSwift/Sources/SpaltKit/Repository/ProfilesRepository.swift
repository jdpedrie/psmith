import Foundation
import Connect

public final class ProfilesRepository: Sendable {
    private let client: Spalt_V1_ProfilesServiceClientInterface
    private let cache: SpaltCache?

    public init(client: Spalt_V1_ProfilesServiceClientInterface, cache: SpaltCache? = nil) {
        self.client = client
        self.cache = cache
    }

    public func list() async throws -> [SpaltProfile] {
        // Bounded timeout — see RPCTimeout.swift. ConversationsModel
        // fires this alongside listConversations at launch; without
        // the timeout an unreachable server pins the splash on
        // URLSession's default (~60s).
        let resp = try? await withRPCTimeout(seconds: 6) { [client] in
            await client.listProfiles(request: Spalt_V1_ListProfilesRequest(), headers: [:])
        }
        if let msg = resp?.message {
            let items = msg.profiles.map(SpaltProfile.init(from:))
            if let cache {
                try? await cache.set(items, kind: CacheKind.profiles, id: "all", capBytes: CachePreferences.capBytes)
            }
            return items
        }
        if let cache,
           let cached: [SpaltProfile] = await cache.get([SpaltProfile].self, kind: CacheKind.profiles, id: "all") {
            return cached
        }
        throw resp?.error.map(SpaltError.from) ?? .missingPayload("list profiles")
    }

    public func get(id: String, resolve: Bool = false) async throws -> (SpaltProfile, SpaltProfile?) {
        var req = Spalt_V1_GetProfileRequest()
        req.id = id
        req.resolve = resolve
        let resp = await client.getProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("get profile") }
        let profile = SpaltProfile(from: msg.profile)
        let resolved = msg.hasResolved ? SpaltProfile(from: msg.resolved) : nil
        return (profile, resolved)
    }

    public func create(_ patch: SpaltProfilePatch) async throws -> SpaltProfile {
        var req = Spalt_V1_CreateProfileRequest()
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
        if let v = patch.welcomeMessage        { req.welcomeMessage = v }
        let resp = await client.createProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("create profile") }
        return SpaltProfile(from: msg.profile)
    }

    /// `clearFields` lists protobuf field names whose value should be reset to inherit from the parent.
    /// Valid: `system_message`, `default_user_message`, `compression_guide`, `compression_mode`,
    /// `compression_provider_id`, `compression_model_id`, `default_settings`, `title_provider_id`,
    /// `title_model_id`, `title_guide`, `title_provider_kind`, `parent_profile_id`.
    public func update(id: String, patch: SpaltProfilePatch, clearFields: [String] = []) async throws -> SpaltProfile {
        var req = Spalt_V1_UpdateProfileRequest()
        req.id = id
        if let v = patch.name                  { req.name = v }
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
        if let v = patch.welcomeMessage        { req.welcomeMessage = v }
        req.clearFields_p = clearFields
        let resp = await client.updateProfile(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("update profile") }
        return SpaltProfile(from: msg.profile)
    }

    public func delete(id: String) async throws {
        var req = Spalt_V1_DeleteProfileRequest()
        req.id = id
        let resp = await client.deleteProfile(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw SpaltError.from(err) }
    }

    // MARK: - Plugins

    public func listPluginTypes() async throws -> [SpaltPluginType] {
        let resp = await client.listPluginTypes(request: Spalt_V1_ListPluginTypesRequest(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("list plugin types") }
        return msg.pluginTypes.map(SpaltPluginType.init(from:))
    }

    public func getProfilePlugins(profileID: String) async throws -> [SpaltProfilePlugin] {
        var req = Spalt_V1_GetProfilePluginsRequest()
        req.profileID = profileID
        let resp = await client.getProfilePlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("get profile plugins") }
        return msg.plugins.map(SpaltProfilePlugin.init(from:))
    }

    public func setProfilePlugins(profileID: String, plugins: [SpaltProfilePlugin]) async throws -> [SpaltProfilePlugin] {
        var req = Spalt_V1_SetProfilePluginsRequest()
        req.profileID = profileID
        req.plugins = plugins.map { $0.proto }
        let resp = await client.setProfilePlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("set profile plugins") }
        return msg.plugins.map(SpaltProfilePlugin.init(from:))
    }

    // MARK: - User-scoped global plugin settings

    public func getUserPluginSettings(pluginName: String) async throws -> SpaltUserPluginSettings {
        var req = Spalt_V1_GetUserPluginSettingsRequest()
        req.pluginName = pluginName
        let resp = await client.getUserPluginSettings(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("get user plugin settings") }
        return SpaltUserPluginSettings(from: msg.settings)
    }

    public func listUserPluginSettings() async throws -> [SpaltUserPluginSettings] {
        let resp = await client.listUserPluginSettings(request: Spalt_V1_ListUserPluginSettingsRequest(), headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("list user plugin settings") }
        return msg.settings.map(SpaltUserPluginSettings.init(from:))
    }

    public func upsertUserPluginSettings(pluginName: String, config: Data) async throws -> SpaltUserPluginSettings {
        var req = Spalt_V1_UpsertUserPluginSettingsRequest()
        req.pluginName = pluginName
        req.config = config
        let resp = await client.upsertUserPluginSettings(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(SpaltError.from) ?? .missingPayload("upsert user plugin settings") }
        return SpaltUserPluginSettings(from: msg.settings)
    }
}

/// Optional-each-field patch shape for create/update. `nil` = don't set.
/// To clear a field on update, pass its proto name in `clearFields`.
public struct SpaltProfilePatch: Sendable {
    public var name: String?
    public var parentProfileID: String?
    public var systemMessage: String?
    public var defaultUserMessage: String?
    public var compressionGuide: String?
    public var compressionMode: SpaltCompressionMode?
    public var compressionProviderID: String?
    public var compressionModelID: String?
    public var defaultSettings: SpaltProfileDefaults?
    public var titleProviderID: String?
    public var titleModelID: String?
    public var titleGuide: String?
    /// Sentinel for non-server title generation (e.g.
    /// `SpaltTitleProviderKind.appleFoundation`). Pass `clearFields:
    /// ["title_provider_kind"]` to revert to default cloud-titled behavior.
    public var titleProviderKind: String?
    public var description: String?
    public var parentOnly: Bool?
    public var favorite: Bool?
    /// Profile.welcome_message — rendered as the synthetic first
    /// assistant bubble in fresh conversations. Pass `clearFields:
    /// ["welcome_message"]` to remove.
    public var welcomeMessage: String?

    public init(
        name: String? = nil,
        parentProfileID: String? = nil,
        systemMessage: String? = nil,
        defaultUserMessage: String? = nil,
        compressionGuide: String? = nil,
        compressionMode: SpaltCompressionMode? = nil,
        compressionProviderID: String? = nil,
        compressionModelID: String? = nil,
        defaultSettings: SpaltProfileDefaults? = nil,
        titleProviderID: String? = nil,
        titleModelID: String? = nil,
        titleGuide: String? = nil,
        titleProviderKind: String? = nil,
        description: String? = nil,
        parentOnly: Bool? = nil,
        favorite: Bool? = nil,
        welcomeMessage: String? = nil
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
        self.welcomeMessage = welcomeMessage
    }
}

private func pbCompressionMode(_ m: SpaltCompressionMode) -> Spalt_V1_CompressionMode {
    switch m {
    case .replace:     return .replace
    case .append:      return .append
    case .unspecified: return .unspecified
    }
}

private func pbDefaults(_ d: SpaltProfileDefaults) -> Spalt_V1_ProfileDefaults {
    var pd = Spalt_V1_ProfileDefaults()
    if let v = d.defaultProviderID         { pd.defaultProviderID = v }
    if let v = d.defaultModelID            { pd.defaultModelID = v }
    if let v = d.includeThinkingInHistory  { pd.includeThinkingInHistory = v }
    if let cs = d.callSettings, !cs.isEmpty { pd.callSettings = cs.proto }
    return pd
}
