import SwiftUI
import ClarkKit

struct ConversationListView: View {
    @Environment(ConversationsModel.self) private var convos
    @State private var conversationToDelete: ClarkConversation?
    @State private var sortPopoverShown = false

    var body: some View {
        @Bindable var convos = convos
        VStack(spacing: 0) {
            List(selection: $convos.selectedID) {
                // Mode pill row — first row of the list, no separator, no
                // background. Stays visible across all modes.
                modePillRow
                if convos.listMode == .search {
                    searchFieldRow
                }
                modeContent
            }
            .listStyle(.sidebar)
            .confirmationDialog(
                "Delete \"\(conversationToDelete?.title?.isEmpty == false ? conversationToDelete!.title! : "Untitled")\"?",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let c = conversationToDelete {
                        Task { await convos.delete(c.id) }
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
                ? .regular.tint(Color.accentColor.opacity(0.85)).interactive()
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
                    ConversationRow(conversation: c)
                        .tag(c.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { conversationToDelete = c }
                        }
                }
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
                        ConversationRow(conversation: c, hideProfileLabel: true)
                            .tag(c.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { conversationToDelete = c }
                            }
                    }
                } header: {
                    Text(profile.name)
                }
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
                        ConversationRow(conversation: c)
                            .tag(c.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { conversationToDelete = c }
                            }
                    }
                }
            }
        }
    }

    private var profilesSorted: [ClarkProfile] {
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

    private func sortPopoverButton(_ title: String, target: ClarkConversationOrder) -> some View {
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

struct ConversationRow: View {
    let conversation: ClarkConversation
    /// In By-Profile mode the section header already names the profile, so
    /// the subtitle would just repeat it. Hidden in that mode.
    var hideProfileLabel: Bool = false
    @Environment(ConversationsModel.self) private var convos

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title?.isEmpty == false ? conversation.title! : "Untitled")
                .lineLimit(1)
            if !hideProfileLabel, let profileName = profileName {
                Text(profileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var profileName: String? {
        let id = conversation.profileID
        guard let p = convos.profiles.first(where: { $0.id == id }) else { return nil }
        var ancestors: [String] = []
        var current = p.parentProfileID
        var seen: Set<String> = [p.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let parent = convos.profiles.first(where: { $0.id == pid }) else { break }
            ancestors.append(parent.name)
            current = parent.parentProfileID
        }
        return ancestors.isEmpty ? p.name : "\(p.name) (\(ancestors.joined(separator: ", ")))"
    }
}
