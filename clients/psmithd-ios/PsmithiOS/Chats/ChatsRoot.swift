import SwiftUI
import PsmithKit
import PsmithUI

/// The Chats list, the app's root (boards Main, ListSearch, ListSwipe,
/// ListSelect, ListRowMenu, ListEmpty, ListArchived, ListOffline). Settings,
/// adding an account and every conversation push onto this one stack: the
/// redesign has no sheets.
struct ChatsRoot: View {
    let user: PsmithUser
    /// The server never answered and nothing is cached: the list's place
    /// shows the launch-offline state (board LaunchOffline) instead.
    var launchOffline = false
    var retry: () async -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(ConversationsModel.self) private var convos
    @Environment(iOSNavigator.self) private var navigator
    @Environment(\.theme) private var theme

    @State private var path: [ChatRoute] = []
    @State private var filter: ChatsFilter = .all
    @State private var searchText = ""
    @State private var searchArchived = false
    @FocusState private var searchFocused: Bool
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmingDelete: String?
    @State private var confirmingBulkDelete = false
    @State private var renaming: String?
    @State private var renameDraft = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if launchOffline {
                    LaunchOfflineScreen(user: user, retry: retry, open: { path.append($0) })
                } else {
                    chatsList
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .conversation(let conversation):
                    ConversationView(conversation: conversation)
                case .newConversation(let draftID):
                    ConversationView(newConversation: draftID)
                case .settings:
                    SettingsRoot()
                case .addAccount:
                    LoginView()
                }
            }
        }
        // Archive and Delete on a conversation's Info page leave the
        // conversation entirely, not just the page.
        .environment(\.ikPopToRoot) { path.removeAll() }
        .onChange(of: navigator.pendingConversationSelection) { _, id in consumePending(id) }
        .task { consumePending(navigator.pendingConversationSelection) }
        .onChange(of: searchText) { _, q in applySearch(q) }
        .onChange(of: filter) { _, f in
            if f == .archived { Task { await convos.loadArchived() } }
        }
    }

    private var chatsList: some View {
            ChatsListScreen(
                user: user,
                filter: $filter,
                searchText: $searchText,
                searchArchived: $searchArchived,
                searchFocused: $searchFocused,
                selecting: $selecting,
                selection: $selection,
                confirmingDelete: $confirmingDelete,
                confirmingBulkDelete: $confirmingBulkDelete,
                renaming: $renaming,
                renameDraft: $renameDraft,
                open: { path.append($0) }
            )
    }

    private func applySearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        convos.listMode = trimmed.isEmpty ? .allChats : .search
        convos.searchQuery = trimmed
        Task {
            await convos.refresh()
            if !trimmed.isEmpty && searchArchived { await convos.loadArchived() }
        }
    }

    /// A notification tap opens its conversation; a stale id refreshes the
    /// list once in case the conversation was made on another device.
    private func consumePending(_ id: String?) {
        guard let id else { return }
        defer { navigator.pendingConversationSelection = nil }
        if case .conversation(let open) = path.last, open.id == id { return }
        if let c = convos.conversations.first(where: { $0.id == id }) {
            path.append(.conversation(c))
            return
        }
        Task {
            await convos.refresh()
            if let c = convos.conversations.first(where: { $0.id == id }) { path.append(.conversation(c)) }
        }
    }
}

/// What the chats stack can show. A new conversation is its own route
/// because it has no server id until its first send; the UUID only keeps two
/// taps distinct.
enum ChatRoute: Hashable {
    case conversation(PsmithConversation)
    case newConversation(UUID)
    case settings
    case addAccount
}

/// The chips under the title: everything, the archive, or one profile.
enum ChatsFilter: Hashable {
    case all
    case archived
    case profile(String)
}

struct ChatsListScreen: View {
    let user: PsmithUser
    @Binding var filter: ChatsFilter
    @Binding var searchText: String
    @Binding var searchArchived: Bool
    var searchFocused: FocusState<Bool>.Binding
    @Binding var selecting: Bool
    @Binding var selection: Set<String>
    @Binding var confirmingDelete: String?
    @Binding var confirmingBulkDelete: Bool
    @Binding var renaming: String?
    @Binding var renameDraft: String
    let open: (ChatRoute) -> Void

    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme

    /// Fixed so a snapshot's "Today" doesn't depend on when it runs.
    var now: Date = .now
    /// Snapshot seam: the model's archive is settable only from inside
    /// PsmithKit, so fixtures hand theirs in here.
    var archivedFixture: [PsmithConversation]?

