import SwiftUI
import PsmithKit
import PsmithUI

/// The fields the profile pages edit, as one value so the draft can count
/// and revert changes field by field.
struct ProfileFields: Equatable {
    var name = ""
    var description = ""
    var favorite = false
    var parentOnly = false
    var parentProfileID: String?
    var defaultProviderID: String?
    var defaultModelID: String?
    var systemMessage = ""
    var defaultUserMessage = ""
    var welcomeMessage = ""
    var compressionMode: PsmithCompressionMode?
    var compressionProviderID: String?
    var compressionModelID: String?
    var compressionGuide = ""
    /// nil is the cloud title model (or inherit); `apple_foundation` is on-device.
    var titleProviderKind: String?
    var titleProviderID: String?
    var titleModelID: String?
    var titleGuide = ""

    init() {}

    init(_ p: PsmithProfile) {
        name = p.name
        description = p.description
        favorite = p.favorite
        parentOnly = p.parentOnly
        parentProfileID = p.parentProfileID
        defaultProviderID = p.defaultSettings?.defaultProviderID
        defaultModelID = p.defaultSettings?.defaultModelID
        systemMessage = p.systemMessage ?? ""
        defaultUserMessage = p.defaultUserMessage ?? ""
        welcomeMessage = p.welcomeMessage ?? ""
        compressionMode = p.compressionMode
        compressionProviderID = p.compressionProviderID
        compressionModelID = p.compressionModelID
        compressionGuide = p.compressionGuide ?? ""
        titleProviderKind = p.titleProviderKind
        titleProviderID = p.titleProviderID
        titleModelID = p.titleModelID
        titleGuide = p.titleGuide ?? ""
    }

    /// How many fields differ, counting a model choice (provider and model) once.
    func changes(from other: ProfileFields) -> Int {
        var n = 0
        if name != other.name { n += 1 }
        if description != other.description { n += 1 }
        if favorite != other.favorite { n += 1 }
        if parentOnly != other.parentOnly { n += 1 }
        if parentProfileID != other.parentProfileID { n += 1 }
        if defaultProviderID != other.defaultProviderID || defaultModelID != other.defaultModelID { n += 1 }
        if systemMessage != other.systemMessage { n += 1 }
        if defaultUserMessage != other.defaultUserMessage { n += 1 }
        if welcomeMessage != other.welcomeMessage { n += 1 }
        if compressionMode != other.compressionMode { n += 1 }
        if compressionProviderID != other.compressionProviderID || compressionModelID != other.compressionModelID { n += 1 }
        if compressionGuide != other.compressionGuide { n += 1 }
        if titleProviderKind != other.titleProviderKind { n += 1 }
        if titleProviderID != other.titleProviderID || titleModelID != other.titleModelID { n += 1 }
        if titleGuide != other.titleGuide { n += 1 }
        return n
    }
}

/// A profile-attached plugin while it's being edited. The config is untyped
/// JSON because every plugin's schema differs. A disabled row turns off the
/// same-named plugin the profile would inherit.
struct ProfileDraftPlugin: Identifiable {
    let id = UUID()
    var pluginName: String
    var config: [String: Any]
    var disabled = false

    init(pluginName: String, config: [String: Any], disabled: Bool = false) {
        self.pluginName = pluginName
        self.config = config
        self.disabled = disabled
    }

    init(_ p: PsmithProfilePlugin) {
        self.init(pluginName: p.pluginName, config: p.disabled ? [:] : decodePluginConfig(p.config), disabled: p.disabled)
    }

    func same(as p: PsmithProfilePlugin) -> Bool {
        guard pluginName == p.pluginName, disabled == p.disabled else { return false }
        return disabled || pluginValuesEqual(config, decodePluginConfig(p.config))
    }
}

