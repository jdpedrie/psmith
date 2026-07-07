import Foundation
import Observation

public enum ProfilesDetailMode: Equatable, Sendable {
    case viewing
    case adding
    case editing
}

/// Drives the Profiles settings category. Reusable across macOS / iOS.
@Observable
@MainActor
public final class ProfilesViewModel {
    private let client: PsmithClient

    public var profiles: [PsmithProfile] = []
    /// Cursor for the next page; nil = fully loaded. Paging state is
    /// reset by load() and advanced by loadMore().
    public private(set) var nextPageToken: String?
    public private(set) var isLoadingMore = false
    /// Page size for load()/loadMore(). Var so tests can shrink it;
    /// 100 matches the server cap, so installations under 100 profiles
    /// behave exactly as the old return-everything path did.
    public var pageSize: Int32 = 100
    public var hasMore: Bool { nextPageToken != nil }
    public var selectedID: String?
    public var isLoading = false
    public var isDeleting = false
    public var error: String?

    public var detailMode: ProfilesDetailMode = .viewing
    public var showDeleteConfirm = false

    /// All enabled models across all providers, for the "default model" picker
    /// inside profile forms. Loaded lazily.
    public var availableModels: [PsmithUserModel] = []
    public var providerLabels: [String: String] = [:]
    /// Provider driver type keyed by provider ID — used by the profile form
    /// to pick the right CallSettings extension block (anthropic / openai /
    /// google) based on the profile's default model.
    public var providerTypes: [String: String] = [:]
    /// openai-compatible preset id keyed by provider ID — used by the
    /// profile form's model picker to render the right provider logo on
    /// each section header. Empty for native drivers and pre-preset
    /// custom configs.
    public var providerPresetIDs: [String: String] = [:]
    /// Provider-level default CallSettings keyed by provider ID —
    /// bottom layer of the resolution chain. Feeds the profile
    /// editor's inherit-preview so it matches send-time resolution.
    public var providerDefaultSettings: [String: PsmithCallSettings] = [:]

    /// Server's compiled-in plugin registry. Loaded lazily by
    /// `loadPluginTypes()`. Sorted by display name.
    public var pluginTypes: [PsmithPluginType] = []

    /// Per-profile plugin pipeline keyed by profile id. Populated by
    /// `loadPlugins(forProfileID:)` and replaced by `savePlugins(...)`.
    public var profilePlugins: [String: [PsmithProfilePlugin]] = [:]

