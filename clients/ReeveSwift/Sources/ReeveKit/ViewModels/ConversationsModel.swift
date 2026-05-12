import Foundation
import Observation

/// Top-level filter applied to the sidebar conversation list. Drives both
/// what the server returns (the search-mode `searchQuery` is sent as a
/// title filter) and how the UI groups results.
public enum ConversationListMode: Sendable, Hashable {
    case allChats
    case byProfile
    case search
}

/// List of conversations + profiles for the active user.
/// Drives the sidebar conversation list. Reusable across macOS / iOS.
@Observable
@MainActor
public final class ConversationsModel {
    private let client: ReeveClient
    /// Optional. When present, `refresh()` sweeps currently-running
    /// stream_runs for the user and asks the hub to adopt them — so a
    /// cold launch into the conversations list immediately re-attaches
    /// to any mid-generation conversation.
    private let hub: StreamHub?

    public var conversations: [ReeveConversation] = []
    public var profiles: [ReeveProfile] = []
    public var selectedID: ReeveConversation.ID?
    public var loadError: String?
    public var isLoading = false

    /// Sidebar filter mode (All Chats / By Profile / Search). UI uses this
    /// to pick its grouping; refresh() uses it to know whether to send the
    /// `searchQuery` title filter to the server.
    public var listMode: ConversationListMode = .allChats
    /// Sort order for the All Chats list. Ignored when `listMode` is
    /// `.byProfile` (profiles always group with their own internal order)
    /// or `.search` (search results always sort by recency).
    public var listOrder: ReeveConversationOrder = .recentlyUsed
    /// Substring matched server-side against conversation titles when
    /// `listMode == .search`. Trimmed; refresh() short-circuits empty
    /// queries to a flat list with no filter.
    public var searchQuery: String = ""

    public init(client: ReeveClient, hub: StreamHub? = nil) {
        self.client = client
        self.hub = hub
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listOrder: ReeveConversationOrder
            let titleQuery: String?
            switch listMode {
            case .allChats:
                listOrder = self.listOrder
                titleQuery = nil
            case .byProfile:
                // The UI groups by profile and sorts within groups by recency.
                listOrder = .recentlyUsed
                titleQuery = nil
            case .search:
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                listOrder = .recentlyUsed
                titleQuery = trimmed.isEmpty ? nil : trimmed
            }
            async let convos = client.conversations.list(order: listOrder, titleQuery: titleQuery)
            async let profs = client.profiles.list()
            let (cs, ps) = try await (convos, profs)
            self.conversations = cs.items
            self.profiles = ps
            self.loadError = nil
            // Sweep for stream_runs the user left running. Adopting
            // them in the hub means the list / conversation entry
            // shows live content immediately, instead of catching up
            // on the next refresh. Best-effort.
            if let hub {
                await adoptActiveRuns(into: hub)
            }
            // Don't auto-select on refresh. Selection is user-driven; an
            // auto-select hops the detail pane away from the welcome page.
            // Drop a stale selection if its conversation is no longer in
            // the list (e.g. filtered out by search).
            if let sel = selectedID, !cs.items.contains(where: { $0.id == sel }) {
                selectedID = nil
            }
        } catch {
            self.loadError = ReeveError.display(error)
        }
    }

    @discardableResult
    public func newConversation(
        profileID: String,
        title: String? = nil,
        settings: ReeveConversationSettings? = nil
    ) async -> ReeveConversation? {
        do {
            let effectiveSettings = (settings?.isEmpty ?? true) ? nil : settings
            let c = try await client.conversations.create(
                profileID: profileID,
                title: title,
                settings: effectiveSettings
            )
            self.conversations.insert(c, at: 0)
            self.selectedID = c.id
            return c
        } catch {
            self.loadError = ReeveError.display(error)
            return nil
        }
    }

    public func delete(_ id: String) async {
        do {
            try await client.conversations.delete(id: id)
            self.conversations.removeAll { $0.id == id }
            if selectedID == id { selectedID = conversations.first?.id }
        } catch {
            self.loadError = ReeveError.display(error)
        }
    }

    /// Sets a new title and updates the in-memory list so callers see
    /// the rename without waiting for a refresh round-trip.
    public func rename(id: String, title: String) async {
        do {
            let updated = try await client.conversations.updateTitle(id: id, title: title)
            if let idx = conversations.firstIndex(where: { $0.id == id }) {
                conversations[idx] = updated
            }
        } catch {
            self.loadError = ReeveError.display(error)
        }
    }

    public var clientRef: ReeveClient { client }

    private func adoptActiveRuns(into hub: StreamHub) async {
        do {
            let runs = try await client.streams.listActiveRuns()
            for run in runs { hub.adopt(run) }
        } catch {
            // Silent — hub stays empty, view models will fall back to
            // a per-conversation server query on entry.
        }
    }
}