/// One profile's unsaved edits, shared by the profile page and every page
/// it pushes (models, plugins, prompts) so they all feed one save bar. It
/// outlives a trip back to the list: drafts are kept per profile until saved
/// or reverted, so backing out never silently drops work.
@Observable
@MainActor
final class ProfileDraft {
    /// nil for a profile that doesn't exist yet.
    let profileID: String?
    var fields: ProfileFields
    private(set) var base: ProfileFields
    var plugins: [ProfileDraftPlugin] = []
    private(set) var pluginsBase: [PsmithProfilePlugin] = []
    private(set) var pluginsLoaded = false
    /// When the attached plugins couldn't be fetched the list stays read
    /// only: saving an empty list (an atomic replace) would detach them all.
    private(set) var pluginsLoadFailed = false
    /// A created profile's id once the create landed, so a retried save
    /// after a failed plugin write updates it instead of creating another.
    private(set) var createdID: String?
    var saving = false
    var error: String?

    init(profile: PsmithProfile?) {
        profileID = profile?.id
        let f = profile.map(ProfileFields.init) ?? ProfileFields()
        fields = f
        base = f
        if profile == nil { pluginsLoaded = true }
    }

    private static var store: [String: ProfileDraft] = [:]

    /// The draft for a profile, kept across pushes and pops.
    static func draft(for profile: PsmithProfile?) -> ProfileDraft {
        let key = profile?.id ?? "new"
        if let d = store[key] { return d }
        let d = ProfileDraft(profile: profile)
        store[key] = d
        return d
    }

    static func discard(_ draft: ProfileDraft) {
        store[draft.profileID ?? "new"] = nil
    }

    var pluginChanges: Int {
        guard pluginsLoaded else { return 0 }
        let n = max(plugins.count, pluginsBase.count)
        return (0..<n).filter { i in
            guard i < plugins.count, i < pluginsBase.count else { return true }
            return !plugins[i].same(as: pluginsBase[i])
        }.count
    }

    var changeCount: Int { fields.changes(from: base) + pluginChanges }

    var isNew: Bool { profileID == nil && createdID == nil }

    var isDirty: Bool {
        if profileID == nil { return !fields.name.trimmingCharacters(in: .whitespaces).isEmpty || changeCount > 0 }
        return changeCount > 0
    }

