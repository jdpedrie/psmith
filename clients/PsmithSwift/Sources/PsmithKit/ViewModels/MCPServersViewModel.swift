import Foundation
import Observation

/// Settings → MCP Servers. Backs the registry CRUD screens on Mac and
/// iOS. Attachment to profiles/conversations happens through the
/// normal plugin pickers (registered servers arrive there as pseudo-
/// plugin entries via ListPluginTypes), so this model is pure registry
/// management.
@Observable
@MainActor
public final class MCPServersViewModel {
    private let client: PsmithClient

    public var servers: [PsmithMCPServer] = []
    public var isLoading = false
    public var error: String?

    /// Selection + add-mode state for master-detail hosts (the Mac
    /// settings columns). List/detail views share this model, so the
    /// selection has to live here rather than in either view.
    public var selectedID: String?
    public var isAddingNew = false

    public var selected: PsmithMCPServer? {
        guard let selectedID else { return nil }
        return servers.first { $0.id == selectedID }
    }

    public func startAdding() {
        isAddingNew = true
        selectedID = nil
    }

    public func select(_ id: String) {
        selectedID = id
        isAddingNew = false
    }

    public init(client: PsmithClient) {
        self.client = client
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await client.profiles.listMCPServers()
            error = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Create (nil id) or update one server. `env`/`headers` nil keeps
    /// the stored secret, empty string clears it. Returns the saved
    /// server, or nil on failure (error is set for the UI).
    @discardableResult
    public func upsert(
        id: String?,
        name: String,
        transport: String,
        command: String = "",
        args: String = "",
        env: String? = nil,
        url: String = "",
        headers: String? = nil,
        toolPrefix: String = ""
    ) async -> PsmithMCPServer? {
        do {
            let saved = try await client.profiles.upsertMCPServer(
                id: id, name: name, transport: transport,
                command: command, args: args, env: env,
                url: url, headers: headers, toolPrefix: toolPrefix
            )
            if let idx = servers.firstIndex(where: { $0.id == saved.id }) {
                servers[idx] = saved
            } else {
                servers.append(saved)
                servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            error = nil
            return saved
        } catch {
            self.error = PsmithError.display(error)
            return nil
        }
    }

    /// Returns true on success. The registry row disappears; pipeline
    /// rows referencing it degrade to a quiet no-op server-side.
    public func delete(id: String) async -> Bool {
        do {
            try await client.profiles.deleteMCPServer(id: id)
            servers.removeAll { $0.id == id }
            error = nil
            return true
        } catch {
            self.error = PsmithError.display(error)
            return false
        }
    }
}
