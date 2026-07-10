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
    private let client: PsmithClient
    /// Optional. When present, `refresh()` sweeps currently-running
    /// stream_runs for the user and asks the hub to adopt them — so a
    /// cold launch into the conversations list immediately re-attaches
    /// to any mid-generation conversation.
    private let hub: StreamHub?

    /// Shared per-account ProfilesViewModel. When wired (the
    /// production path), `profiles` reads through to its list so
    /// adding/removing a profile in Settings propagates to every
    /// view binding on `convos.profiles` automatically via
    /// Swift Observation. nil in tests / snapshot stubs that
    /// construct ConversationsModel without an AppModel context;
    /// in that case `profiles` falls back to the locally-stored
    /// `_profiles` slice (also writable from outside, so the
    /// existing test setters keep working).
    private let profilesVM: ProfilesViewModel?

    public var conversations: [PsmithConversation] = []
    /// Cursor for the next page of the current listing (order + query);
    /// nil = fully loaded. refresh() resets it, loadMore() advances it.
    public private(set) var nextPageToken: String?
    public private(set) var isLoadingMore = false
    /// Page size for refresh()/loadMore(). Var so tests can shrink it.
    /// 50 keeps the first paint fast; before paging the list silently
    /// capped at the server's 100 — conversations past that were
    /// unreachable on this client.
    public var pageSize: Int32 = 50
    public var hasMore: Bool { nextPageToken != nil }
    /// Profiles for the current user. Read through to the shared
    /// per-account ProfilesViewModel when available — that's what
    /// makes a "Settings → add profile → back to home" flow
    /// reflect immediately without an explicit refresh. Tests
    /// without a wired profilesVM read/write the local slice via
    /// the setter.
    public var profiles: [PsmithProfile] {
        get { profilesVM?.profiles ?? _profiles }
        set { _profiles = newValue }
    }
    private var _profiles: [PsmithProfile] = []
    public var selectedID: PsmithConversation.ID?
    public var loadError: String?
    public var isLoading = false

    /// Sidebar filter mode (All Chats / By Profile / Search). UI uses this
    /// to pick its grouping; refresh() uses it to know whether to send the
    /// `searchQuery` title filter to the server.
    public var listMode: ConversationListMode = .allChats
    /// Sort order for the All Chats list. Ignored when `listMode` is
    /// `.byProfile` (profiles always group with their own internal order)
    /// or `.search` (search results always sort by recency).
    public var listOrder: PsmithConversationOrder = .recentlyUsed
    /// Substring matched server-side against conversation titles when
    /// `listMode == .search`. Trimmed; refresh() short-circuits empty
    /// queries to a flat list with no filter.
    public var searchQuery: String = ""

    public init(
        client: PsmithClient,
        profiles profilesVM: ProfilesViewModel? = nil,
        hub: StreamHub? = nil
    ) {
        self.client = client
        self.profilesVM = profilesVM
        self.hub = hub
    }

    /// The wire order + title filter for the current list mode. refresh()
    /// and loadMore() must agree on these — a loadMore against a different
    /// listing than the one on screen would splice unrelated rows in.
    private func currentListing() -> (order: PsmithConversationOrder, titleQuery: String?) {
        switch listMode {
        case .allChats:
            return (listOrder, nil)
        case .byProfile:
            // The UI groups by profile and sorts within groups by recency.
            return (.recentlyUsed, nil)
        case .search:
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return (.recentlyUsed, trimmed.isEmpty ? nil : trimmed)
        }
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (listOrder, titleQuery) = currentListing()
            // Conversations come straight from the server. Profiles
            // route through the shared ProfilesViewModel when wired
            // so its mutations stay the source of truth across the
            // app; only the test fallback path fetches profiles
            // here directly.
            async let convos = client.conversations.list(pageSize: pageSize, order: listOrder, titleQuery: titleQuery)
            if let pvm = profilesVM {
                // Load both concurrently, but await the profile load too. A
                // bare unawaited `async let` is cancelled when this scope
                // exits, and because the conversation list often resolves
                // instantly from cache, that cancellation landed before the
                // profile fetch finished — leaving `profiles` empty and the
                // new-conversation button wrongly disabled.
                async let profileLoad: Void = pvm.load()
                let cs = try await convos
                self.conversations = cs.items
                self.nextPageToken = cs.nextPageToken
                await profileLoad
            } else {
                async let profs = client.profiles.list()
                let (cs, ps) = try await (convos, profs)
                self.conversations = cs.items
                self.nextPageToken = cs.nextPageToken
                self._profiles = ps
            }
            let cs = self.conversations
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
            if let sel = selectedID, !cs.contains(where: { $0.id == sel }) {
                selectedID = nil
            }
        } catch {
            self.loadError = PsmithError.display(error)
        }
    }

    @discardableResult
    /// Appends the next page of the current listing. No-op while a page
    /// is in flight or when the list is fully loaded, so scroll-trigger
    /// callers can fire it unconditionally from the last row's onAppear.
    public func loadMore() async {
        guard let token = nextPageToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (order, titleQuery) = currentListing()
            let page = try await client.conversations.list(
                pageSize: pageSize, pageToken: token, order: order, titleQuery: titleQuery)
            // Keyset paging can't duplicate rows, but a conversation
            // created between pages shifts nothing either — dedupe by id
            // anyway so a surprise upstream can't corrupt the list.
            let known = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextPageToken = page.nextPageToken
            loadError = nil
        } catch {
            loadError = PsmithError.display(error)
        }
    }

    public func newConversation(
        profileID: String,
        title: String? = nil,
        settings: PsmithConversationSettings? = nil
    ) async -> PsmithConversation? {
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
            self.loadError = PsmithError.display(error)
            return nil
        }
    }

    /// Archives the conversation and drops it from the active list —
    /// mirrors delete's local behavior; the row lives on in the
    /// Archived screen.
    public func archive(_ id: String) async {
        do {
            try await client.conversations.archive(id: id)
            conversations.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        } catch {
            loadError = PsmithError.display(error)
        }
    }

    /// Pins or unpins, then refreshes: the pinned block's position is
    /// server-defined ordering (ahead of page one, newest pin first),
    /// so re-fetching page one is both simpler and more honest than
    /// re-sorting locally.
    public func togglePin(_ id: String) async {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        do {
            if conv.pinnedAt == nil {
                try await client.conversations.pin(id: id)
            } else {
                try await client.conversations.unpin(id: id)
            }
            await refresh()
        } catch {
            loadError = PsmithError.display(error)
        }
    }

    public func delete(_ id: String) async {
        do {
            try await client.conversations.delete(id: id)
            self.conversations.removeAll { $0.id == id }
            if selectedID == id { selectedID = conversations.first?.id }
        } catch {
            self.loadError = PsmithError.display(error)
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
            self.loadError = PsmithError.display(error)
        }
    }

    // MARK: - Archived browsing

    /// The archive, loaded on demand (loadArchived) — never part of the
    /// active list. iOS renders it on a pushed screen, Mac swaps the
    /// sidebar list into archive mode; both read this state.
    public private(set) var archivedConversations: [PsmithConversation] = []
    public private(set) var archivedNextPageToken: String?
    public private(set) var archivedLoading = false

    public func loadArchived() async {
        archivedLoading = true
        defer { archivedLoading = false }
        do {
            let page = try await client.conversations.list(pageSize: 50, archived: true)
            archivedConversations = page.items
            archivedNextPageToken = page.nextPageToken
        } catch {
            if PsmithError.isCancellation(error) { return }
            loadError = PsmithError.display(error)
        }
    }

    public func loadMoreArchived() async {
        guard let token = archivedNextPageToken else { return }
        do {
            let page = try await client.conversations.list(pageSize: 50, pageToken: token, archived: true)
            let known = Set(archivedConversations.map(\.id))
            archivedConversations.append(contentsOf: page.items.filter { !known.contains($0.id) })
            archivedNextPageToken = page.nextPageToken
        } catch {
            if PsmithError.isCancellation(error) { return }
            loadError = PsmithError.display(error)
        }
    }

    /// Restores an archived conversation to the active list: removed
    /// from the archive state, active page one re-fetched so it lands
    /// in server order.
    public func unarchive(_ id: String) async {
        do {
            try await client.conversations.unarchive(id: id)
            archivedConversations.removeAll { $0.id == id }
            await refresh()
        } catch {
            loadError = PsmithError.display(error)
        }
    }

    /// Deletes a conversation that lives in the archive list.
    public func deleteArchived(_ id: String) async {
        do {
            try await client.conversations.delete(id: id)
            archivedConversations.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        } catch {
            loadError = PsmithError.display(error)
        }
    }

    public var clientRef: PsmithClient { client }

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
