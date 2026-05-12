import SwiftUI
import ReeveKit
import ReeveUI

struct ConversationListView: View {
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme
    @State private var conversationToDelete: ReeveConversation?
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
            .tint(theme.accent)
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
                    ConversationRowMac(conversation: c, onDelete: { conversationToDelete = c })
                        .tag(c.id)
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
                        ConversationRowMac(conversation: c, hideProfileLabel: true, onDelete: { conversationToDelete = c })
                            .tag(c.id)
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
                        ConversationRowMac(conversation: c, onDelete: { conversationToDelete = c })
                            .tag(c.id)
                    }
                }
            }
        }
    }

    private var profilesSorted: [ReeveProfile] {
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

    private func sortPopoverButton(_ title: String, target: ReeveConversationOrder) -> some View {
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

/// Mac wrapper around ReeveUI's shared `ConversationRow`. Adds the
/// hover-trash chrome — Mac-specific because contextMenu on macOS 26
/// sidebar rows hits a Liquid Glass capture-path bug (renders as a
/// window-wide black box). iOS uses `.swipeActions` and doesn't go
/// through this wrapper.
struct ConversationRowMac: View {
    let conversation: ReeveConversation
    /// In By-Profile mode the section header already names the profile, so
    /// the subtitle would just repeat it. Hidden in that mode.
    var hideProfileLabel: Bool = false
    /// Hover-revealed delete callback. Owned by the parent so the
    /// confirmation sheet stays at the list level. nil → no trash icon
    /// in the row chrome (defensive — every current call site provides one).
    var onDelete: (() -> Void)? = nil
    @State private var hovering = false
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
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete conversation")
                .opacity(hovering ? 1 : 0)
                // Always reserve the layout slot so hover doesn't shift
                // the title; only fade in/out.
                .allowsHitTesting(hovering)
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
}