    private var archived: [PsmithConversation] { archivedFixture ?? convos.archivedConversations }
    private var offline: Bool { app.connectivity.state == .offline }

    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.well.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if !searching && !selecting && !isEmptyState {
                    chips
                }
                content
            }
            bottomBar
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if selecting {
            // The count centers between the two buttons, as the board's
            // space-between row does, not on the screen.
            HStack(spacing: 0) {
                IKGlassCapsule(title: "Select All") { selection = Set(visibleConversations.map(\.id)) }
                Spacer(minLength: 8)
                Text(selection.isEmpty ? "Select" : "\(selection.count) selected")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                IKGlassCapsule(title: "Done", prominent: theme.accent, weight: .semibold) {
                    selecting = false
                    selection = []
                    confirmingBulkDelete = false
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
        } else if searching {
            HStack {
                Text(resultsTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                Spacer()
                IKChip(title: "Active", isOn: !searchArchived) { searchArchived = false }
                IKChip(title: "Archived", systemImage: "archivebox", isOn: searchArchived) {
                    searchArchived = true
                    Task { await convos.loadArchived() }
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    accountMenu
                    Spacer()
                    if !isEmptyState {
                        sortMenu
                        IKGlassCircle(accessibilityLabel: "Select conversations", action: { selecting = true }) {
                            Image(systemName: "checkmark.circle").font(.system(size: 19))
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 44)
                IKLargeTitle(text: "Chats").frame(height: 44, alignment: .top)
            }
        }
    }

    private var resultsTitle: String {
        let n = visibleConversations.count
        return n == 1 ? "1 result" : "\(n) results"
    }

    private var accountMenu: some View {
        ChatsAccountMenu(user: user, open: open)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { convos.listOrder },
                set: { order in
                    convos.listOrder = order
                    Task { await convos.refresh() }
                }
            )) {
                Label("Recently Used", systemImage: "clock").tag(PsmithConversationOrder.recentlyUsed)
                Label("Recently Created", systemImage: "calendar.badge.plus").tag(PsmithConversationOrder.recentlyCreated)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 17))
                .foregroundStyle(IK.text)
                .frame(width: 44, height: 44)
                .ikGlass(in: Circle())
        }
        .accessibilityLabel("Sort conversations")
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                IKChip(title: "All", isOn: filter == .all) { filter = .all }
                IKChip(title: "Archived", systemImage: "archivebox", isOn: filter == .archived) { filter = .archived }
                ForEach(chipProfiles) { p in
                    IKChip(title: p.name, dot: ProfileColor.color(for: p.id, theme: theme),
                           isOn: filter == .profile(p.id)) { filter = .profile(p.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 32)
        .padding(.bottom, 8)
    }

    /// Profiles worth a chip: ones with a conversation, in list order.
    private var chipProfiles: [PsmithProfile] {
        let used = Set(convos.conversations.map(\.profileID))
        return convos.profiles.filter { used.contains($0.id) && !$0.parentOnly }
    }

    // MARK: Content

    private var isEmptyState: Bool {
        convos.conversations.isEmpty && !convos.isLoading && filter == .all && !searching
    }

    private var visibleConversations: [PsmithConversation] {
        if searching {
            let q = searchText.lowercased()
            return searchArchived
                ? archived.filter { ($0.title ?? "").lowercased().contains(q) }
                : convos.conversations
        }
        switch filter {
        case .all: return convos.conversations
        case .archived: return archived
        case .profile(let id): return convos.conversations.filter { $0.profileID == id }
        }
    }

    @ViewBuilder
    private var content: some View {
        if convos.isLoading && convos.conversations.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmptyState {
            ChatsEmptyState(
                archivedCount: archived.count,
                archivedMore: archivedFixture == nil && convos.archivedNextPageToken != nil,
                openArchive: { filter = .archived }
            ) { open(.newConversation(UUID())) }
            .task {
                // The count needs the archive; it isn't loaded until asked for.
                if archivedFixture == nil { await convos.loadArchived() }
            }
        } else {
            List {
                if offline {
                    IKStatusBanner(text: "Server unreachable. Messages queue and send when it's back.")
                        .ikListRow(top: 2, bottom: 0, leading: 16, trailing: 16)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.conversations) { c in row(c) }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IK.tertiary)
                            .textCase(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 18, leading: 16, bottom: 4, trailing: 16))
                            .listRowInsets(EdgeInsets())
                    }
                }
                if searching {
                    Text("Matches titles. Archived conversations stay out of the list until you turn on the Archived filter.")
                        .font(.system(size: 13)).lineSpacing(3).foregroundStyle(IK.tertiary)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .ikListRow()
                }
                if filter != .archived && !searching {
                    LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
                        .ikListRow()
                }
                Color.clear.frame(height: 96).ikListRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .listSectionSpacing(0)
            .contentMargins(.top, 0, for: .scrollContent)
            .refreshable { await convos.refresh() }
        }
    }

    private var sections: [PsmithKit.ConversationSections.Section] {
        if searching {
            return [.init(title: searchArchived ? "Archived" : "Active", conversations: visibleConversations)]
        }
        if filter == .archived {
            return visibleConversations.isEmpty ? [] : [.init(title: "Newest first", conversations: visibleConversations)]
        }
        return ConversationSections.group(visibleConversations, by: convos.listOrder, now: now)
    }

    @ViewBuilder
    private func row(_ c: PsmithConversation) -> some View {
        if confirmingDelete == c.id {
            IKConfirmCard(
                question: "Delete “\(c.title ?? "Untitled")”?",
                detail: c.archivedAt == nil
                    ? "Every message and context goes with it. Archive keeps it out of the list instead."
                    : "Every message and context goes with it.",
                onCancel: { confirmingDelete = nil },
                onConfirm: {
                    confirmingDelete = nil
                    Haptics.notify(.warning)
                    Task {
                        if c.archivedAt == nil { await convos.delete(c.id) } else { await convos.deleteArchived(c.id) }
                    }
                }
            )
            .ikListRow(top: 8, bottom: 8, leading: 12, trailing: 12)
        } else if renaming == c.id {
            ChatRenameRow(conversation: c, draft: $renameDraft, profileColor: profileColor(c)) { save in
                if save {
                    let t = renameDraft.trimmingCharacters(in: .whitespaces)
                    Task { await convos.rename(id: c.id, title: t) }
                }
                renaming = nil
            }
            .ikListRow()
        } else {
            ChatRowButton(
                conversation: c,
                profileName: profileName(c),
                profileColor: profileColor(c),
                state: rowState(c),
                order: convos.listOrder,
                now: now,
                selecting: selecting,
                selected: selection.contains(c.id),
                highlight: searching ? searchText.trimmingCharacters(in: .whitespaces) : nil,
                offline: offline,
                action: {
                    if selecting {
                        if selection.contains(c.id) { selection.remove(c.id) } else { selection.insert(c.id) }
                    } else {
                        open(.conversation(c))
                    }
                }
            )
            .ikListRow()
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                ForEach(ChatRowAction.swipeLeading(c), id: \.self) { a in actionButton(a, c).tint(a.tint) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(ChatRowAction.swipeTrailing(c), id: \.self) { a in actionButton(a, c).tint(a.tint) }
            }
            .contextMenu {
                ForEach(ChatRowAction.menu(c), id: \.self) { a in actionButton(a, c) }
            } preview: {
                ChatRowPreview(conversation: c, profileName: profileName(c), profileColor: profileColor(c), now: now)
            }
        }
    }

    private var rowActions: ChatRowActions {
        ChatRowActions(convos: convos, confirmingDelete: $confirmingDelete, renaming: $renaming, renameDraft: $renameDraft)
    }

    private func actionButton(_ a: ChatRowAction, _ c: PsmithConversation) -> some View {
        Button(role: a == .delete ? .destructive : nil) { rowActions.perform(a, on: c) } label: {
            Label(a.title, systemImage: a.systemImage)
        }
    }

    private func profileName(_ c: PsmithConversation) -> String {
        convos.profiles.first { $0.id == c.profileID }?.name ?? "Profile"
    }

    private func profileColor(_ c: PsmithConversation) -> Color {
        ProfileColor.color(for: c.profileID, theme: theme)
    }

    private func rowState(_ c: PsmithConversation) -> ChatRowState {
        if app.streamHub.activeConversationIDs.contains(c.id) { return .replying }
        if let q = app.outboundQueue.entries(forConversation: c.id).last { return .queued(q.content) }
        if let d = DraftStore.load(conversationID: c.id), !d.isEmpty { return .draft(d) }
        if app.streamHub.unseenConversationIDs.contains(c.id) { return .unseen }
        if let at = c.archivedAt { return searching ? .archivedResult : .archived(at) }
        return .idle
    }

    // MARK: Bottom bar

    /// The bar floats over a fade of the list's ground; the fade runs to
    /// the screen edge, the bar sits on the bottom safe area.
    private var bottomBar: some View {
        Group {
            if selecting { selectionBar } else { searchBar }
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [theme.well.opacity(0), theme.well], startPoint: .top, endPoint: .center)
                .frame(height: 120)
                .offset(y: 34)
                .allowsHitTesting(false)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(IK.secondary)
                TextField("Search", text: $searchText, prompt: Text("Search").foregroundStyle(IK.secondary))
                    .font(.system(size: 16))
                    .foregroundStyle(IK.text)
                    .focused(searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(IK.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .ikGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(searchFocused.wrappedValue ? theme.accent.opacity(0.55) : .clear, lineWidth: 1.5))

            if searchFocused.wrappedValue || searching {
                IKGlassCircle(accessibilityLabel: "Cancel search", action: {
                    searchText = ""
                    searchFocused.wrappedValue = false
                }) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 50, height: 50)
                .scaleEffect(50 / 44)
            } else {
                Button { open(.newConversation(UUID())) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isEmptyState ? IK.text : .white)
                        .frame(width: 50, height: 50)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .ikGlass(in: Circle(), prominent: isEmptyState ? nil : theme.accent)
                .accessibilityLabel("New conversation")
            }
        }
        .padding(.horizontal, 16)
    }

    private var selectionBar: some View {
        Group {
            if confirmingBulkDelete {
                IKConfirmCard(
                    question: "Delete \(selection.count) conversations?",
                    detail: "Every message and context in them goes too.",
                    onCancel: { confirmingBulkDelete = false },
                    onConfirm: {
                        let ids = selection
                        confirmingBulkDelete = false
                        selection = []
                        selecting = false
                        Task { for id in ids { await convos.delete(id) } }
                    }
                )
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 0) {
                    bulkAction("Pin", "pin") {
                        let ids = selection
                        Task { for id in ids { await convos.togglePin(id) } }
                    }
                    bulkAction("Archive", "archivebox") {
                        let ids = selection
                        selection = []
                        Task { for id in ids { await convos.archive(id) } }
                    }
                    bulkAction(selection.isEmpty ? "Delete" : "Delete \(selection.count)", "trash", color: IK.red) {
                        confirmingBulkDelete = true
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 64)
                .ikGlass(in: Capsule())
                .padding(.horizontal, 16)
                .disabled(selection.isEmpty)
            }
        }
    }

    private func bulkAction(_ title: String, _ icon: String, color: Color = IK.strong, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The avatar's account menu (board AccountMenu): who you are, the other
/// signed-in accounts, adding one, Settings and signing out.
struct ChatsAccountMenu: View {
    let user: PsmithUser
    let open: (ChatRoute) -> Void
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager

    var body: some View {
        Menu {
            Section {
                Button {} label: {
                    Text(user.displayName ?? user.username)
                    Text(app.serverURL.absoluteString)
                }
                .disabled(true)
            }
            if otherAccounts.isEmpty {
                Section { addAccount }
            } else {
                Section("Switch account") {
                    ForEach(otherAccounts) { account in
                        Button {
                            accountManager.switchAccount(to: account.id)
                        } label: {
                            Text(account.username)
                            Text(account.host.host ?? account.host.absoluteString)
                        }
                    }
                    addAccount
                }
            }
            Section {
                Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                Button(role: .destructive) {
                    Task { await accountManager.signOutActive() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            IKAvatar(name: user.displayName ?? user.username)
        }
        .accessibilityLabel("Account, Settings")
    }

    private var addAccount: some View {
        Button { open(.addAccount) } label: { Label("Add Account", systemImage: "plus.circle") }
    }

    private var otherAccounts: [Account] {
        accountManager.accounts.filter { $0.id != accountManager.activeAccountID }
    }
}

/// What a row offers, shared by its swipe buttons and its long-press menu
/// so the two can't drift apart.
enum ChatRowAction: Hashable {
    case pin, unpin, rename, archive, unarchive, delete

    /// Leading swipe: pin, for active conversations.
    static func swipeLeading(_ c: PsmithConversation) -> [ChatRowAction] {
        c.archivedAt == nil ? [c.pinnedAt == nil ? .pin : .unpin] : []
    }

    /// Trailing swipe, outermost first: delete, then archive and rename.
    static func swipeTrailing(_ c: PsmithConversation) -> [ChatRowAction] {
        c.archivedAt == nil ? [.delete, .archive, .rename] : [.delete, .unarchive]
    }

    /// The long-press menu, top to bottom (board ListRowMenu).
    static func menu(_ c: PsmithConversation) -> [ChatRowAction] {
        c.archivedAt == nil ? [c.pinnedAt == nil ? .pin : .unpin, .rename, .archive, .delete] : [.unarchive, .delete]
    }

    var title: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .rename: "Rename"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .delete: "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .rename: "pencil"
        case .archive: "archivebox"
        case .unarchive: "square.and.arrow.up"
        case .delete: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .pin, .unpin: IK.pinFill
        case .rename: IK.swipeNeutral
        case .archive: IK.swipeArchive
        case .unarchive: IK.swipeUnarchive
        case .delete: IK.swipeDelete
        }
    }
}

/// Runs a row action. Delete and rename only change the list's state: the
/// row turns into its confirm card or its title field, in place.
struct ChatRowActions {
    let convos: ConversationsModel
    @Binding var confirmingDelete: String?
    @Binding var renaming: String?
    @Binding var renameDraft: String

    @MainActor
    func perform(_ action: ChatRowAction, on c: PsmithConversation) {
        switch action {
        case .pin, .unpin: Task { await convos.togglePin(c.id) }
        case .archive: Task { await convos.archive(c.id) }
        case .unarchive: Task { await convos.unarchive(c.id) }
        case .delete: confirmingDelete = c.id
        case .rename:
            renameDraft = c.title ?? ""
            renaming = c.id
        }
    }
}

extension IK {
    static let pinFill = Color.dynamic(light: .hex("#A86A12"), dark: .hex("#B07A2A"))
    static let swipeDelete = Color.dynamic(light: .hex("#D93D32"), dark: .hex("#C2453C"))
    static let swipeArchive = Color.dynamic(light: .hex("#2C65A0"), dark: .hex("#2C65A0"))
    static let swipeNeutral = Color.dynamic(light: .hex("#7D8A97"), dark: .hex("#3A4756"))
}

extension View {
    /// A list row with the board's own insets and no system separator or
    /// background: rows draw their own hairline.
    func ikListRow(top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Rows

enum ChatRowState: Equatable {
    case idle
    case unseen
    case replying
    case draft(String)
    case queued(String)
    case archived(Date)
    /// An archived conversation among search results: its time, and
    /// "archived" after the profile.
    case archivedResult
}

/// One conversation: title and time, then the profile (or the draft,
/// queued text, or "Replying…"). 64pt, hairline inset 16.
struct ChatRowButton: View {
    let conversation: PsmithConversation
    let profileName: String
    let profileColor: Color
    let state: ChatRowState
    let order: PsmithConversationOrder
    let now: Date
    var selecting = false
    var selected = false
    /// The search query, marked in the title.
    var highlight: String?
    /// Offline, a queued send shows as a pill: it's waiting on the server.
    var offline = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if selecting { checkbox }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(titleText)
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        trailing
                    }
                    .frame(height: 21)
                    HStack(spacing: 6) {
                        IKDot(color: profileColor)
                        detail.font(.system(size: 14)).lineLimit(1)
                    }
                    .frame(height: 19)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 64)
            .background(selected ? theme.selection.opacity(0.55) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(IK.wash(0.06)).frame(height: 1).padding(.leading, selecting ? 52 : 16)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .replying:
            IKLaunchSpinner(size: 12, lineWidth: 1.5, track: 0.15, label: "Replying")
        case .queued where offline:
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                Text("Queued").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(IK.orange)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(IK.orange.opacity(0.16)))
        case .queued:
            Text("Queued").font(.system(size: 11, weight: .semibold)).foregroundStyle(IK.orange)
        case .unseen:
            HStack(spacing: 6) {
                IKDot(color: theme.accent, size: 9).accessibilityLabel("Unread reply")
                timeText.foregroundStyle(theme.accentInk).fontWeight(.semibold)
            }
        case .archived(let d):
            Text("Archived \(d.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.system(size: 13)).foregroundStyle(IK.tertiary)
        default:
            if conversation.pinnedAt != nil {
                Image(systemName: "pin").font(.system(size: 13)).rotationEffect(.degrees(45)).foregroundStyle(IK.tertiary)
                    .accessibilityLabel("Pinned")
            } else {
                timeText
            }
        }
    }

    private var titleColor: Color {
        guard conversation.archivedAt != nil else { return IK.text }
        return state == .archivedResult ? IK.secondary : IK.archivedTitle
    }

    private var titleText: AttributedString {
        var s = AttributedString(conversation.title ?? "Untitled")
        guard let q = highlight, !q.isEmpty else { return s }
        var from = s.startIndex
        while from < s.endIndex,
              let r = s[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            s[r].backgroundColor = theme.accent.opacity(0.28)
            s[r].foregroundColor = IK.text
            from = r.upperBound
        }
        return s
    }

    private var timeText: some View {
        Text(ChatRowButton.time(ConversationSections.date(of: conversation, by: order), now: now))
            .font(.system(size: 13)).monospacedDigit().foregroundStyle(IK.tertiary)
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .replying: Text("Replying…").foregroundStyle(theme.accentInk)
        case .draft(let d): (Text("Draft: ").foregroundColor(IK.orange) + Text(d).foregroundColor(IK.secondary))
        case .queued(let q): Text("You: \(q)").foregroundStyle(IK.secondary)
        case .archivedResult: Text("\(profileName) · archived").foregroundStyle(IK.secondary)
        default: Text(profileName).foregroundStyle(IK.secondary)
        }
    }

    private var checkbox: some View {
        ZStack {
            if selected {
                Circle().fill(theme.accent)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(IK.wash(0.25), lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// "10:42" today, "Yesterday", the weekday within a week, else "Nov 2".
    static func time(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        case 1: return "Yesterday"
        case 2...6: return d.formatted(.dateTime.weekday(.abbreviated))
        default: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// Rename in place: the row becomes a field on the highlight.
struct ChatRenameRow: View {
    let conversation: PsmithConversation
    @Binding var draft: String
    let profileColor: Color
    let done: (Bool) -> Void
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $draft)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IK.text)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.well))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 1.5))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { done(true) }
                .onChange(of: focused) { _, f in if !f { done(false) } }
            HStack(spacing: 6) {
                IKDot(color: profileColor)
                Text("Done saves · tap away to cancel").font(.system(size: 14)).foregroundStyle(IK.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(theme.selection)
        .onAppear { focused = true }
    }
}

/// The lifted card a long-press shows above the row menu: the row's
/// header. Conversations carry no message text, so there's no excerpt.
struct ChatRowPreview: View {
    let conversation: PsmithConversation
    let profileName: String
    let profileColor: Color
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(conversation.title ?? "Untitled")
                    .font(.system(size: 16, weight: .semibold)).tracking(-0.2).foregroundStyle(IK.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ChatRowButton.time(conversation.lastActivityAt, now: now))
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(IK.tertiary)
            }
            HStack(spacing: 6) {
                IKDot(color: profileColor)
                Text(profileName).font(.system(size: 13)).foregroundStyle(IK.secondary)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 358, alignment: .leading)
        .background(theme.chrome)
    }
}

