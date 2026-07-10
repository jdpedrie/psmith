import SwiftUI
import PsmithKit
import PsmithUI

struct ConversationListView: View {
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme
    @State private var conversationToDelete: PsmithConversation?
    @State private var sortPopoverShown = false
    /// Conversation being renamed via the alert. Owned at list level so
    /// one alert serves every row.
    @State private var renameCandidate: PsmithConversation?
    @State private var renameDraft = ""
    /// When true the sidebar browses the archive instead of the active
    /// list. Presentation-only — the data lives on ConversationsModel so
    /// HomeView's detail pane can resolve archived selections too.
    @Binding var showingArchived: Bool

    var body: some View {
        @Bindable var convos = convos
        VStack(spacing: 0) {
            List(selection: $convos.selectedID) {
                if showingArchived {
                    archivedContent
                } else {
                    // Mode pill row — first row of the list, no separator, no
                    // background. Stays visible across all modes.
                    modePillRow
                    if convos.listMode == .search {
                        searchFieldRow
                    }
                    modeContent
                }
            }
            .listStyle(.sidebar)
            .tint(theme.accent)
            .task(id: showingArchived) {
                if showingArchived { await convos.loadArchived() }
            }
            .alert(
                "Rename conversation",
                isPresented: Binding(
                    get: { renameCandidate != nil },
                    set: { if !$0 { renameCandidate = nil } }
                )
            ) {
                TextField("Title", text: $renameDraft)
                Button("Rename") {
                    if let c = renameCandidate {
                        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty {
                            Task { await convos.rename(id: c.id, title: title) }
                        }
                    }
                    renameCandidate = nil
                }
                Button("Cancel", role: .cancel) { renameCandidate = nil }
            }
            .confirmationDialog(
                conversationToDelete.map { c in
                    let t = c.title ?? ""
                    return "Delete \"\(t.isEmpty ? "Untitled" : t)\"?"
                } ?? "Delete conversation?",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let c = conversationToDelete {
                        let fromArchive = showingArchived
                        Task {
                            if fromArchive {
                                await convos.deleteArchived(c.id)
                            } else {
                                await convos.delete(c.id)
                            }
                        }
                    }
                    conversationToDelete = nil
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("This will permanently delete the conversation and all its messages.")
            }
            .overlay {
                if let err = convos.loadError {
                    VStack(spacing: 8) {
                        Text("Failed to load").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await convos.refresh() } }
                    }
                    .padding()
                } else if convos.isLoading && convos.conversations.isEmpty {
                    ProgressView()
                }
            }
        }
    }

    /// Pill at the top of the list — three buttons for All Chats / By
    /// Profile / Search. Lives as a list row (not a VStack sibling above
    /// the List) because the latter disrupts NavigationSplitView's size
    /// negotiation in this layout. `Picker(.segmented)` rendered as zero
    /// height inside `.listStyle(.sidebar)`, so we hand-roll the segments
    /// as glass capsule buttons.
    @ViewBuilder
    private var modePillRow: some View {
        HStack(spacing: 6) {
            modeButton("All Chats", mode: .allChats)
            modeButton("By Profile", mode: .byProfile)
            modeButton("Search", mode: .search)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
    }

    private func modeButton(_ label: String, mode: ConversationListMode) -> some View {
        @Bindable var convos = convos
        let active = convos.listMode == mode
        return Button {
            guard !active else { return }
            convos.listMode = mode
            Task { await convos.refresh() }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            active
                ? .regular.tint(theme.accent.opacity(0.85)).interactive()
                : .regular.interactive(),
            in: .capsule
        )
    }

    @ViewBuilder
    private var searchFieldRow: some View {
        @Bindable var convos = convos
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search titles…", text: Binding(
                get: { convos.searchQuery },
                set: { newValue in
                    convos.searchQuery = newValue
                    Task { await convos.refresh() }
                }
            ))
            .textFieldStyle(.plain)
            if !convos.searchQuery.isEmpty {
                Button {
                    convos.searchQuery = ""
                    Task { await convos.refresh() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
    }

    /// Mode-specific list sections. All Chats uses the sort-menu header;
    /// By Profile groups by profile (one section each); Search renders a
    /// flat unheaded list of matches.
    @ViewBuilder
    private var modeContent: some View {
        switch convos.listMode {
        case .allChats:
            Section {
                if convos.conversations.isEmpty && !convos.isLoading && convos.loadError == nil {
                    Text("No conversations yet.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(convos.conversations) { c in
                    activeRow(c)
                }
                LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
                archiveFooterRow
            } header: {
                sortMenu
            }
        case .byProfile:
            ForEach(profilesSorted) { profile in
                let buckets = convos.conversations.filter { $0.profileID == profile.id }
                Section {
                    if buckets.isEmpty {
                        Text("No conversations.")
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(buckets) { c in
                        activeRow(c, hideProfileLabel: true)
                    }
                } header: {
                    Text(profile.name)
                }
            }
            Section {
                LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
                archiveFooterRow
            }
        case .search:
            Section {
                if convos.searchQuery.isEmpty {
                    Text("Type to search.")
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                } else if convos.conversations.isEmpty {
                    Text("No matches.")
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(convos.conversations) { c in
                        activeRow(c)
                    }
                    LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
                }
            }
        }
    }

    private func activeRow(_ c: PsmithConversation, hideProfileLabel: Bool = false) -> some View {
        ConversationRowMac(
            conversation: c,
            hideProfileLabel: hideProfileLabel,
            onPinToggle: { Task { await convos.togglePin(c.id) } },
            onRename: {
                renameDraft = c.title ?? ""
                renameCandidate = c
            },
            onArchive: { Task { await convos.archive(c.id) } },
            onDelete: { conversationToDelete = c }
        )
        .tag(c.id)
    }

    /// Quiet entry point to the archive, pinned under the active list.
    private var archiveFooterRow: some View {
        Button {
            showingArchived = true
        } label: {
            Label("Archived", systemImage: "archivebox")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .help("Browse archived conversations")
    }

    // MARK: - Archived mode

    /// Sidebar content while browsing the archive: a back header, then
    /// the archived rows (read-only in the detail pane; the server
    /// refuses mutations). Hover chrome offers Unarchive + Delete.
    @ViewBuilder
    private var archivedContent: some View {
        Section {
            if convos.archivedConversations.isEmpty && !convos.archivedLoading {
                Text("Nothing archived.")
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            }
            ForEach(convos.archivedConversations) { c in
                ArchivedRowMac(
                    conversation: c,
                    onUnarchive: { Task { await convos.unarchive(c.id) } },
                    onDelete: { conversationToDelete = c }
                )
                .tag(c.id)
            }
            LoadMoreFooter(token: convos.archivedNextPageToken) { await convos.loadMoreArchived() }
        } header: {
            Button {
                showingArchived = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption2)
                    Text("Archived")
                }
            }
            .buttonStyle(.plain)
            .help("Back to conversations")
        }
    }

    private var profilesSorted: [PsmithProfile] {
        convos.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Section header — current sort label + chevron, taps open a popover
    /// with two buttons. `Menu` and `Picker(.menu)` both render empty on
    /// macOS 26 (the same SwiftUI bug noted in HomeView's user tray);
    /// popover-with-buttons is the reliable replacement.
    private var sortMenu: some View {
        Button {
            sortPopoverShown = true
        } label: {
            HStack(spacing: 4) {
                Text(convos.listOrder == .recentlyUsed ? "Recently Used" : "Recently Created")
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $sortPopoverShown, arrowEdge: .bottom) {
            sortPopoverContent
        }
    }

    private var sortPopoverContent: some View {
        @Bindable var convos = convos
        return VStack(alignment: .leading, spacing: 0) {
            sortPopoverButton("Recently Used", target: .recentlyUsed)
            sortPopoverButton("Recently Created", target: .recentlyCreated)
        }
        .frame(minWidth: 180)
        .padding(.vertical, 4)
    }

    private func sortPopoverButton(_ title: String, target: PsmithConversationOrder) -> some View {
        @Bindable var convos = convos
        let active = convos.listOrder == target
        return Button {
            sortPopoverShown = false
            guard convos.listOrder != target else { return }
            convos.listOrder = target
            Task { await convos.refresh() }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Mac wrapper around PsmithUI's shared `ConversationRow`. Adds the
/// hover-ellipsis actions popover — Mac-specific because contextMenu on
/// macOS 26 sidebar rows hits a Liquid Glass capture-path bug (renders
/// as a window-wide black box), and single-item SwiftUI Menus render
/// empty; popover-with-buttons is the reliable replacement. iOS uses
/// `.swipeActions` and doesn't go through this wrapper.
struct ConversationRowMac: View {
    let conversation: PsmithConversation
    /// In By-Profile mode the section header already names the profile, so
    /// the subtitle would just repeat it. Hidden in that mode.
    var hideProfileLabel: Bool = false
    var onPinToggle: () -> Void
    var onRename: () -> Void
    var onArchive: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var actionsShown = false
    @Environment(ConversationsModel.self) private var convos
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            ConversationRow(
                conversation: conversation,
                profileChainName: hideProfileLabel
                    ? nil
                    : profileChainName(for: conversation, profiles: convos.profiles),
                isGenerating: app.streamHub.activeConversationIDs.contains(conversation.id),
                isUnseen: app.streamHub.unseenConversationIDs.contains(conversation.id)
            )
            Spacer(minLength: 0)
            Button {
                actionsShown = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Conversation actions")
            // Always reserve the layout slot so hover doesn't shift
            // the title; only fade in/out. Stay visible while the
            // popover is up so the anchor doesn't vanish under it.
            .opacity(hovering || actionsShown ? 1 : 0)
            .allowsHitTesting(hovering || actionsShown)
            .popover(isPresented: $actionsShown, arrowEdge: .trailing) {
                actionsPopover
            }
        }
        .contentShape(Rectangle())
        // .onHover with a plain @State write (no withAnimation wrapper)
        // is the safe pattern on macOS 26 — wrapping the write in
        // withAnimation has historically crashed mid-stream-churn.
        .onHover { isOver in
            hovering = isOver
        }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var actionsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowActionButton(
                title: conversation.pinnedAt == nil ? "Pin" : "Unpin",
                systemImage: conversation.pinnedAt == nil ? "pin" : "pin.slash"
            ) {
                actionsShown = false
                onPinToggle()
            }
            RowActionButton(title: "Rename…", systemImage: "pencil") {
                actionsShown = false
                onRename()
            }
            RowActionButton(title: "Archive", systemImage: "archivebox") {
                actionsShown = false
                onArchive()
            }
            Divider().padding(.vertical, 4)
            RowActionButton(title: "Delete…", systemImage: "trash", role: .destructive) {
                actionsShown = false
                onDelete()
            }
        }
        .frame(minWidth: 180)
        .padding(.vertical, 4)
    }
}

/// Archived-mode counterpart: Unarchive + Delete only.
struct ArchivedRowMac: View {
    let conversation: PsmithConversation
    var onUnarchive: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var actionsShown = false

    var body: some View {
        HStack(spacing: 8) {
            ConversationRow(
                conversation: conversation,
                profileChainName: nil,
                isGenerating: false,
                isUnseen: false
            )
            Spacer(minLength: 0)
            Button {
                actionsShown = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Archive actions")
            .opacity(hovering || actionsShown ? 1 : 0)
            .allowsHitTesting(hovering || actionsShown)
            .popover(isPresented: $actionsShown, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 0) {
                    RowActionButton(title: "Unarchive", systemImage: "tray.and.arrow.up") {
                        actionsShown = false
                        onUnarchive()
                    }
                    Divider().padding(.vertical, 4)
                    RowActionButton(title: "Delete…", systemImage: "trash", role: .destructive) {
                        actionsShown = false
                        onDelete()
                    }
                }
                .frame(minWidth: 180)
                .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// One row inside a row-actions popover: full-width, hover-highlit,
/// leading icon + title. Destructive rows render red.
struct RowActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
    }
}
