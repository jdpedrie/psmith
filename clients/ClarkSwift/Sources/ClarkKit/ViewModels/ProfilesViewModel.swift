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
    private let client: ClarkClient

    public var profiles: [ClarkProfile] = []
    public var selectedID: String?
    public var isLoading = false
    public var isDeleting = false
    public var error: String?

    public var detailMode: ProfilesDetailMode = .viewing
    public var showDeleteConfirm = false

    /// All enabled models across all providers, for the "default model" picker
    /// inside profile forms. Loaded lazily.
    public var availableModels: [ClarkUserModel] = []
    public var providerLabels: [String: String] = [:]

    public init(client: ClarkClient) { self.client = client }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profiles = try await client.profiles.list()
            error = nil
            if selectedID == nil, let first = profiles.first {
                selectedID = first.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func select(_ id: String) {
        selectedID = id
        detailMode = .viewing
    }

    public func selected() -> ClarkProfile? {
        guard let id = selectedID else { return nil }
        return profiles.first { $0.id == id }
    }

    public func loadAvailableModels() async {
        guard availableModels.isEmpty else { return }
        do {
            let providers = try await client.modelProviders.list()
            providerLabels = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.label) })
            availableModels = try await withThrowingTaskGroup(of: [ClarkUserModel].self) { group in
                for p in providers {
                    group.addTask { try await self.client.modelProviders.listModels(providerID: p.id) }
                }
                var all: [ClarkUserModel] = []
                for try await models in group { all.append(contentsOf: models) }
                return all.sorted { $0.displayName < $1.displayName }
            }
        } catch {
            // Non-fatal — picker just stays empty
        }
    }

    public func create(_ patch: ClarkProfilePatch) async throws -> ClarkProfile {
        let p = try await client.profiles.create(patch)
        profiles.append(p)
        profiles.sort { $0.name < $1.name }
        return p
    }

    public func update(id: String, patch: ClarkProfilePatch, clearFields: [String] = []) async throws -> ClarkProfile {
        let updated = try await client.profiles.update(id: id, patch: patch, clearFields: clearFields)
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx] = updated
        }
        profiles.sort { $0.name < $1.name }
        return updated
    }

    /// Concise display name walking the parent chain:
    /// `"Profile Name (Parent Name, Grandparent Name)"`.
    /// Cycle-safe (caps at 8 hops).
    public func conciseName(for profile: ClarkProfile) -> String {
        var ancestors: [String] = []
        var current = profile.parentProfileID
        var seen: Set<String> = [profile.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let p = profiles.first(where: { $0.id == pid }) else { break }
            ancestors.append(p.name)
            current = p.parentProfileID
        }
        if ancestors.isEmpty { return profile.name }
        return "\(profile.name) (\(ancestors.joined(separator: ", ")))"
    }

    /// True if any other profile lists this one as its parent.
    public func hasChildren(_ id: String) -> Bool {
        profiles.contains { $0.parentProfileID == id }
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
            self.error = error.localizedDescription
        }
    }
}
