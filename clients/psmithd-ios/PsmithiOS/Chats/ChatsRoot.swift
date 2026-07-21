import SwiftUI
import PsmithKit
import PsmithUI

/// Root of the Chats tab. Hosts the conversation list plus the toolbar
/// account / filter / new chrome.
///
/// The list is deliberately chrome-free: search hides until the user
/// pulls down (`.navigationBarDrawer(displayMode: .automatic)`), and
/// the All Chats / By Profile mode plus the sort order live as two
/// exclusive-picker sections inside the toolbar's filter menu — no
/// segmented control or visible field rides above the conversations.
/// Swipe-to-delete on rows, long-press context menu, pull-to-refresh.
struct ChatsRoot: View {
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(ConversationsModel.self) private var convos

    /// Local mode binding driven by the filter menu. Search isn't in
    /// this enum because a non-empty query drives the third mode
    /// implicitly.
    @State private var pickerMode: PickerMode = .allChats
    @State private var searchText: String = ""
    /// Focus for the pull-to-reveal search row. `.searchable` can't
    /// express "hidden until over-scroll" on iOS 26 (every drawer
    /// variant pins the field, verified live), so the field is the
    /// list's FIRST ROW and the list starts scrolled just past it —
    /// the classic table-header-search pattern.
    @FocusState private var searchFocused: Bool
    /// One-shot guard for the initial hide (re-fires per cold list
    /// load, not per refresh).
    @State private var didInitialSearchHide = false
    @State private var deleteCandidate: PsmithConversation?
    @State private var renameCandidate: PsmithConversation?
    @State private var renameDraft: String = ""
    @State private var showingNewConversation = false
    @State private var showingSettings = false
    @State private var showingAddAccount = false
    /// Path appended-to when NewConversationSheet creates a chat — auto-
    /// pushes the conversation onto the stack so the user lands inside
    /// the new chat instead of having to find + tap it in the list.
    /// Also driven by notification taps via `iOSNavigator
    /// .pendingConversationSelection`.
    @State private var conversationPath: [PsmithConversation] = []
    @Environment(iOSNavigator.self) private var navigator

    enum PickerMode: Hashable {
        case allChats
        case byProfile
    }