/// Boards ListEmpty and ListEmptyArchive. With conversations in the
/// archive, the empty list says so and opens it, because the filter chips
/// that normally reach the archive aren't drawn here.
struct ChatsEmptyState: View {
    var archivedCount = 0
    var archivedMore = false
    var openArchive: () -> Void = {}
    let newConversation: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(IK.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(IK.wash(0.06)))
            Text(archivedCount > 0 ? "No active conversations" : "No conversations yet")
                .font(.system(size: 20, weight: .semibold)).tracking(-0.3).foregroundStyle(IK.text)
                .padding(.top, 18)
            Text(archivedCount > 0
                 ? "Archived ones stay out of the list. Start something new, or open the archive."
                 : "Pick a profile and say hello. Everything you start shows up here.")
                .font(.system(size: 15)).ikLineHeight(21, size: 15).foregroundStyle(IK.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button(action: newConversation) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .medium))
                    Text("New Conversation")
                }
                .padding(.horizontal, 24)
            }
            .ikWideButton()
            .fixedSize()
            .padding(.top, 26)
            if archivedCount > 0 {
                Button(action: openArchive) {
                    HStack(spacing: 7) {
                        Image(systemName: "archivebox").font(.system(size: 16, weight: .regular))
                        Text("Archived").font(.system(size: 16, weight: .medium))
                        Text("\(archivedCount)\(archivedMore ? "+" : "")")
                            .font(.system(size: 16)).opacity(0.7)
                    }
                    .foregroundStyle(theme.accentInk)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Archived, \(archivedCount) conversations")
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        // The board sets the icon 153pt under the large title.
        .padding(.top, 153)
        .frame(maxWidth: .infinity)
    }
}