    public init(client: PsmithClient) { self.client = client }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.profiles.listPage(pageSize: pageSize)
            profiles = page.items
            nextPageToken = page.nextPageToken
            error = nil
            if selectedID == nil, let first = profiles.first {
                selectedID = first.id
            }
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Appends the next page. No-op while a page is in flight or when
    /// the list is fully loaded, so scroll-trigger callers can fire it
    /// unconditionally from onAppear.
    public func loadMore() async {
        guard let token = nextPageToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.profiles.listPage(pageSize: pageSize, pageToken: token)
            let known = Set(profiles.map(\.id))
            profiles.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextPageToken = page.nextPageToken
            error = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    public func select(_ id: String) {
        selectedID = id
        detailMode = .viewing
    }

    public func selected() -> PsmithProfile? {
        guard let id = selectedID else { return nil }
        return profiles.first { $0.id == id }
    }

    public func loadAvailableModels() async {
        // Always re-fetch — providers/models can be added or removed
        // between visits to a picker. The previous early-return on
        // non-empty cache caused stale state when a provider's models
        // were enabled after the first load.
        do {
            let providers = try await client.modelProviders.list()
            let labels = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.label) })
            let types  = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.type) })
            let models = try await withThrowingTaskGroup(of: [PsmithUserModel].self) { group in
                for p in providers {
                    group.addTask { try await self.client.modelProviders.listModels(providerID: p.id) }
                }
                var all: [PsmithUserModel] = []
                for try await batch in group { all.append(contentsOf: batch) }
                return all.sorted { $0.displayName < $1.displayName }
            }
            providerLabels = labels
            providerTypes = types
            providerPresetIDs = Dictionary(uniqueKeysWithValues:
                providers.compactMap { p in p.presetID.map { (p.id, $0) } }
            )
            providerDefaultSettings = Dictionary(uniqueKeysWithValues:
                providers.compactMap { p in p.defaultSettings.map { (p.id, $0) } }
            )
            availableModels = models
        } catch {
            // Non-fatal — picker just stays at whatever was loaded last.
        }
    }

    /// Optimistic local toggle of a user model's `favorite` flag — UI updates
    /// instantly, rolls back on error. Mirrors `toggleFavorite(_:)` for profiles.
    /// Server is the source of truth.
    public func toggleModelFavorite(providerID: String, modelID: String) async {
        guard let idx = availableModels.firstIndex(where: { $0.providerID == providerID && $0.modelID == modelID }) else { return }
        let original = availableModels[idx]
        let newValue = !original.favorite
        availableModels[idx] = PsmithUserModel(
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
            availableModels[idx] = original
            self.error = PsmithError.display(error)
        }
    }

    public func create(_ patch: PsmithProfilePatch) async throws -> PsmithProfile {
        let p = try await client.profiles.create(patch)
        profiles.append(p)
        profiles.sort { $0.name < $1.name }
        return p
    }

    public func update(id: String, patch: PsmithProfilePatch, clearFields: [String] = []) async throws -> PsmithProfile {
        let updated = try await client.profiles.update(id: id, patch: patch, clearFields: clearFields)
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx] = updated
        }
        profiles.sort { $0.name < $1.name }
        return updated
    }

    /// Concise display name walking the parent chain, slash-separated:
    /// `"Profile Name / Parent Name / Grandparent Name"`. Cycle-safe (caps
    /// at 8 hops). Returns just the profile name if no parents.
    public func conciseName(for profile: PsmithProfile) -> String {
        var parts: [String] = [profile.name]
        var current = profile.parentProfileID
        var seen: Set<String> = [profile.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let p = profiles.first(where: { $0.id == pid }) else { break }
            parts.append(p.name)
            current = p.parentProfileID
        }
        return parts.joined(separator: " / ")
    }

    /// Just the parent-chain portion (no leading profile name). Empty when
    /// the profile is standalone. Used by ProfileCard's secondary line.
    public func parentChainName(for profile: PsmithProfile) -> String {
        var parts: [String] = []
        var current = profile.parentProfileID
        var seen: Set<String> = [profile.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let p = profiles.first(where: { $0.id == pid }) else { break }
            parts.append(p.name)
            current = p.parentProfileID
        }
        return parts.joined(separator: " / ")
    }

    /// Sorted view of profiles for pickers: favorites first, then alpha by name.
    public var sortedForPicker: [PsmithProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Optimistic local toggle of `favorite` so the UI updates instantly;
    /// rolls back on error. Server is the source of truth.
    public func toggleFavorite(_ id: String) async {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let original = profiles[idx]
        let newValue = !original.favorite
        profiles[idx] = PsmithProfile(
            id: original.id, name: original.name,
            description: original.description,
            parentOnly: original.parentOnly,
            favorite: newValue,
            parentProfileID: original.parentProfileID,
            systemMessage: original.systemMessage,
            defaultUserMessage: original.defaultUserMessage,
            compressionGuide: original.compressionGuide,
            compressionMode: original.compressionMode,
            compressionProviderID: original.compressionProviderID,
            compressionModelID: original.compressionModelID,
            defaultSettings: original.defaultSettings,
            titleProviderID: original.titleProviderID,
            titleModelID: original.titleModelID,
            titleGuide: original.titleGuide,
            titleProviderKind: original.titleProviderKind,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        do {
            var patch = PsmithProfilePatch()
            patch.favorite = newValue
            _ = try await client.profiles.update(id: id, patch: patch)
        } catch {
            profiles[idx] = original
            self.error = PsmithError.display(error)
        }
    }

    /// True if any other profile lists this one as its parent.
    public func hasChildren(_ id: String) -> Bool {
        profiles.contains { $0.parentProfileID == id }
    }

    // MARK: - Plugins

    /// Loads the server's plugin registry. Sorts the result by display name.
    /// Errors land in `error` (the existing form error surface).
    public func loadPluginTypes() async {
        do {
            let types = try await client.profiles.listPluginTypes()
            pluginTypes = types.sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Per-user, per-plugin global config blobs. Populated by
    /// `loadUserPluginSettings()`; `globalSettings(for:)` returns the
    /// blob (or nil) for one plugin. Replaces and is replaced by
    /// `upsertUserPluginSettings(...)`.
    public var userPluginSettings: [String: PsmithUserPluginSettings] = [:]

    /// Currently-selected plugin name on the Plugin Settings surface;
    /// drives the middle column's highlight + the detail column's form
    /// binding. Nil → empty state.
    public var selectedPluginID: String?

    public func loadUserPluginSettings() async {
        do {
            let rows = try await client.profiles.listUserPluginSettings()
            var map: [String: PsmithUserPluginSettings] = [:]
            for row in rows { map[row.pluginName] = row }
            userPluginSettings = map
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    public func upsertUserPluginSettings(pluginName: String, config: Data) async throws {
        let updated = try await client.profiles.upsertUserPluginSettings(pluginName: pluginName, config: config)
        userPluginSettings[pluginName] = updated
    }

    /// Returns the stored global config for a plugin (or `{}` when the
    /// user hasn't configured it yet).
    public func globalSettings(for pluginName: String) -> PsmithUserPluginSettings {
        userPluginSettings[pluginName] ?? PsmithUserPluginSettings(pluginName: pluginName, config: Data())
    }

    /// Loads the plugin pipeline for one profile and stashes it under
    /// `profilePlugins[id]`.
    public func loadPlugins(forProfileID id: String) async {
        do {
            profilePlugins[id] = try await client.profiles.getProfilePlugins(profileID: id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Atomic replace. On success the stored slice for `id` is replaced by
    /// the server-canonical list (with persisted ordinals).
    public func savePlugins(forProfileID id: String, plugins: [PsmithProfilePlugin]) async throws {
        let updated = try await client.profiles.setProfilePlugins(profileID: id, plugins: plugins)
        profilePlugins[id] = updated
    }

    public func deleteSelected() async {
        guard let id = selectedID else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await client.profiles.delete(id: id)
            profiles.removeAll { $0.id == id }
            selectedID = profiles.first?.id
            detailMode = .viewing
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}