    var body: some View {
        NavigationStack(path: $conversationPath) {
            VStack(spacing: 0) {
                if app.connectivity.state == .offline {
                    offlineBanner
                }
                contentList
            }
                .navigationTitle("Chats")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: PsmithConversation.self) { conversation in
                    ConversationView(conversation: conversation)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        accountMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        filterMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        newConversationButton
                    }
                }
                .sheet(isPresented: $showingNewConversation) {
                    NewConversationSheet { newConversation in
                        // Auto-push the new conversation onto the stack
                        // so the user lands inside the chat instead of
                        // having to tap-into-it from the list.
                        conversationPath.append(newConversation)
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsRoot()
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $showingAddAccount) {
                    // LoginView with no preselected host walks through
                    // server probe + credentials and routes through
                    // AccountManager.addAccount, which dedupes on
                    // (host, username) — so even if the user happens
                    // to re-enter an existing account here, it just
                    // reactivates instead of failing or duplicating.
                    NavigationStack {
                        LoginView()
                            .navigationTitle("Add account")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Cancel") { showingAddAccount = false }
                                }
                            }
                    }
                }
                .onChange(of: navigator.pendingConversationSelection) { _, newValue in
                    consumePendingConversation(newValue)
                }
                .task {
                    // Consume on first appear too — covers the case
                    // where the notifier set the pending value before
                    // ChatsRoot mounted.
                    consumePendingConversation(navigator.pendingConversationSelection)
                }
            .onChange(of: searchText) { _, newValue in
                applySearchOrMode(newSearchText: newValue, newPicker: pickerMode)
            }
            .onChange(of: pickerMode) { _, newValue in
                applySearchOrMode(newSearchText: searchText, newPicker: newValue)
            }
            .refreshable {
                await convos.refresh()
            }
            .alert(
                "Delete conversation?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { c in
                Button("Delete", role: .destructive) {
                    Haptics.notify(.warning)
                    Task { await convos.delete(c.id) }
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: { c in
                Text("This will permanently delete \(c.title?.isEmpty == false ? "\"\(c.title!)\"" : "this conversation").")
            }
            .alert(
                "Rename conversation",
                isPresented: Binding(
                    get: { renameCandidate != nil },
                    set: { if !$0 { renameCandidate = nil } }
                )
            ) {
                TextField("Title", text: $renameDraft)
                    .textInputAutocapitalization(.sentences)
                Button("Save") {
                    if let c = renameCandidate {
                        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                        Task { await convos.rename(id: c.id, title: trimmed) }
                    }
                    renameCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    renameCandidate = nil
                }
            }
        }  // closes NavigationStack
    }

    /// Filter menu — two exclusive-choice sections: the list MODE
    /// (All Chats / By Profile, formerly a segmented control riding
    /// above the list) and the sort ORDER (Recently Used / Recently
    /// Created, bound to `convos.listOrder`; refresh fires after the
    /// write so the server returns the new order). Pickers inside a
    /// Menu render as checkmarked exclusive groups, which is exactly
    /// the semantic both choices carry.
    private var filterMenu: some View {
        Menu {
            Picker("Mode", selection: $pickerMode) {
                Label("All Chats", systemImage: "bubble.left.and.bubble.right")
                    .tag(PickerMode.allChats)
                Label("By Profile", systemImage: "person.2")
                    .tag(PickerMode.byProfile)
            }
            Divider()
            Picker("Sort", selection: Binding(
                get: { convos.listOrder },
                set: { newValue in
                    convos.listOrder = newValue
                    Task { await convos.refresh() }
                }
            )) {
                Label("Recently Used", systemImage: "clock")
                    .tag(PsmithConversationOrder.recentlyUsed)
                Label("Recently Created", systemImage: "calendar.badge.plus")
                    .tag(PsmithConversationOrder.recentlyCreated)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Filter and sort conversations")
    }

    // MARK: - List body

    /// With a default profile set, tapping + starts a conversation with
    /// it immediately — the chooser stays reachable by press-and-hold.
    /// Without a default, tap opens the chooser as before.
    ///
    /// Not a Menu(primaryAction:): inside a ToolbarItem on iOS 26 the
    /// primary-action tap is silently swallowed (the long-press menu
    /// still opens) — same class of Menu breakage as the Mac rendering
    /// bug. Plain tap + long-press gestures on the label are reliable.
    @ViewBuilder
    private var newConversationButton: some View {
        if let def = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly }) {
            Image(systemName: "plus")
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await createWithProfile(def) }
                }
                .onLongPressGesture {
                    Haptics.impact(.light)
                    showingNewConversation = true
                }
                .accessibilityLabel("New conversation")
                .accessibilityHint("Starts a chat with \(def.name). Long-press to choose a profile.")
                .accessibilityAddTraits(.isButton)
        } else {
            Button {
                showingNewConversation = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New conversation")
            // Only disable when we positively know there are no
            // usable profiles. An empty list (not yet loaded)
            // must NOT disable it — `allSatisfy` is true for an
            // empty array, which used to wrongly grey this out
            // before profiles finished loading.
            .disabled(!convos.profiles.isEmpty && convos.profiles.allSatisfy { $0.parentOnly })
        }
    }

    @MainActor
    private func createWithProfile(_ profile: PsmithProfile) async {
        if let conversation = await convos.newConversation(
            profileID: profile.id, title: nil, settings: nil
        ) {
            conversationPath.append(conversation)
        }
    }

    @ViewBuilder
    private var contentList: some View {
        if convos.isLoading && convos.conversations.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if convos.conversations.isEmpty && searchText.isEmpty {
            emptyState
        } else {
            // Chrome-free list: the mode/sort controls live in the
            // toolbar's filter menu, and search is the list's first
            // row with the list initially scrolled just past it —
            // hidden at rest, revealed by pulling down a bit. This is
            // hand-rolled because no iOS 26 `.searchable` placement
            // hides the field at rest (every drawer variant pins it;
            // verified live on short and scrollable lists).
            ScrollViewReader { proxy in
                List {
                    modeBody(proxy)
                }
                .listStyle(.plain)
                // The 1pt tuck anchor must actually BE 1pt — List's
                // default minimum row height (~44pt) would otherwise
                // pad it into a visible dead band under the search
                // row. Content-sized rows are unaffected.
                .environment(\.defaultMinListRowHeight, 1)
                .onAppear { tuckSearchIfNeeded(proxy) }
                .onChange(of: convos.conversations.isEmpty) { _, isEmpty in
                    if !isEmpty { tuckSearchIfNeeded(proxy) }
                }
                // Mode switches rebuild the list content and reset the
                // scroll to the true top, which would re-reveal the
                // search row — re-tuck so "hidden by default" holds
                // across All Chats ↔ By Profile.
                .onChange(of: pickerMode) { _, _ in
                    didInitialSearchHide = false
                    tuckSearchIfNeeded(proxy)
                }
            }
        }
    }

    private static let listTopAnchor = "chats-list-top"

    /// The pull-to-reveal search field. Styled after the system search
    /// field (gray capsule, magnifier, clear button, Cancel while
    /// active); binds straight into `searchText`, which the existing
    /// search pipeline consumes identically to the old `.searchable`.
    private func searchRow(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search conversations", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: Capsule())
            if searchFocused || !searchText.isEmpty {
                Button("Cancel") {
                    searchText = ""
                    searchFocused = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.listTopAnchor, anchor: .top)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: searchFocused)
    }

    /// Initial tuck: scroll the list to the anchor just below the
    /// search row so the field hides until the user over-scrolls.
    /// One-shot per view lifetime, and never while a search is live.
    private func tuckSearchIfNeeded(_ proxy: ScrollViewProxy) {
        guard !didInitialSearchHide, !convos.conversations.isEmpty,
              searchText.isEmpty, !searchFocused else { return }
        didInitialSearchHide = true
        // A beat so the rows exist before the id resolves.
        DispatchQueue.main.async {
            proxy.scrollTo(Self.listTopAnchor, anchor: .top)
        }
    }

    /// The pull-to-reveal leader rows: the search field + the 1pt
    /// anchor the initial tuck scrolls to. These live INSIDE the
    /// first content section — as their own Section, the inter-
    /// section gap sat below the anchor and survived the tuck as a
    /// dead band of top padding.
    @ViewBuilder
    private func listLeader(_ proxy: ScrollViewProxy) -> some View {
        searchRow(proxy)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        Color.clear
            .frame(height: 1)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .id(Self.listTopAnchor)
    }

    @ViewBuilder
    private func modeBody(_ proxy: ScrollViewProxy) -> some View {
        switch pickerMode {
        case .allChats:
            allChatsBody(proxy)
        case .byProfile:
            if !searchText.isEmpty {
                allChatsBody(proxy)  // search overrides mode grouping
            } else {
                byProfileBody(proxy)
            }
        }
    }

    @ViewBuilder
    private func allChatsBody(_ proxy: ScrollViewProxy) -> some View {
        Section {
            listLeader(proxy)
            ForEach(convos.conversations) { c in
                conversationRowLink(c, hideProfile: false)
            }
            LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
        }
        Section {
            NavigationLink {
                ArchivedConversationsScreen()
            } label: {
                Label("Archived", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func byProfileBody(_ proxy: ScrollViewProxy) -> some View {
        Section {
            listLeader(proxy)
        }
        .listSectionSpacing(2)
        ForEach(profilesSorted, id: \.id) { profile in
            let buckets = convos.conversations.filter { $0.profileID == profile.id }
            Section {
                // The profile label is a ROW, not a Section header: a
                // pinned plain-list header drags an opaque system band
                // behind it (not suppressible), and its bare-text form
                // scrolled illegibly over row content. As a row, the
                // glass chip scrolls with its group — no band, no
                // overlap.
                Text(profile.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 2, trailing: 16))
                if buckets.isEmpty {
                    Text("No conversations.")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                } else {
                    ForEach(buckets) { c in
                        conversationRowLink(c, hideProfile: true)
                    }
                }
            }
        }
        // Paging pages the flat conversation list; groups above grow as
        // pages land, so the trigger lives once at the end of the list.
        Section {
            LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
        }
    }

    private var profilesSorted: [PsmithProfile] {
        convos.profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func conversationRowLink(_ c: PsmithConversation, hideProfile: Bool) -> some View {
        NavigationLink {
            ConversationView(conversation: c)
        } label: {
            ConversationRow(
                conversation: c,
                profileChainName: hideProfile
                    ? nil
                    : profileChainName(for: c, profiles: convos.profiles),
                isGenerating: app.streamHub.activeConversationIDs.contains(c.id),
                isUnseen: app.streamHub.unseenConversationIDs.contains(c.id)
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await convos.togglePin(c.id) }
            } label: {
                Label(c.pinnedAt == nil ? "Pin" : "Unpin",
                      systemImage: c.pinnedAt == nil ? "pin" : "pin.slash")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteCandidate = c
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await convos.archive(c.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
            Button {
                renameDraft = c.title ?? ""
                renameCandidate = c
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                Task { await convos.togglePin(c.id) }
            } label: {
                Label(c.pinnedAt == nil ? "Pin" : "Unpin",
                      systemImage: c.pinnedAt == nil ? "pin" : "pin.slash")
            }
            Button {
                renameDraft = c.title ?? ""
                renameCandidate = c
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                Task { await convos.archive(c.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                deleteCandidate = c
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty state (no conversations yet)

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                "Welcome to Psmith",
                systemImage: "bubble.left.and.bubble.right",
                description: "Tap + to start your first conversation."
            )
        }
    }

    // MARK: - Pending-selection consumer

    /// Reads `pendingConversationSelection` and, if set, pushes the
    /// matching conversation onto the path. Clears the pending value
    /// so it can't fire twice. No-op when the conversation isn't in
    /// the local list (stale id from a deleted conversation, etc.).
    private func consumePendingConversation(_ id: String?) {
        guard let id else { return }
        defer { navigator.pendingConversationSelection = nil }
        guard let conversation = convos.conversations.first(where: { $0.id == id }) else {
            // Refresh the list — maybe the conversation lives on the
            // server but hasn't synced down yet (e.g. notification
            // arrived for a conversation created on another client).
            Task {
                await convos.refresh()
                if let c = convos.conversations.first(where: { $0.id == id }) {
                    conversationPath.append(c)
                }
            }
            return
        }
        // Avoid double-push if the user is already inside that
        // conversation (the notification tap landed while they were
        // looking at it).
        if conversationPath.last?.id != id {
            conversationPath.append(conversation)
        }
    }

    // MARK: - Mode driving (push to ConversationsModel)

    private func applySearchOrMode(newSearchText: String, newPicker: PickerMode) {
        let trimmed = newSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            switch newPicker {
            case .allChats:
                convos.listMode = .allChats
            case .byProfile:
                convos.listMode = .byProfile
            }
            convos.searchQuery = ""
        } else {
            convos.listMode = .search
            convos.searchQuery = trimmed
        }
        Task { await convos.refresh() }
    }

    // MARK: - Account menu

    private var accountMenu: some View {
        Menu {
            Section {
                Text(user.username)
                Text(app.serverURL.absoluteString)
                    .font(.caption)
            }
            Section {
                Button {
                    showingAddAccount = true
                } label: {
                    Label("Add account", systemImage: "plus.circle")
                }
                if otherAccounts.count > 0 {
                    Menu {
                        ForEach(otherAccounts) { account in
                            Button {
                                accountManager.switchAccount(to: account.id)
                            } label: {
                                // Two-line label so the user can tell two
                                // accounts on the same host apart by their
                                // username, and two accounts with the same
                                // username on different hosts apart by URL.
                                Text("\(account.resolvedDisplayLabel) — \(account.host.host ?? account.host.absoluteString)")
                            }
                        }
                    } label: {
                        Label("Switch account", systemImage: "person.2")
                    }
                }
            }
            Section {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                Button(role: .destructive) {
                    Task { await accountManager.signOutActive() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .imageScale(.large)
        }
        .accessibilityLabel("Account")
    }

    /// Accounts other than the active one — the candidates for "switch
    /// account". The active account is the one the menu's header
    /// section already names, so listing it again would be noise.
    private var otherAccounts: [Account] {
        accountManager.accounts.filter { $0.id != accountManager.activeAccountID }
    }

    /// Strip rendered above the list when the connectivity monitor
    /// reports the server is unreachable. The list below shows
    /// whatever the cache last saw, so the user has context but knows
    /// they're not seeing live state. Visually mirrors the composer's
    /// offline banner inside a conversation for consistency.
    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption2)
            Text("Server unavailable — showing cached chats")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
        .padding(.top, 4)
    }
}

