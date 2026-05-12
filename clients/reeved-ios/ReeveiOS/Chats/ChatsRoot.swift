import SwiftUI
import ReeveKit
import ReeveUI

/// Root of the Chats tab. Hosts the conversation list (search + mode
/// picker + sectioned list) plus the toolbar account/new chrome.
///
/// Per `docs/ios-screens.md` §2.4: `.searchable` for search, segmented
/// `Picker` for All Chats / By Profile, swipe-to-delete on rows,
/// long-press context menu, pull-to-refresh.
struct ChatsRoot: View {
    let user: ReeveUser
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos

    /// Local mode binding driven by the segmented picker. Search isn't
    /// in this enum because `.searchable`'s "user is currently typing"
    /// state drives the third mode implicitly.
    @State private var pickerMode: PickerMode = .allChats
    @State private var searchText: String = ""
    @State private var deleteCandidate: ReeveConversation?
    @State private var renameCandidate: ReeveConversation?
    @State private var renameDraft: String = ""
    @State private var showingNewConversation = false
    @State private var showingSettings = false
    /// Path appended-to when NewConversationSheet creates a chat — auto-
    /// pushes the conversation onto the stack so the user lands inside
    /// the new chat instead of having to find + tap it in the list.
    /// Also driven by notification taps via `iOSNavigator
    /// .pendingConversationSelection`.
    @State private var conversationPath: [ReeveConversation] = []
    @Environment(iOSNavigator.self) private var navigator

    enum PickerMode: Hashable {
        case allChats
        case byProfile
    }

    var body: some View {
        NavigationStack(path: $conversationPath) {
            contentList
                .navigationTitle("Chats")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ReeveConversation.self) { conversation in
                    ConversationView(conversation: conversation)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        accountMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingNewConversation = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New conversation")
                        .disabled(convos.profiles.allSatisfy { $0.parentOnly })
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
                .onChange(of: navigator.pendingConversationSelection) { _, newValue in
                    consumePendingConversation(newValue)
                }
                .task {
                    // Consume on first appear too — covers the case
                    // where the notifier set the pending value before
                    // ChatsRoot mounted.
                    consumePendingConversation(navigator.pendingConversationSelection)
                }
                .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search conversations"
            )
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

    /// Sort menu — Recently Used / Created / Title. Bound to
    /// `convos.listOrder`; refresh fires after the write so the
    /// server returns the new order.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { convos.listOrder },
                set: { newValue in
                    convos.listOrder = newValue
                    Task { await convos.refresh() }
                }
            )) {
                Text("Recently Used").tag(ReeveConversationOrder.recentlyUsed)
                Text("Recently Created").tag(ReeveConversationOrder.recentlyCreated)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort conversations")
        .disabled(pickerMode != .allChats || !searchText.isEmpty)
    }

    // MARK: - List body

    @ViewBuilder
    private var contentList: some View {
        if convos.isLoading && convos.conversations.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if convos.conversations.isEmpty && searchText.isEmpty {
            emptyState
        } else {
            List {
                if searchText.isEmpty {
                    Section {
                        Picker("Mode", selection: $pickerMode) {
                            Text("All Chats").tag(PickerMode.allChats)
                            Text("By Profile").tag(PickerMode.byProfile)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                modeBody
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var modeBody: some View {
        switch pickerMode {
        case .allChats:
            allChatsBody
        case .byProfile:
            if !searchText.isEmpty {
                allChatsBody  // search overrides mode grouping
            } else {
                byProfileBody
            }
        }
    }

    @ViewBuilder
    private var allChatsBody: some View {
        Section {
            ForEach(convos.conversations) { c in
                conversationRowLink(c, hideProfile: false)
            }
        }
    }

    @ViewBuilder
    private var byProfileBody: some View {
        ForEach(profilesSorted, id: \.id) { profile in
            let buckets = convos.conversations.filter { $0.profileID == profile.id }
            Section {
                if buckets.isEmpty {
                    Text("No conversations.")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                } else {
                    ForEach(buckets) { c in
                        conversationRowLink(c, hideProfile: true)
                    }
                }
            } header: {
                Text(profile.name)
            }
        }
    }

    private var profilesSorted: [ReeveProfile] {
        convos.profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func conversationRowLink(_ c: ReeveConversation, hideProfile: Bool) -> some View {
        NavigationLink {
            ConversationView(conversation: c)
        } label: {
            ConversationRow(
                conversation: c,
                profileChainName: hideProfile
                    ? nil
                    : profileChainName(for: c, profiles: convos.profiles),
                isGenerating: app.streamHub.activeConversationIDs.contains(c.id)
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteCandidate = c
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
                renameDraft = c.title ?? ""
                renameCandidate = c
            } label: {
                Label("Rename", systemImage: "pencil")
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
                "Welcome to Reeve",
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
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            Button(role: .destructive) {
                Task { try? await app.client.auth.logout() }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .imageScale(.large)
        }
        .accessibilityLabel("Account")
    }
}

// MARK: - Placeholder destination (Phase 5c replaces this)

/// Holds the slot that `ConversationView` will fill in Phase 5c.
/// Renders the conversation's title + an explainer so navigation
/// works end-to-end before the real view exists.
private struct ConversationViewPlaceholder: View {
    let conversation: ReeveConversation

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(conversation.title?.isEmpty == false ? conversation.title! : "Untitled")
                .font(.title3.weight(.semibold))
            Text("ConversationView lands in Phase 5c. The push, the back chevron, and the conversation row plumbing all work — this is the destination slot.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(conversation.title?.isEmpty == false ? conversation.title! : "Untitled")
        .navigationBarTitleDisplayMode(.inline)
    }
}