    var canSave: Bool { !fields.name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    func revert() {
        fields = base
        plugins = pluginsBase.map(ProfileDraftPlugin.init)
        error = nil
    }

    /// Seeds the attached plugins once. A later load never overwrites a
    /// draft the user has started editing.
    func loadPlugins(_ profiles: ProfilesViewModel) async {
        guard !pluginsLoaded, let id = profileID else { return }
        if profiles.pluginTypes.isEmpty { await profiles.loadPluginTypes() }
        await profiles.loadUserPluginSettings()
        pluginsLoadFailed = false
        await profiles.loadPlugins(forProfileID: id)
        guard let stored = profiles.profilePlugins[id] else {
            pluginsLoadFailed = true
            return
        }
        seedPlugins(stored)
    }

    func seedPlugins(_ stored: [PsmithProfilePlugin]) {
        pluginsBase = stored
        plugins = stored.map(ProfileDraftPlugin.init)
        pluginsLoaded = true
    }

    func save(_ profiles: ProfilesViewModel) async -> Bool {
        guard canSave else { return false }
        saving = true
        error = nil
        defer { saving = false }
        let f = fields
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let existing = profiles.profile(id: (profileID ?? createdID))
        // The server replaces the whole defaults blob; call settings and
        // include-thinking are edited elsewhere, so carry them through.
        let defaults = PsmithProfileDefaults(
            defaultProviderID: f.defaultProviderID,
            defaultModelID: f.defaultModelID,
            includeThinkingInHistory: existing?.defaultSettings?.includeThinkingInHistory,
            callSettings: existing?.defaultSettings?.callSettings
        )
        let patch = PsmithProfilePatch(
            name: f.name.trimmingCharacters(in: .whitespaces),
            parentProfileID: f.parentProfileID,
            systemMessage: trim(f.systemMessage).isEmpty ? nil : trim(f.systemMessage),
            defaultUserMessage: trim(f.defaultUserMessage).isEmpty ? nil : trim(f.defaultUserMessage),
            compressionGuide: trim(f.compressionGuide).isEmpty ? nil : trim(f.compressionGuide),
            compressionMode: f.compressionMode,
            compressionProviderID: f.compressionProviderID,
            compressionModelID: f.compressionModelID,
            defaultSettings: defaults,
            titleProviderID: f.titleProviderID,
            titleModelID: f.titleModelID,
            titleGuide: trim(f.titleGuide).isEmpty ? nil : trim(f.titleGuide),
            titleProviderKind: f.titleProviderKind,
            description: f.description.trimmingCharacters(in: .whitespaces),
            parentOnly: f.parentOnly,
            favorite: f.favorite,
            welcomeMessage: trim(f.welcomeMessage).isEmpty ? nil : trim(f.welcomeMessage)
        )
        // Proto field names; some fields clear on an empty value, others only through this list.
        var clear: [String] = []
        if f.parentProfileID == nil { clear.append("parent_profile_id") }
        if trim(f.systemMessage).isEmpty { clear.append("system_message") }
        if trim(f.defaultUserMessage).isEmpty { clear.append("default_user_message") }
        if trim(f.compressionGuide).isEmpty { clear.append("compression_guide") }
        if f.compressionMode == nil { clear.append("compression_mode") }
        if f.compressionProviderID == nil { clear.append("compression_provider_id") }
        if f.compressionModelID == nil { clear.append("compression_model_id") }
        if f.titleProviderID == nil { clear.append("title_provider_id") }
        if f.titleModelID == nil { clear.append("title_model_id") }
        if trim(f.titleGuide).isEmpty { clear.append("title_guide") }
        if f.titleProviderKind == nil { clear.append("title_provider_kind") }
        if trim(f.welcomeMessage).isEmpty { clear.append("welcome_message") }

        do {
            let id: String
            if let known = profileID ?? createdID {
                _ = try await profiles.update(id: known, patch: patch, clearFields: clear)
                id = known
            } else {
                let created = try await profiles.create(patch)
                createdID = created.id
                id = created.id
            }
            if pluginsLoaded && pluginChanges > 0 {
                let rows = plugins.enumerated().map { i, p in
                    PsmithProfilePlugin(pluginName: p.pluginName, ordinal: Int32(i),
                                        config: p.disabled ? Data("{}".utf8) : encodePluginConfig(p.config),
                                        disabled: p.disabled)
                }
                try await profiles.savePlugins(forProfileID: id, plugins: rows)
                pluginsBase = rows
            }
            base = fields
            await profiles.load()
            return true
        } catch {
            self.error = PsmithError.display(error)
            return false
        }
    }
}

/// Lookups the profile pages share.
@MainActor
enum ProfileLookup {
    static func modelName(_ profiles: ProfilesViewModel, provider: String?, model: String?) -> String? {
        guard let pid = provider, let mid = model else { return nil }
        return profiles.availableModels.first { $0.modelID == mid && $0.providerID == pid }?.displayName ?? mid
    }

    static func color(_ p: PsmithProfile, theme: Theme) -> Color {
        p.parentOnly ? IKS.parentGray : ProfileColor.color(for: p.id, theme: theme)
    }

    /// Ancestors, nearest first, stopping at a cycle or after ten hops.
    static func ancestors(of parentID: String?, in all: [PsmithProfile]) -> [PsmithProfile] {
        var out: [PsmithProfile] = []
        var next = parentID
        var seen: Set<String> = []
        while let id = next, !seen.contains(id), out.count < 10, let p = all.first(where: { $0.id == id }) {
            seen.insert(id)
            out.append(p)
            next = p.parentProfileID
        }
        return out
    }

    /// Fields a profile's call settings override.
    static func overrideCount(_ cs: PsmithCallSettings?) -> Int {
        guard let cs else { return 0 }
        var n = 0
        if cs.temperature != nil { n += 1 }
        if cs.topP != nil { n += 1 }
        if cs.maxOutputTokens != nil { n += 1 }
        if cs.topK != nil { n += 1 }
        if !cs.stopSequences.isEmpty { n += 1 }
        if cs.thinking?.isEmpty == false { n += 1 }
        if cs.explicitCache != nil { n += 1 }
        if cs.anthropic?.isEmpty == false { n += 1 }
        if cs.openai?.isEmpty == false { n += 1 }
        if cs.google?.isEmpty == false { n += 1 }
        return n
    }
}
